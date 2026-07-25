#!/usr/bin/env bash
# scripts/test_de_overlay_wiring.sh — VISUAL proof that the compositor-owned
# overlays (End-Session dialog + message-tray history) POP when the panel/menu
# requests them through the /dev/wsys/run/launch slot.
#
# The scene panel's WK_SESSION / WK_TRAY clicks (and the Applications-menu
# "Log Out" row) enqueue the overlay's program PATH into /dev/wsys/run/launch.
# hamUId's run_drain_launch() observes the serial bump and — because the path
# names a resident overlay — calls session_open() / sets TRAY_OPEN=1 instead of
# spawning a duplicate window (see drain_intercept_overlay in user/hamUId.ad).
#
# This test reproduces exactly that request from the interactive serial shell:
#   echo /bin/hamsessui > /dev/wsys/run/launch   -> End-Session modal pops
#   echo /bin/hamtray    > /dev/wsys/run/launch   -> message-tray panel pops
# then screendumps the framebuffer so a reviewer can SEE the dialog/tray.
#
# Same boot plumbing as scripts/test_de_mate_applets.sh.
set -u
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
OUT_DIR="${OUT_DIR:-build/de_overlay_wiring}"
HANDOFF_MARKER="${HANDOFF_MARKER:-handing off to interactive shell}"
BOOT_WAIT="${BOOT_WAIT:-240}"
PAINT_WAIT="${PAINT_WAIT:-22}"

[ -e /dev/kvm ] || { echo "[overlay] SKIP: /dev/kvm absent" >&2; exit 0; }
OVMF_FD=""
for c in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
    [ -f "$c" ] && { OVMF_FD="$c"; break; }
done
[ -z "$OVMF_FD" ] && { echo "[overlay] SKIP: OVMF firmware not found" >&2; exit 0; }
CONVERTER=""
for c in convert pnmtopng ffmpeg; do command -v "$c" >/dev/null 2>&1 && { CONVERTER="$c"; break; }; done
[ -z "$CONVERTER" ] && { echo "[overlay] SKIP: no PPM->PNG converter" >&2; exit 0; }
MON_DRIVER=""
for c in socat nc; do command -v "$c" >/dev/null 2>&1 && { MON_DRIVER="$c"; break; }; done
[ -z "$MON_DRIVER" ] && { echo "[overlay] SKIP: no socat/nc" >&2; exit 0; }
[ -f "$INSTALLER_IMG" ] || { echo "[overlay] SKIP: $INSTALLER_IMG absent" >&2; exit 0; }
# Stale-artifact guard: this gate BOOTS a pre-existing image it did not
# build. Booting a stale one silently is the 2026-07-24 false-negative
# class — be loud about it. shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
installer_img_warn_if_stale "$INSTALLER_IMG" "[de_overlay_wiring]"

OVMF_RW=$(mktemp --tmpdir hamnix-ow.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-ow.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-ow.XXXXXX.log)
MON=$(mktemp --tmpdir -u hamnix-ow-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-ow.XXXXXX).in
SESS_PPM=$(mktemp --tmpdir hamnix-ow-sess.XXXXXX.ppm)
TRAY_PPM=$(mktemp --tmpdir hamnix-ow-tray.XXXXXX.ppm)
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
mkdir -p "$OUT_DIR"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO" "$SESS_PPM" "$TRAY_PPM"
    cp "$LOG" "$OUT_DIR/serial.log" 2>/dev/null
    rm -f "$LOG"
}
trap cleanup EXIT
exec 4<>"$FIFO"; exec 3>"$FIFO"

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -device qemu-xhci -device usb-tablet \
    -m 2G \
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

echo "[overlay] waiting up to ${BOOT_WAIT}s for handoff..."
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    grep -a -q "$HANDOFF_MARKER" "$LOG" && { booted=1; break; }
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 1
done
[ "$booted" -ne 1 ] && { echo "[overlay] FAIL: handoff not seen" >&2; tail -40 "$LOG" >&2; exit 1; }
echo "[overlay] handoff reached; DE paint ${PAINT_WAIT}s."
sleep "$PAINT_WAIT"

# --- 1) Spawn the self-opening End-Session scene modal ---------------------
# hamsessui is now a scene client that paints the dialog immediately on
# launch (it owns its window + handles its own row clicks). The panel
# session button does exactly this spawn.
printf 'hamsessui &\n' >&3 ; sleep 5
mon_cmd "screendump $SESS_PPM"; sleep 2

# --- 2) Spawn the About-this-system scene dialog ---------------------------
printf 'hamabout &\n' >&3 ; sleep 5
mon_cmd "screendump $TRAY_PPM"; sleep 2

exec 3>&-
kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""

[ -s "$SESS_PPM" ] || { echo "[overlay] FAIL: empty session screendump" >&2; exit 1; }
[ -s "$TRAY_PPM" ] || { echo "[overlay] FAIL: empty tray screendump" >&2; exit 1; }
ppm2png "$SESS_PPM" "$OUT_DIR/session_modal.png"
ppm2png "$TRAY_PPM" "$OUT_DIR/tray_panel.png"

echo "[overlay] session modal png : $OUT_DIR/session_modal.png"
echo "[overlay] tray panel   png : $OUT_DIR/tray_panel.png"
echo "[overlay] serial log       : $OUT_DIR/serial.log"
echo "[overlay] REVIEW: view both PNGs — modal must show 4 buttons; tray must show a header + row."
exit 0
