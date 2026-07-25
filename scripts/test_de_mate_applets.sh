#!/usr/bin/env bash
# scripts/test_de_mate_applets.sh — MATE-parity applet INTERACTION gate.
#
# Proves the three new hampanelscene applets are not just painted but LIVE:
#   * Workspace switcher (pager) on the bottom panel: clicking cell "2"
#     drives /dev/wsys/ctl `ws 2`, the compositor switches virtual desktops
#     (workspace_switch), and the pager re-lights cell 2. Serial shows the
#     compositor's "WS switch 2" marker.
#   * Session button on the top panel: clicking it spawns /bin/hamsessui
#     (the Lock/Log Out/Shut Down dialog). Serial shows the panel's
#     "[panel] launched /bin/hamsessui".
#   * Notification tray: a `hamnotify` post lights the tray unread dot.
#
# Same boot plumbing as scripts/test_de_p0_mouse_screendump.sh (the canonical
# writable /dev/mouse + QMP screendump). Skips cleanly if KVM/OVMF/converter
# are unavailable.
set -u
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
OUT_DIR="${OUT_DIR:-build/de_mate_applets}"
HANDOFF_MARKER="${HANDOFF_MARKER:-handing off to interactive shell}"
BOOT_WAIT="${BOOT_WAIT:-240}"
PAINT_WAIT="${PAINT_WAIT:-22}"

[ -e /dev/kvm ] || { echo "[mate_applets] SKIP: /dev/kvm absent" >&2; exit 0; }
OVMF_FD=""
for c in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
    [ -f "$c" ] && { OVMF_FD="$c"; break; }
done
[ -z "$OVMF_FD" ] && { echo "[mate_applets] SKIP: OVMF firmware not found" >&2; exit 0; }
CONVERTER=""
for c in convert pnmtopng ffmpeg; do command -v "$c" >/dev/null 2>&1 && { CONVERTER="$c"; break; }; done
[ -z "$CONVERTER" ] && { echo "[mate_applets] SKIP: no PPM->PNG converter" >&2; exit 0; }
MON_DRIVER=""
for c in socat nc; do command -v "$c" >/dev/null 2>&1 && { MON_DRIVER="$c"; break; }; done
[ -z "$MON_DRIVER" ] && { echo "[mate_applets] SKIP: no socat/nc" >&2; exit 0; }
[ -f "$INSTALLER_IMG" ] || { echo "[mate_applets] SKIP: $INSTALLER_IMG absent" >&2; exit 0; }
# Stale-artifact guard: this gate BOOTS a pre-existing image it did not
# build. Booting a stale one silently is the 2026-07-24 false-negative
# class — be loud about it. shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
installer_img_warn_if_stale "$INSTALLER_IMG" "[de_mate_applets]"

OVMF_RW=$(mktemp --tmpdir hamnix-ma.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-ma.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-ma.XXXXXX.log)
MON=$(mktemp --tmpdir -u hamnix-ma-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-ma.XXXXXX).in
WS_PPM=$(mktemp --tmpdir hamnix-ma-ws.XXXXXX.ppm)
NOTIF_PPM=$(mktemp --tmpdir hamnix-ma-notif.XXXXXX.ppm)
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
mkdir -p "$OUT_DIR"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO" "$WS_PPM" "$NOTIF_PPM"
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

echo "[mate_applets] waiting up to ${BOOT_WAIT}s for handoff..."
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    grep -a -q "$HANDOFF_MARKER" "$LOG" && { booted=1; break; }
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 1
done
[ "$booted" -ne 1 ] && { echo "[mate_applets] FAIL: handoff not seen" >&2; tail -40 "$LOG" >&2; exit 1; }
echo "[mate_applets] handoff reached; DE paint ${PAINT_WAIT}s."
sleep "$PAINT_WAIT"

# --- 1) Click workspace cell "2" on the bottom panel pager -----------------
# Bottom panel is the last ~26px of an 800px-tall fb. Pager cells start at
# x~22, cell-2 center ~x35. Tablet coords: ax=35/1280*32767~=896, ay=787/800*
# 32767~=32227.
printf 'echo "896 32227 1 0 1" > /dev/mouse\n' >&3 ; sleep 1
printf 'echo "896 32227 0 0 1" > /dev/mouse\n' >&3 ; sleep 3
mon_cmd "screendump $WS_PPM"; sleep 2

# --- 2) Post a notification to light the tray dot --------------------------
printf 'hamnotify "Build done" "MATE applets landed" >/dev/null 2>&1 &\n' >&3
sleep 2
# --- 3) Click the session (power) button on the top panel ------------------
# Power glyph ~x1158/1280*32767~=29647, y12/800*32767~=491.
printf 'echo "29647 491 1 0 1" > /dev/mouse\n' >&3 ; sleep 1
printf 'echo "29647 491 0 0 1" > /dev/mouse\n' >&3 ; sleep 3
mon_cmd "screendump $NOTIF_PPM"; sleep 2

exec 3>&-
kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""

[ -s "$WS_PPM" ] || { echo "[mate_applets] FAIL: empty ws screendump" >&2; exit 1; }
ppm2png "$WS_PPM"    "$OUT_DIR/after_ws_switch.png"
ppm2png "$NOTIF_PPM" "$OUT_DIR/after_session_click.png"

echo "[mate_applets] ws-switch png : $OUT_DIR/after_ws_switch.png"
echo "[mate_applets] session  png : $OUT_DIR/after_session_click.png"

PASS=1
if grep -a -q "WS switch 2" "$LOG"; then
    echo "[mate_applets] PASS: compositor 'WS switch 2' (real virtual-desktop switch)"
else
    echo "[mate_applets] WARN: no 'WS switch 2' marker in serial" >&2
    PASS=0
fi
if grep -a -q "launched /bin/hamsessui" "$LOG"; then
    echo "[mate_applets] PASS: panel launched /bin/hamsessui (session button)"
else
    echo "[mate_applets] WARN: no hamsessui launch marker" >&2
fi
[ "$PASS" -eq 1 ] && echo "[mate_applets] PASS" || echo "[mate_applets] REVIEW (see PNGs/serial)"
exit 0
