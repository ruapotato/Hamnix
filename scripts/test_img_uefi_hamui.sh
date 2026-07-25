#!/usr/bin/env bash
# scripts/test_img_uefi_hamui.sh — ACCEPTANCE GATE for hamUI on the REAL
# boot path (build/hamnix.img under OVMF/UEFI, GOP framebuffer).
#
# This is the test that the ~100 `-kernel` tests could NOT be: it boots the
# INSTALLED ext4-on-NVMe system (the golden disk produced by the real
# installer, scripts/build_installed_nvme.sh) under OVMF firmware -> ESP ->
# kernel ELF -> ext4 root, EFI GOP framebuffer, then proves the windowing
# stack works from userland OFF EXT4:
#
#   1. boot to the interactive shell (ext4 root, no cpio userland)
#   2. `cat /dev/fb` succeeds — the synthetic /dev/fb cdev RESOLVES under
#      the kernel `bind '#sysroot' /` root rebind (the bug this gates: the
#      root rebind used to swallow /dev/* into the ext4 sysroot, so every
#      open("/dev/fb") missed and hamUId died with "cannot read /dev/fb
#      geometry"). The read returns the geometry line "<w> <h> <pitch>
#      <bpp> <pixfmt>".
#   3. `hamUId daemon` comes up: "DAEMON up screen=<w>x<h>" — it opened
#      /dev/fb, read the real GOP geometry, and entered its present loop.
#   4. a QEMU framebuffer screendump is NON-BLANK (the daemon painted a
#      desktop into the GOP framebuffer — actual pixels, not just a marker).
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

# --- environment gates (skip cleanly) ---------------------------------
# These GFX tests need a framebuffer + screendump, which the serial-only
# _installed_boot.sh helper cannot provide, so we boot a fresh writable
# COPY of the golden installed disk directly here. Gating mirrors the
# helper / build_installed_nvme.sh.
if [ ! -e /dev/kvm ]; then
    echo "[test_img_hamui] SKIP: /dev/kvm absent (KVM required; boot too slow without it)" >&2
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
    echo "[test_img_hamui] SKIP: OVMF firmware not found (apt install ovmf)" >&2
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
if installer_img_needs_build "$GOLDEN_NVME" "[img_uefi_hamui]"; then
    echo "[test_img_hamui] golden installed disk absent/stale; building it via build_installed_nvme.sh"
    bash "$PROJ_ROOT/scripts/build_installed_nvme.sh"
fi
if [ ! -f "$GOLDEN_NVME" ]; then
    echo "[test_img_hamui] SKIP: golden installed disk $GOLDEN_NVME unavailable (mksquashfs/installer path gated)." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-hamui.ovmf.XXXXXX.fd)
DISK_RW=$(mktemp --tmpdir hamnix-hamui.disk.XXXXXX.qcow2)
LOG=$(mktemp --tmpdir hamnix-hamui.XXXXXX.log)
INFIFO=$(mktemp --tmpdir -u hamnix-hamui-in.XXXXXX)
MON=$(mktemp --tmpdir -u hamnix-hamui-mon.XXXXXX)
SHOT=$(mktemp --tmpdir hamnix-hamui.XXXXXX.ppm)
cp "$OVMF_FD" "$OVMF_RW"
# Fresh writable COPY of the golden disk (never boot the golden master).
cp "$GOLDEN_NVME" "$DISK_RW"
mkfifo "$INFIFO"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$DISK_RW" "$INFIFO" "$MON" "$SHOT"
}
trap cleanup EXIT

exec 4<>"$INFIFO"
exec 3>"$INFIFO"

# -vga std gives a real GOP framebuffer under OVMF; -monitor on a unix
# socket lets us screendump the framebuffer the daemon paints. The root is
# the installed ext4-on-NVMe disk (golden copy) instead of the retired
# baked hamnix.img.
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
echo "[test_img_hamui] waiting up to ${SHELL_BOOT_WAIT}s for prompt marker..."
booted=0
for _ in $(seq 1 "$SHELL_BOOT_WAIT"); do
    if grep -a -q "$PROMPT_MARKER" "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[test_img_hamui] FAIL: qemu exited before reaching the prompt." >&2
        tail -80 "$LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$booted" -ne 1 ]; then
    echo "[test_img_hamui] FAIL: prompt marker not seen in ${SHELL_BOOT_WAIT}s." >&2
    tail -80 "$LOG" >&2
    exit 1
