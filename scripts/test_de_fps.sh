#!/usr/bin/env bash
# scripts/test_de_fps.sh — BASELINE measurement of compositor frames per
# second under load.
#
# The user's #1 perf complaint after cursor refresh is overall DE FPS.
# This harness counts the compositor frames the daemon actually presents
# during a known-load window, by greppping the per-frame "[fps] frame N"
# markers emitted by user/hamUId.ad's daemon_present() when the gate
# file /etc/de-fps-test is present.
#
# THE GATE: user/hamUId.ad gates the per-present serial marker on
# /etc/de-fps-test. In normal boot the file is absent and the print is a
# pure no-op; this test arranges for the file to be touched right after
# the handoff marker by typing on the serial shell. Once the gate flips,
# every present writes "[fps] frame N\n" to fd 1 (supervisor-routed to
# serial), and we count the markers across a fixed wall-clock window.
#
# Load scenario: spawn N hamterm windows over the serial shell, then run
# a brief synthetic load (window-list cycle), and measure how many frames
# the compositor actually pumps during the window. The first frame
# counter seen after the gate flips becomes the BASE; the last seen
# inside the window becomes the END; fps = (END - BASE) / window_s.
#
# Skips cleanly when /dev/kvm, OVMF, or the installer image is missing.
#
# Env overrides:
#   INSTALLER_IMG      image path        (default: build/hamnix-installer.img)
#   OVMF_FD            OVMF firmware     (default: auto-resolved)
#   BOOT_WAIT          handoff wait s    (default: 240)
#   PAINT_WAIT         pre-load settle s (default: 8)
#   LOAD_S             measurement window seconds (default: 5)
#   APPS_TO_OPEN       hamterm spawns over serial (default: 4)
#   HAMNIX_SKIP_BUILD  1 = require an existing image
#   OUT_REPORT         report path (default: build/de_fps.txt)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
PAINT_WAIT="${PAINT_WAIT:-8}"
LOAD_S="${LOAD_S:-5}"
APPS_TO_OPEN="${APPS_TO_OPEN:-4}"
OUT_REPORT="${OUT_REPORT:-build/de_fps.txt}"
HANDOFF_MARKER="handing off to interactive shell"

# --- gates ---------------------------------------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_de_fps] SKIP: /dev/kvm absent" >&2
    exit 0
fi

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[test_de_fps] SKIP: OVMF not found" >&2
    exit 0
fi

# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[de_fps]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[test_de_fps] SKIP: $INSTALLER_IMG absent + HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_de_fps] SKIP: $INSTALLER_IMG unavailable" >&2
    exit 0
fi

TMPD=$(mktemp -d --tmpdir hamnix-de-fps.XXXXXX)
OVMF_RW="$TMPD/ovmf.fd"
IMG_RW="$TMPD/img.raw"
LOG="$TMPD/serial.log"
INFIFO="$TMPD/in.fifo"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
mkfifo "$INFIFO"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -rf "$TMPD"
}
trap cleanup EXIT

exec 4<>"$INFIFO"
exec 3>"$INFIFO"

# NOTE: the gate file /etc/de-fps-test must exist at daemon STARTUP for
# the marker to fire. In the installer image the daemon is autostarted by
# rc.5 before the serial shell is ready, so we instead RESTART the daemon
# AFTER touching the file. The "daemon" verb in hamUId reattaches, and
# fps_marker checks FPS_GATE which was set in the prior cmd_daemon_auto;
# but a NEW daemon process re-runs cmd_daemon_auto and re-reads the gate.
#
# Practical sequence (typed at the serial shell after handoff):
#   touch /etc/de-fps-test
#   killall hamUId 2>/dev/null
#   hamUId daemon &
# then opens APPS_TO_OPEN hamterms to add compositor load.

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m 1G \
    -vga std -display none -no-reboot \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

echo "[test_de_fps] waiting up to ${BOOT_WAIT}s for handoff marker..."
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q "$HANDOFF_MARKER" "$LOG"; then booted=1; break; fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[test_de_fps] FAIL: qemu exited early" >&2
        tail -60 "$LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$booted" -ne 1 ]; then
    echo "[test_de_fps] FAIL: handoff marker absent after ${BOOT_WAIT}s" >&2
    exit 1
