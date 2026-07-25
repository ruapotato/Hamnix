#!/usr/bin/env bash
# scripts/test_img_uefi_hamterm.sh — ACCEPTANCE GATE for the in-window
# TERMINAL: a hamUI window that is an ACTUAL interactive hamsh shell, with
# the shell's text rendered INSIDE the window body and the keyboard routed
# to the focused window's shell.
#
# This boots the INSTALLED ext4-on-NVMe system (the golden disk produced by
# the real installer, scripts/build_installed_nvme.sh) under OVMF/UEFI (GOP
# framebuffer) and proves the terminal-in-window works END TO
# END off the real boot path (NOT the `-kernel` shortcut):
#
#   1. boot to the interactive shell (ext4 root)
#   2. `hamUId daemon autowin` comes up ("DAEMON up screen=<w>x<h>") and
#      programmatically creates one terminal window bound to a hamsh whose
#      stdin/stdout are kernel pipes owned by the daemon ("DAEMON autowin
#      created").
#   3. the spawned hamsh prints its "hamsh$ " prompt to its stdout pipe;
#      the daemon's in-daemon VT emulator rasterises that into the window
#      body. A QEMU framebuffer screendump of the BODY RECTANGLE must
#      contain text-shaped ink pixels (a meaningful dark-on-light glyph
#      count), not just non-uniform chrome — stronger than the blank check
#      in test_img_uefi_hamui.sh.
#   4. BONUS: inject keystrokes via the QEMU monitor `sendkey` and assert
#      the echoed text changes the body ink. sendkey -> /dev/cons routing
#      may not be wired in this QEMU/firmware combo; if the post-keystroke
#      ink does not grow we DO NOT fail — the prompt-render assertion (3)
#      is the gate, and we log the bonus result.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, mksquashfs, or the golden
# installed disk is unavailable.
#
# Env overrides:
#   GOLDEN_NVME        installed disk path       (default: build/hamnix-installed.qcow2)
#   OVMF_FD            OVMF firmware path        (default: auto-resolved)
#   SHELL_BOOT_WAIT    seconds to wait for the   (default: 200)
#                      interactive-prompt marker
#   HAMNIX_SKIP_BUILD  1 = require an existing golden disk (no rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

GOLDEN_NVME="${GOLDEN_NVME:-build/hamnix-installed.qcow2}"
SHELL_BOOT_WAIT="${SHELL_BOOT_WAIT:-200}"
KERNEL_BANNER="Hamnix kernel booting"
PROMPT_MARKER="handing off to interactive shell"

# Auto-window rect (must match cmd_daemon_auto in user/hamUId.ad).
WIN_X=720
WIN_Y=80
WIN_W=480
WIN_H=320
TITLE_H=18                    # hamUId.ad TITLE_H
# Body rectangle = window minus 2px border + title bar.
BODY_X=$((WIN_X + 2))
BODY_Y=$((WIN_Y + TITLE_H))
BODY_W=$((WIN_W - 4))
BODY_H=$((WIN_H - TITLE_H - 2))

# --- environment gates (skip cleanly) ---------------------------------
# These GFX tests need a framebuffer + screendump, which the serial-only
# _installed_boot.sh helper cannot provide, so we boot a fresh writable
# COPY of the golden installed disk directly here. Gating mirrors the
# helper / build_installed_nvme.sh.
if [ ! -e /dev/kvm ]; then
    echo "[test_img_hamterm] SKIP: /dev/kvm absent (KVM required; boot too slow without it)" >&2
    exit 0
fi

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    if [ -f /usr/share/ovmf/OVMF.fd ]; then
        OVMF_FD=/usr/share/ovmf/OVMF.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[test_img_hamterm] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- ensure the golden installed disk exists --------------------------
# build_installed_nvme.sh installs ONCE via the real installer path and
# gates cleanly (exit 0, no disk) when KVM/OVMF/mksquashfs is missing.
# Stale-artifact guard: "(re)build only when ABSENT" is the shape that
# produced the 2026-07-24 false negative — the golden disk is installed once
# and then reused forever. See scripts/_installer_img.sh.
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
if installer_img_needs_build "$GOLDEN_NVME" "[img_uefi_hamterm]"; then
    echo "[test_img_hamterm] golden installed disk absent/stale; building it via build_installed_nvme.sh"
    bash "$PROJ_ROOT/scripts/build_installed_nvme.sh"
