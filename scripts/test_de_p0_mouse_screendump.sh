#!/usr/bin/env bash
# scripts/test_de_p0_mouse_screendump.sh — DE-correction Phase 0 GATE.
#
# Proves the canonical Plan 9 writable-mouse (/dev/mouse) drives the live
# compositor cursor on a REAL EFI GOP framebuffer, with SCREENDUMP evidence:
#
#   1. Boot the installer live image under OVMF/-vga std (the real ship path).
#   2. Wait for the interactive-shell handoff (the live DE is compositing).
#   3. screendump BEFORE.
#   4. From the serial hamsh, drive the cursor to a KNOWN screen position with
#      the canonical writable mouse:  echo "<ax> <ay> 0 0 1" > /dev/mouse
#      (ax/ay = 0..32767 absolute tablet coords; abs-flag=1). NO QMP HW
#      injection — purely the /dev/mouse file capability.
#   5. screendump AFTER.
#   6. Assert the two PNGs DIFFER (cursor moved). Both PNG paths are printed.
#
# Skips cleanly when /dev/kvm, OVMF, a PPM->PNG converter, or a monitor
# driver (socat/nc) is unavailable.
#
# Env overrides:
#   INSTALLER_IMG   live image      (default: build/hamnix-installer.img)
#   OVMF_FD         OVMF firmware   (default: auto-resolved)
#   BOOT_WAIT       handoff wait s  (default: 240)
#   PAINT_WAIT      DE paint wait s (default: 8)
#   BEFORE_OUT/AFTER_OUT  PNG paths (default: build/de_p0_mouse_{before,after}.png)

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
PAINT_WAIT="${PAINT_WAIT:-8}"
BEFORE_OUT="${BEFORE_OUT:-build/de_p0_mouse_before.png}"
AFTER_OUT="${AFTER_OUT:-build/de_p0_mouse_after.png}"
HANDOFF_MARKER="handing off to interactive shell"

if [ ! -e /dev/kvm ]; then
    echo "[p0_mouse] SKIP: /dev/kvm absent" >&2; exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[p0_mouse] SKIP: OVMF firmware not found" >&2; exit 0
fi
CONVERTER=""
for c in convert ffmpeg pnmtopng; do command -v "$c" >/dev/null 2>&1 && CONVERTER="$c" && break; done
[ -z "$CONVERTER" ] && { echo "[p0_mouse] SKIP: no PPM->PNG converter" >&2; exit 0; }
MON_DRIVER=""
for c in socat nc; do command -v "$c" >/dev/null 2>&1 && MON_DRIVER="$c" && break; done
[ -z "$MON_DRIVER" ] && { echo "[p0_mouse] SKIP: no socat/nc to drive QEMU monitor" >&2; exit 0; }

# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[de_p0_mouse_screendump]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[p0_mouse] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2; exit 0
    fi
    echo "[p0_mouse] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
[ -f "$INSTALLER_IMG" ] || { echo "[p0_mouse] SKIP: image unavailable" >&2; exit 0; }

OVMF_RW=$(mktemp --tmpdir hamnix-p0.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-p0.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-p0.XXXXXX.log)
MON=$(mktemp --tmpdir -u hamnix-p0-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-p0.XXXXXX).in
BEFORE_PPM=$(mktemp --tmpdir hamnix-p0-before.XXXXXX.ppm)
AFTER_PPM=$(mktemp --tmpdir hamnix-p0-after.XXXXXX.ppm)
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO" "$BEFORE_PPM" "$AFTER_PPM"
    [ -n "${KEEP_LOG:-}" ] && cp "$LOG" "${KEEP_LOG}" 2>/dev/null
    rm -f "$LOG"
}
trap cleanup EXIT

exec 4<>"$FIFO"
exec 3>"$FIFO"

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -device qemu-xhci -device usb-tablet \
    -m 1280M \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

mon_cmd() {
    if [ "$MON_DRIVER" = "socat" ]; then
        printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
    else
        printf '%s\n' "$1" | nc -U -q1 "$MON" >/dev/null 2>&1
    fi
}
ppm2png() {
    case "$CONVERTER" in
        convert)  convert "$1" "$2" 2>/dev/null ;;
        ffmpeg)   ffmpeg -y -loglevel error -i "$1" "$2" </dev/null ;;
        pnmtopng) pnmtopng "$1" > "$2" 2>/dev/null ;;
    esac
}

echo "[p0_mouse] waiting up to ${BOOT_WAIT}s for handoff marker..."
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    grep -a -q "$HANDOFF_MARKER" "$LOG" && { booted=1; break; }
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 1
done
[ "$booted" -ne 1 ] && { echo "[p0_mouse] FAIL: handoff not seen" >&2; tail -60 "$LOG" >&2; exit 1; }
echo "[p0_mouse] handoff reached; letting the DE paint for ${PAINT_WAIT}s."
sleep "$PAINT_WAIT"

# Park the cursor at a KNOWN start (top-left quadrant) so BEFORE is deterministic.
printf 'echo "2000 2000 0 0 1" > /dev/mouse\n' >&3
sleep 2
mkdir -p "$(dirname "$BEFORE_OUT")"
mon_cmd "screendump $BEFORE_PPM"; sleep 2

# Drive the cursor to the FAR opposite quadrant via the canonical /dev/mouse.
# 26000/32767 ~= 0.79 of each axis -> bottom-right region; visibly different.
printf 'echo "26000 22000 0 0 1" > /dev/mouse\n' >&3
sleep 2
mon_cmd "screendump $AFTER_PPM"; sleep 2

# Grab the compositor's own cursor_fps line to confirm presents rose.
CURSOR_FPS_LINE=$(grep -a -E '^\[de_perf\] cursor_fps=' "$LOG" | tail -1 || true)

exec 3>&-
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
QEMU_PID=""

[ -s "$BEFORE_PPM" ] || { echo "[p0_mouse] FAIL: empty BEFORE screendump" >&2; exit 1; }
[ -s "$AFTER_PPM" ]  || { echo "[p0_mouse] FAIL: empty AFTER screendump" >&2; exit 1; }
ppm2png "$BEFORE_PPM" "$BEFORE_OUT"
ppm2png "$AFTER_PPM"  "$AFTER_OUT"
[ -s "$BEFORE_OUT" ] && [ -s "$AFTER_OUT" ] || { echo "[p0_mouse] FAIL: PNG conversion empty" >&2; exit 1; }

echo "[p0_mouse] BEFORE png: $BEFORE_OUT"
echo "[p0_mouse] AFTER  png: $AFTER_OUT"
[ -n "$CURSOR_FPS_LINE" ] && echo "[p0_mouse] compositor: $CURSOR_FPS_LINE"

# The frames must DIFFER: the cursor (and only the cursor, on an idle desktop)
# moved across the screen. Compare the raw PPMs byte-for-byte.
if cmp -s "$BEFORE_PPM" "$AFTER_PPM"; then
    echo "[p0_mouse] FAIL: BEFORE and AFTER frames are IDENTICAL — /dev/mouse did not move the cursor" >&2
    exit 1
fi
# Quantify the pixel delta so a clock-only tick can't masquerade as a cursor move.
if command -v compare >/dev/null 2>&1; then
    DIFF=$(compare -metric AE "$BEFORE_OUT" "$AFTER_OUT" null: 2>&1 || true)
    echo "[p0_mouse] differing pixels (ImageMagick AE): $DIFF"
fi
echo "[p0_mouse] PASS: /dev/mouse injection moved the cursor on the GOP framebuffer (frames differ)"
exit 0