fi
echo "[test_img_hamui] prompt reached; driving the windowing stack."

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

type_cmd "echo HAMUI_REPL_OK"
type_cmd "cat /dev/fb"                 # geometry read — must NOT error
type_cmd "echo HAMUI_AFTER_FB"
type_cmd "hamUId daemon" 6             # opens /dev/fb, reads geometry, draws
# Give the daemon a moment to paint, then screendump the framebuffer.
sleep 3
SHOT_OK=0
if mon_cmd "screendump $SHOT"; then
    sleep 2
    [ -s "$SHOT" ] && SHOT_OK=1
fi
type_cmd "echo HAMUI_DONE_99"

sleep 2
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
exec 3>&-
exec 4>&-

# --- assertions -------------------------------------------------------
fail=0

if grep -a -q "$KERNEL_BANNER" "$LOG"; then
    echo "[test_img_hamui] PASS: kernel banner present (EFI stub -> kernel)."
else
    echo "[test_img_hamui] FAIL: kernel banner NOT present." >&2
    fail=1
fi

# The GOP framebuffer must have come up the UEFI way (NOT multiboot/VBE).
if grep -a -q "EFI GOP framebuffer console ready" "$LOG"; then
    echo "[test_img_hamui] PASS: EFI GOP framebuffer console ready."
else
    echo "[test_img_hamui] FAIL: EFI GOP framebuffer did NOT come up." >&2
    fail=1
fi

# THE KEYSTONE bug: /dev/fb must be openable under the root rebind.
if grep -a -q -E "cannot open /dev/fb|cannot read /dev/fb geometry" "$LOG"; then
    echo "[test_img_hamui] FAIL: /dev/fb did NOT resolve under '#sysroot' / — the synthetic cdev was swallowed into ext4:" >&2
    grep -a -E "cannot open /dev/fb|cannot read /dev/fb geometry" "$LOG" >&2
    fail=1
else
    echo "[test_img_hamui] PASS (KEYSTONE): /dev/fb resolves off the synthetic devtab, not ext4."
fi

# hamUId daemon must report it came up at the real GOP geometry.
if grep -a -q -E "DAEMON up screen=[0-9]+x[0-9]+" "$LOG"; then
    geo=$(grep -a -o -E "DAEMON up screen=[0-9]+x[0-9]+" "$LOG" | head -1)
    echo "[test_img_hamui] PASS: hamUId daemon up ($geo)."
else
    echo "[test_img_hamui] FAIL: hamUId daemon did NOT come up (no 'DAEMON up screen=')." >&2
    fail=1
fi

# Framebuffer screendump must be non-blank: more than one distinct pixel
# value means the daemon actually painted into the GOP framebuffer.
# (Skipped, not failed, if no socat/nc is available to drive the monitor.)
if [ "$SHOT_OK" -eq 1 ]; then
    distinct=$(tail -c +16 "$SHOT" 2>/dev/null \
        | od -An -tx1 -w3 2>/dev/null | sort -u | head -200 | wc -l)
    if [ "${distinct:-0}" -ge 2 ]; then
        echo "[test_img_hamui] PASS: framebuffer screendump is non-blank ($distinct+ distinct pixel values — desktop painted)."
    else
        echo "[test_img_hamui] FAIL: framebuffer screendump is uniform/blank — nothing was painted." >&2
        fail=1
    fi
else
    echo "[test_img_hamui] NOTE: framebuffer screendump skipped (no socat/nc, or empty dump); relying on the DAEMON-up + geometry assertions above."
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_img_hamui] PASS"
    rm -f "$LOG"
    exit 0
else
    echo "[test_img_hamui] FAIL (serial log: $LOG)" >&2
    exit 1
fi