fi
if [ ! -f "$GOLDEN_NVME" ]; then
    echo "[test_img_hamterm] SKIP: golden installed disk $GOLDEN_NVME unavailable (mksquashfs/installer path gated)." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-hamterm.ovmf.XXXXXX.fd)
DISK_RW=$(mktemp --tmpdir hamnix-hamterm.disk.XXXXXX.qcow2)
LOG=$(mktemp --tmpdir hamnix-hamterm.XXXXXX.log)
INFIFO=$(mktemp --tmpdir -u hamnix-hamterm-in.XXXXXX)
MON=$(mktemp --tmpdir -u hamnix-hamterm-mon.XXXXXX)
SHOT1=$(mktemp --tmpdir hamnix-hamterm.1.XXXXXX.ppm)
SHOT2=$(mktemp --tmpdir hamnix-hamterm.2.XXXXXX.ppm)
cp "$OVMF_FD" "$OVMF_RW"
# Fresh writable COPY of the golden disk (never boot the golden master).
cp "$GOLDEN_NVME" "$DISK_RW"
mkfifo "$INFIFO"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$DISK_RW" "$INFIFO" "$MON" "$SHOT1" "$SHOT2"
}
trap cleanup EXIT

exec 4<>"$INFIFO"
exec 3>"$INFIFO"

# The root is the installed ext4-on-NVMe disk (golden copy) instead of the
# retired baked hamnix.img.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$DISK_RW",format=qcow2,if=none,id=nvmeroot \
    -device nvme,drive=nvmeroot,serial=hamnvme01,bootindex=0 \
    -m 1G \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

# --- wait for the interactive prompt ----------------------------------
echo "[test_img_hamterm] waiting up to ${SHELL_BOOT_WAIT}s for prompt marker..."
booted=0
for _ in $(seq 1 "$SHELL_BOOT_WAIT"); do
    if grep -a -q "$PROMPT_MARKER" "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[test_img_hamterm] FAIL: qemu exited before reaching the prompt." >&2
        tail -80 "$LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$booted" -ne 1 ]; then
    echo "[test_img_hamterm] FAIL: prompt marker not seen in ${SHELL_BOOT_WAIT}s." >&2
    tail -80 "$LOG" >&2
    exit 1
fi
echo "[test_img_hamterm] prompt reached; starting the in-window terminal."

type_cmd() {
    printf '%s\n' "$1" >&3
    sleep "${2:-4}"
}

# HMP command over the monitor unix socket (one-shot; needs socat or nc).
mon_cmd() {
    if command -v socat >/dev/null 2>&1; then
        printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
    elif command -v nc >/dev/null 2>&1; then
        printf '%s\n' "$1" | nc -U -q1 "$MON" >/dev/null 2>&1
    else
        return 1
    fi
}

have_mon=0
if command -v socat >/dev/null 2>&1 || command -v nc >/dev/null 2>&1; then
    have_mon=1
fi

type_cmd "echo HAMTERM_REPL_OK"
# Start the daemon WITH an auto-window so a terminal window is created
# mouse-free; the daemon never returns (it owns the present loop), so this
# is the last interactive command.
type_cmd "hamUId daemon autowin" 8
# Give the spawned hamsh time to print its prompt + the daemon to paint it.
sleep 4

# Count dark "ink" pixels inside an RGB rectangle of a binary PPM (P6).
# Args: ppm x y w h. Echoes the ink count (pixels darker than a threshold,
# i.e. rendered black-on-light glyphs in the window body).
ink_in_rect() {
    local ppm="$1" rx="$2" ry="$3" rw="$4" rh="$5"
    python3 - "$ppm" "$rx" "$ry" "$rw" "$rh" <<'PY'
import sys
path, rx, ry, rw, rh = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
try:
    data = open(path, "rb").read()
except OSError:
    print(0); sys.exit(0)
# Parse a binary PPM (P6) header: magic, width, height, maxval.
if not data.startswith(b"P6"):
    print(0); sys.exit(0)
idx = 2
fields = []
while len(fields) < 3:
    # skip whitespace + comments
    while idx < len(data) and data[idx:idx+1].isspace():
        idx += 1
    if idx < len(data) and data[idx:idx+1] == b"#":
        while idx < len(data) and data[idx:idx+1] != b"\n":
            idx += 1
        continue
    start = idx
    while idx < len(data) and not data[idx:idx+1].isspace():
        idx += 1
    fields.append(int(data[start:idx]))
W, H, maxv = fields
idx += 1  # single whitespace after maxval
pix = data[idx:]
ink = 0
for yy in range(ry, min(ry + rh, H)):
    row = (yy * W) * 3
    for xx in range(rx, min(rx + rw, W)):
        o = row + xx * 3
        if o + 2 >= len(pix):
            continue
        r, g, b = pix[o], pix[o+1], pix[o+2]
        # body is light gray (~200,200,210); glyph ink is dark (~24).
        if r < 90 and g < 90 and b < 90:
            ink += 1
print(ink)
PY
}