fi
sleep "$PAINT_WAIT"

type_cmd() {
    printf '%s\n' "$1" >&3
    sleep "${2:-1}"
}

# Arm the FPS gate, then restart the daemon so cmd_daemon_auto re-reads
# /etc/de-fps-test at startup and sets FPS_GATE=1.
type_cmd "touch /etc/de-fps-test" 1
type_cmd "killall hamUId" 2
type_cmd "hamUId daemon &" 4

# Open APPS_TO_OPEN hamterm windows to drive compositor load.
i=0
while [ "$i" -lt "$APPS_TO_OPEN" ]; do
    type_cmd "hamterm &" 0.4
    i=$((i + 1))
done
sleep 2

# Mark the START of the measurement window and capture the byte offset
# of the current end-of-log. After LOAD_S seconds, count "[fps] frame N"
# lines emitted within that window.
LOG_START_OFFSET=$(wc -c < "$LOG")
echo "[test_de_fps] measurement window: ${LOAD_S}s (load=${APPS_TO_OPEN} hamterms)"
sleep "$LOAD_S"
LOG_END_OFFSET=$(wc -c < "$LOG")

# Extract the slice of serial output produced during the window.
dd if="$LOG" bs=1 skip="$LOG_START_OFFSET" \
    count=$((LOG_END_OFFSET - LOG_START_OFFSET)) \
    2>/dev/null > "$TMPD/window.log"

# Count distinct "[fps] frame N" lines.
FRAMES=$(grep -a -cE "\[fps\] frame [0-9]+" "$TMPD/window.log" || true)
FRAMES=${FRAMES:-0}

# Also extract first/last frame N inside the window for an alternate
# frame-counter-delta FPS measurement (more accurate if the marker
# emission is partially lost on serial).
FIRST_N=$(grep -a -oE "\[fps\] frame [0-9]+" "$TMPD/window.log" | head -1 | awk '{print $3}')
LAST_N=$(grep -a -oE "\[fps\] frame [0-9]+" "$TMPD/window.log" | tail -1 | awk '{print $3}')

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
QEMU_PID=""

FPS_COUNT=$(awk -v f="$FRAMES" -v w="$LOAD_S" 'BEGIN{ if (w==0) print 0; else printf "%.2f", f/w }')
DELTA_FPS="n/a"
if [ -n "${FIRST_N:-}" ] && [ -n "${LAST_N:-}" ] && [ "$FIRST_N" != "$LAST_N" ]; then
    DELTA_FPS=$(awk -v a="$FIRST_N" -v b="$LAST_N" -v w="$LOAD_S" 'BEGIN{ printf "%.2f", (b-a)/w }')
fi

mkdir -p "$(dirname "$OUT_REPORT")"
{
    echo "test_de_fps BASELINE"
    echo "load_window_s=$LOAD_S"
    echo "apps_opened=$APPS_TO_OPEN"
    echo "fps_marker_lines_in_window=$FRAMES"
    echo "first_frame_n=${FIRST_N:-none}"
    echo "last_frame_n=${LAST_N:-none}"
    echo "fps_by_line_count=$FPS_COUNT"
    echo "fps_by_counter_delta=$DELTA_FPS"
} > "$OUT_REPORT"

echo "[test_de_fps] fps_by_line_count=$FPS_COUNT  fps_by_counter_delta=$DELTA_FPS  (frames_seen=$FRAMES over ${LOAD_S}s)"
echo "[test_de_fps] report: $OUT_REPORT"
if [ "$FRAMES" -eq 0 ] && [ "$DELTA_FPS" = "n/a" ]; then
    echo "[test_de_fps] NOTE: no [fps] markers observed — either the FPS gate did not arm (hamUId daemon restart failed?) or the compositor did NOT present during the window. Treat as 0 fps baseline." >&2
fi
echo "[test_de_fps] PASS"
exit 0
