#!/usr/bin/env bash
# scripts/test_de_visual.sh — THE REAL VISUAL DESKTOP GATE.
#
# WHY THIS EXISTS
# ---------------
# scripts/test_installer_de_runlevel5.sh and the legacy
# scripts/test_de_visual_gate.sh were shipping FALSE GREENS: rl5 only
# asserts the framebuffer screendump has ">= 2 distinct pixel values",
# which a BLANK GREEN screen + a tiny mouse cursor satisfies (7 distinct
# triples — demonstrably PASSes on a pure-backdrop frame). And the legacy
# visual gate drives its OWN app-launch sequence through
# /dev/wsys/run/launch with [visual_gate] markers — it proves the
# compositor CAN paint a window it spawned, but NOT that the PRODUCTION
# rc.5 desktop (hamdesktop panel + hampanelscene + the scene apps) renders
# on a vanilla boot. So both gates could be green while the real boot is a
# blank teal screen with a movable cursor and nothing else.
#
# WHAT THIS GATE DOES (no test-only hooks — the PRODUCTION boot path)
# ------------------------------------------------------------------
#   1. Boots build/hamnix-installer.img under OVMF/KVM with the user's
#      EXACT ship command (-vga std / GOP), -display none + a QEMU monitor
#      socket so the framebuffer can be screendumped headlessly.
#   2. Waits for the handoff marker, then lets the runlevel-5 DE settle
#      (the rc.5 hook launches the scene panel/desktop/terminal/FM/calc/
#      editor as ordinary scene clients — NOT the [visual_gate] runner).
#   3. screendumps the framebuffer and runs a STRUCTURAL analysis
#      (scripts/lib/de_screendump_struct.py, PIL): the frame PASSES only
#      if it contains BOTH
#         (a) a PANEL BAR — a near-full-width horizontal band of a
#             distinct color at the top or bottom edge, AND
#         (b) at least one APP WINDOW — a contiguous central block of
#             non-backdrop, non-panel pixels spanning many rows.
#      A blank-green(+cursor) frame has no panel and zero window content,
#      so it FAILS. A panel-only frame FAILS (needs a window too).
#   4. Saves the screendump PNG to OUT_DIR/de_visual.png and prints the
#      path so a reviewer can VIEW it.
#
# Also re-checks the rl5 invariants (entered runlevel 5, hamUI stack
# started, no 'empty definition file', no panic) so this one gate is a
# superset of the rl5 markers PLUS the real structural proof.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat/nc, a PPM->PNG
# converter, PIL, or the installer image are unavailable.
#
# Env overrides:
#   INSTALLER_IMG      image path        (default: build/hamnix-installer.img)
#   OVMF_FD            OVMF firmware     (default: auto-resolved)
#   BOOT_WAIT          seconds for the handoff marker      (default: 240)
#   SETTLE             seconds to let the DE paint after handoff (default: 22)
#   XRES YRES          force a GOP mode via -device VGA,xres=,yres=
#                      (default: unset — OVMF default GOP, ~1280x800)
#   OUT_DIR            artifact dir      (default: build/de_visual/<ts>)
#   HAMNIX_SKIP_BUILD  1 = require an existing image (no rebuild)
#   KEEP_LOGS          1 = keep the serial log + PNG on PASS (default: keep)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
SETTLE="${SETTLE:-22}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_visual/$TS}"
HANDOFF_MARKER="handing off to interactive shell"
STRUCT_PY="$PROJ_ROOT/scripts/lib/de_screendump_struct.py"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[de_visual] SKIP: /dev/kvm absent (KVM required; -vga std boot too slow without it)" >&2
    exit 0
fi

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[de_visual] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

MON_DRIVER=""
if command -v socat >/dev/null 2>&1; then
    MON_DRIVER="socat"
elif command -v nc >/dev/null 2>&1; then
    MON_DRIVER="nc"
else
    echo "[de_visual] SKIP: no socat/nc to drive the QEMU monitor" >&2
    exit 0
fi

CONVERTER=""
if command -v convert >/dev/null 2>&1; then
    CONVERTER="convert"
elif command -v ffmpeg >/dev/null 2>&1; then
    CONVERTER="ffmpeg"
elif command -v pnmtopng >/dev/null 2>&1; then
    CONVERTER="pnmtopng"
fi
# PIL is required for the structural analysis.
if ! python3 -c 'import PIL' >/dev/null 2>&1; then
    echo "[de_visual] SKIP: python3 PIL/Pillow not installed (pip install pillow)" >&2
    exit 0
fi

# --- ensure the installer image exists --------------------------------
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[de_visual]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[de_visual] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2
        exit 0
    fi
    echo "[de_visual] installer image absent; building via build_installer_img.sh (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[de_visual] SKIP: $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