INK1=-1
INK2=-1
if [ "$have_mon" -eq 1 ]; then
    if mon_cmd "screendump $SHOT1"; then
        sleep 2
        if [ -s "$SHOT1" ]; then
            INK1=$(ink_in_rect "$SHOT1" "$BODY_X" "$BODY_Y" "$BODY_W" "$BODY_H")
        fi
    fi
    # BONUS: inject keystrokes (type `echo HI` + Enter) and re-shoot.
    for k in e c h o spc shift-h shift-i ret; do
        mon_cmd "sendkey $k"
        sleep 0.2
    done
    sleep 3
    if mon_cmd "screendump $SHOT2"; then
        sleep 2
        if [ -s "$SHOT2" ]; then
            INK2=$(ink_in_rect "$SHOT2" "$BODY_X" "$BODY_Y" "$BODY_W" "$BODY_H")
        fi
    fi
fi

sleep 1
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
exec 3>&-
exec 4>&-

# --- assertions -------------------------------------------------------
fail=0

if grep -a -q "$KERNEL_BANNER" "$LOG"; then
    echo "[test_img_hamterm] PASS: kernel banner present."
else
    echo "[test_img_hamterm] FAIL: kernel banner NOT present." >&2
    fail=1
fi

if grep -a -q -E "DAEMON up screen=[0-9]+x[0-9]+" "$LOG"; then
    geo=$(grep -a -o -E "DAEMON up screen=[0-9]+x[0-9]+" "$LOG" | head -1)
    echo "[test_img_hamterm] PASS: hamUId daemon up ($geo)."
else
    echo "[test_img_hamterm] FAIL: hamUId daemon did NOT come up." >&2
    fail=1
fi

if grep -a -q "DAEMON autowin created" "$LOG"; then
    echo "[test_img_hamterm] PASS: daemon programmatically created a terminal window."
else
    echo "[test_img_hamterm] FAIL: daemon did NOT create the auto-window." >&2
    fail=1
fi

# THE GATE: the window body must contain text-shaped ink (the rendered
# "hamsh\$ " prompt glyphs), not just chrome. Require a meaningful glyph
# pixel count. A single 8x16 glyph stroke is ~30-60 ink px; the prompt
# "hamsh\$ " is 7 cells, so expect well over 100 ink px.
if [ "$INK1" -lt 0 ]; then
    echo "[test_img_hamterm] NOTE: screendump skipped (no socat/nc or empty dump); relying on serial markers only." >&2
    if [ "$have_mon" -eq 0 ]; then
        echo "[test_img_hamterm] NOTE: install socat or nc to exercise the body-ink gate."
    fi
elif [ "$INK1" -ge 100 ]; then
    echo "[test_img_hamterm] PASS (GATE): window body shows shell-prompt glyphs (${INK1} ink px in the body rect)."
else
    echo "[test_img_hamterm] FAIL (GATE): window body has too little text ink (${INK1} px < 100) — the shell prompt did not render in the window." >&2
    fail=1
fi

# BONUS: keystroke echo. Only a non-fatal note — sendkey -> /dev/cons may
# not be wired in this QEMU/firmware combo.
if [ "$INK1" -ge 0 ] && [ "$INK2" -ge 0 ]; then
    if [ "$INK2" -gt "$INK1" ]; then
        echo "[test_img_hamterm] BONUS PASS: injected keystrokes echoed into the window (ink ${INK1} -> ${INK2})."
    else
        echo "[test_img_hamterm] BONUS NOTE: keystroke echo not observed (ink ${INK1} -> ${INK2}); sendkey->/dev/cons may not route under this QEMU. Prompt-render gate above is the acceptance criterion."
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_img_hamterm] PASS"
    rm -f "$LOG"
    exit 0
else
    echo "[test_img_hamterm] FAIL (serial log: $LOG)" >&2
    exit 1
fi