mkdir -p "$OUT_DIR"
OVMF_RW=$(mktemp --tmpdir hamnix-dev.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-dev.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-dev-mon.XXXXXX)
PPM=$(mktemp --tmpdir hamnix-dev.XXXXXX.ppm)
PNG="$OUT_DIR/de_visual.png"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$PPM"
}
trap cleanup EXIT

mon_cmd() {
    if [ "$MON_DRIVER" = "socat" ]; then
        printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
    else
        printf '%s\n' "$1" | nc -U -q1 "$MON" >/dev/null 2>&1
    fi
}

# Optional forced GOP geometry (reproduce a large real-HW panel). The
# efi_stub takes GOP's CURRENT mode, so -device VGA,xres=,yres= sets the
# framebuffer the kernel inherits.
VGA_ARGS=(-vga std)
if [ -n "${XRES:-}" ] && [ -n "${YRES:-}" ]; then
    VGA_ARGS=(-device "VGA,xres=$XRES,yres=$YRES")
fi

# Mirror the user's exact ship command, headless + monitor socket.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "${HAMNIX_VM_MEM:-2G}" \
    "${VGA_ARGS[@]}" -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    > "$LOG" 2>&1 < /dev/null &
QEMU_PID=$!

echo "[de_visual] waiting up to ${BOOT_WAIT}s for handoff marker..."
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q "$HANDOFF_MARKER" "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[de_visual] FAIL: qemu exited before the handoff marker." >&2
        tail -80 "$LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$booted" -ne 1 ]; then
    echo "[de_visual] FAIL: handoff marker not seen in ${BOOT_WAIT}s." >&2
    tail -80 "$LOG" >&2
    exit 1
fi
echo "[de_visual] handoff reached; letting the DE paint for ${SETTLE}s..."
sleep "$SETTLE"

# screendump the framebuffer (async; poll for a stable file).
SHOT_OK=0
if mon_cmd "screendump $PPM"; then
    for _ in $(seq 1 30); do
        [ -s "$PPM" ] && break
        sleep 0.2
    done
    sleep 0.3
    [ -s "$PPM" ] && SHOT_OK=1
fi

# Convert to PNG for the reviewer (analyzer can read PPM directly too).
if [ "$SHOT_OK" -eq 1 ]; then
    case "$CONVERTER" in
        convert) convert "$PPM" "$PNG" 2>/dev/null ;;
        ffmpeg)  ffmpeg -y -loglevel error -i "$PPM" "$PNG" </dev/null 2>/dev/null ;;
        pnmtopng) pnmtopng "$PPM" > "$PNG" 2>/dev/null ;;
        *) cp "$PPM" "$OUT_DIR/de_visual.ppm" ;;
    esac
fi

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
QEMU_PID=""

# --- assertions -------------------------------------------------------
fail=0

# (rl5 invariants, kept so this gate supersedes the rl5 markers) --------
if grep -a -q "empty definition file" "$LOG"; then
    echo "[de_visual] FAIL: 'empty definition file' present (svc/uaccess regression)." >&2
    fail=1
fi
if grep -a -q -E "\[init\] entering runlevel 5" "$LOG"; then
    echo "[de_visual] PASS: entered runlevel 5 (graphical by default)."
else
    echo "[de_visual] FAIL: did NOT enter runlevel 5 by default." >&2
    fail=1
fi
if grep -a -q "hamUI stack started by supervisor" "$LOG"; then
    echo "[de_visual] PASS: rc.5 hook started the hamUI stack."
else
    echo "[de_visual] FAIL: rc.5 hamUI-stack-started marker missing." >&2
    fail=1
fi
if grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | grep -aq .; then
    echo "[de_visual] FAIL: kernel panic during boot:" >&2
    grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | head >&2
    fail=1
fi

# (THE structural visual proof) ----------------------------------------
ANALYZE_SRC="$PNG"
[ -s "$ANALYZE_SRC" ] || ANALYZE_SRC="$OUT_DIR/de_visual.ppm"
[ -s "$ANALYZE_SRC" ] || ANALYZE_SRC="$PPM"   # last resort if no converter
if [ "$SHOT_OK" -ne 1 ] || [ ! -s "$ANALYZE_SRC" ]; then
    echo "[de_visual] FAIL: no screendump captured (monitor/converter issue)." >&2
    fail=1
else
    echo "[de_visual] structural analysis of $ANALYZE_SRC:"
    if python3 "$STRUCT_PY" "$ANALYZE_SRC"; then
        echo "[de_visual] PASS: real desktop structure (panel bar + app window) present."
    else
        echo "[de_visual] FAIL: NO desktop structure — blank/flat backdrop (the blank-green bug)." >&2
        fail=1
    fi
fi

echo "[de_visual] screendump PNG: $PNG"
echo "[de_visual] serial log:     $LOG"

if [ "$fail" -eq 0 ]; then
    echo "[de_visual] PASS"
    exit 0
else
    echo "[de_visual] FAIL (artifacts in $OUT_DIR)" >&2
    exit 1
fi
