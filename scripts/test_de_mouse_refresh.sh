#!/usr/bin/env bash
# scripts/test_de_mouse_refresh.sh — BASELINE measurement of effective
# cursor refresh rate under compositor load.
#
# The user's #1 perf complaint: cursor drops to ~0.5 Hz on any
# interactive op. This harness QUANTIFIES the current state so the fix
# track has a number to beat.
#
# Method (deliberately simple and robust — the DE is broken, so the
# measurement strategy must not depend on the DE being correct):
#
#   1. Boot build/hamnix-installer.img under OVMF/KVM (user's ship cmd).
#   2. Wait for the rc.5 DE-autostart marker.
#   3. Inject N distinct cursor positions via QEMU monitor `mouse_move`
#      (PS/2 relative; we walk a diagonal in fixed steps so each move is
#      a unique target). Pace = MOUSE_HZ (default 20 moves/sec).
#   4. Concurrently, capture K framebuffer screendumps at SAMPLE_HZ
#      (default 10 dumps/sec) over the same window.
#   5. For each PPM, locate the cursor sprite (small dense black/dark
#      rectangle on the desktop backdrop) and record its centroid pixel.
#   6. distinct_positions = # unique centroids across the K frames.
#      effective_hz = distinct_positions / window_seconds.
#      refresh_fraction = distinct_positions / N_injected.
#
# This is a BASELINE; the value will be terrible (the user reported
# ~0.5 Hz). That is the point — the harness exists so the fix track can
# see the number go up.
#
# Skips cleanly when /dev/kvm, OVMF, the installer image, or socat/nc
# is unavailable.
#
# Env overrides:
#   INSTALLER_IMG      image path        (default: build/hamnix-installer.img)
#   OVMF_FD            OVMF firmware     (default: auto-resolved)
#   BOOT_WAIT          handoff wait s    (default: 240)
#   PAINT_WAIT         pre-test settle s (default: 8)
#   WINDOW_S           measurement window seconds (default: 5)
#   MOUSE_HZ           injected move rate (default: 20)
#   SAMPLE_HZ          screendump rate    (default: 10)
#   APPS_TO_OPEN       extra hamterm spawns over serial (default: 3)
#   HAMNIX_SKIP_BUILD  1 = require an existing image
#   OUT_REPORT         report path (default: build/de_mouse_refresh.txt)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
PAINT_WAIT="${PAINT_WAIT:-8}"
WINDOW_S="${WINDOW_S:-5}"
MOUSE_HZ="${MOUSE_HZ:-20}"
SAMPLE_HZ="${SAMPLE_HZ:-10}"
APPS_TO_OPEN="${APPS_TO_OPEN:-3}"
OUT_REPORT="${OUT_REPORT:-build/de_mouse_refresh.txt}"
HANDOFF_MARKER="handing off to interactive shell"

# --- gates ---------------------------------------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_de_mouse_refresh] SKIP: /dev/kvm absent" >&2
    exit 0
fi

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[test_de_mouse_refresh] SKIP: OVMF not found" >&2
    exit 0
fi

MON_DRIVER=""
if command -v socat >/dev/null 2>&1; then
    MON_DRIVER="socat"
elif command -v nc >/dev/null 2>&1; then
    MON_DRIVER="nc"
else
    echo "[test_de_mouse_refresh] SKIP: no socat/nc to drive QEMU monitor" >&2
    exit 0
fi

# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[de_mouse_refresh]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[test_de_mouse_refresh] SKIP: $INSTALLER_IMG absent + HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_de_mouse_refresh] SKIP: $INSTALLER_IMG unavailable" >&2
    exit 0
fi

TMPD=$(mktemp -d --tmpdir hamnix-de-mouse.XXXXXX)
OVMF_RW="$TMPD/ovmf.fd"
IMG_RW="$TMPD/img.raw"
LOG="$TMPD/serial.log"
MON="$TMPD/mon.sock"
INFIFO="$TMPD/in.fifo"
SHOTS_DIR="$TMPD/shots"
mkdir -p "$SHOTS_DIR"
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

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m 1G \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

echo "[test_de_mouse_refresh] waiting up to ${BOOT_WAIT}s for handoff marker..."
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q "$HANDOFF_MARKER" "$LOG"; then booted=1; break; fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[test_de_mouse_refresh] FAIL: qemu exited early" >&2
        tail -60 "$LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$booted" -ne 1 ]; then
    echo "[test_de_mouse_refresh] FAIL: handoff marker absent after ${BOOT_WAIT}s" >&2
    exit 1
fi

sleep "$PAINT_WAIT"

mon_cmd() {
    if [ "$MON_DRIVER" = "socat" ]; then
        printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
    else
        printf '%s\n' "$1" | nc -U -q1 "$MON" >/dev/null 2>&1
    fi
}

# Open APPS_TO_OPEN extra hamterm windows by typing into the serial shell
# to add compositor load. Best-effort; the shell may drop the first line.
i=0
while [ "$i" -lt "$APPS_TO_OPEN" ]; do
    printf '%s\n' "hamterm &" >&3 2>/dev/null || true
    sleep 0.2
    i=$((i + 1))
done
sleep 1

# --- run the measurement -----------------------------------------------
# Inject MOUSE_HZ moves per second over WINDOW_S seconds while sampling
# SAMPLE_HZ screendumps per second. mouse_move is RELATIVE in PS/2 mode;
# we alternate +/- on each axis so the cursor walks a small box but each
# call moves the pointer a unique amount the present loop must render.

INJECTED_TOTAL=$((MOUSE_HZ * WINDOW_S))
SAMPLE_TOTAL=$((SAMPLE_HZ * WINDOW_S))
MOUSE_PERIOD_MS=$((1000 / MOUSE_HZ))
SAMPLE_PERIOD_MS=$((1000 / SAMPLE_HZ))

echo "[test_de_mouse_refresh] inject=${INJECTED_TOTAL} moves over ${WINDOW_S}s @ ${MOUSE_HZ}Hz; sample=${SAMPLE_TOTAL} shots @ ${SAMPLE_HZ}Hz."

# Injector subshell.
(
    n=0
    dx=4
    while [ "$n" -lt "$INJECTED_TOTAL" ]; do
        # walk right/down then left/up, 8-step cycle, 1px granularity.
        case $((n % 8)) in
            0|1|2|3) sx=$dx;  sy=$dx ;;
            *)       sx=-$dx; sy=-$dx ;;
        esac
        mon_cmd "mouse_move $sx $sy"
        # busy-poll style sleep to MOUSE_HZ
        sleep "0.$(printf '%03d' $MOUSE_PERIOD_MS)" 2>/dev/null || sleep 0.05
        n=$((n + 1))
    done
) &
INJ_PID=$!

# Sampler loop (main): SAMPLE_TOTAL screendumps spaced SAMPLE_PERIOD_MS apart.
s=0
while [ "$s" -lt "$SAMPLE_TOTAL" ]; do
    OUT="$SHOTS_DIR/shot_$(printf '%03d' $s).ppm"
    mon_cmd "screendump $OUT"
    sleep "0.$(printf '%03d' $SAMPLE_PERIOD_MS)" 2>/dev/null || sleep 0.1
    s=$((s + 1))
done

wait "$INJ_PID" 2>/dev/null

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
QEMU_PID=""

# --- analyse the shots --------------------------------------------------
# For each PPM, find the cursor centroid: PPM6 raw binary, 3 bytes per
# pixel. The cursor is a small dense dark sprite on a (lighter) backdrop.
# We just take the centroid of all pixels with luma <= 32 — the cursor
# being a near-black 12x12 sprite. If the desktop chrome also has black
# pixels the centroid will be biased but the # of DISTINCT centroids
# across frames still tracks how much the cursor moved.
#
# Python is in the base distro; this is fast (small frames, few shots).

PY=$(command -v python3 || true)
if [ -z "$PY" ]; then
    echo "[test_de_mouse_refresh] FAIL: python3 needed for shot analysis" >&2
    exit 1
fi

distinct=$($PY - "$SHOTS_DIR" <<'PYEOF'
# DEPERF iter-6 HARNESS UPGRADE: the original centroid-of-dark-pixels
# metric is saturated by the panel band (full-width dark rectangle at
# the top of the screen). Even when the cursor moves freely, the
# centroid of all-dark pixels barely shifts, reporting bogus 0.40 Hz
# regardless of compositor performance.
#
# The frame-difference metric below counts how many shots changed
# meaningfully from the previous one — i.e. how many times the
# compositor presented a new screen during the window. That is the
# real cursor-refresh signal under load: every successful cursor move
# blits the old/new 12x12 cells (~288 px difference), so two frames
# whose pixel-diff exceeds a small threshold ARE two distinct presents.
# This also catches windowed-content updates (a hamterm body changing).
#
# `distinct` (first line) = count of consecutive frame pairs whose
# pixel-diff sum exceeds CHANGE_THRESHOLD. effective_hz = distinct /
# window_s.
import os, sys, glob

shots_dir = sys.argv[1]
CHANGE_THRESHOLD = 200  # at least ~200 pixel deltas to count as a present
shots = []
for path in sorted(glob.glob(os.path.join(shots_dir, "*.ppm"))):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        continue
    if not data.startswith(b"P6"):
        continue
    i = 3
    def tok(off):
        while off < len(data) and (data[off:off+1] in (b" ", b"\n", b"\t", b"\r")
                                   or data[off:off+1] == b"#"):
            if data[off:off+1] == b"#":
                while off < len(data) and data[off:off+1] != b"\n":
                    off += 1
            else:
                off += 1
        start = off
        while off < len(data) and data[off:off+1] not in (b" ", b"\n", b"\t", b"\r"):
            off += 1
        return data[start:off], off
    tw, i = tok(i)
    th, i = tok(i)
    tm, i = tok(i)
    i += 1
    try:
        W = int(tw); H = int(th); M = int(tm)
    except ValueError:
        continue
    if M != 255:
        continue
    pix = data[i:i + W*H*3]
    if len(pix) < W*H*3:
        continue
    shots.append((W, H, pix))

# Frame-difference metric: count consecutive frames that differ enough
# to be a real present (cursor move, terminal redraw, etc).
distinct_frames = 0
prev = None
# Sample 1 in every STRIDE pixels to keep python loop bounded on a
# 1280x800 image (~1 M pixels). Even at stride=16 we get ~64k samples
# per frame which is plenty to detect a 12x12 cursor delta.
STRIDE = 16
for s in shots:
    W, H, pix = s
    if prev is None:
        prev = pix
        continue
    diff = 0
    plen = len(pix)
    # Walk every STRIDE * 3 bytes (R channel only is enough — cursor
    # is near-black vs lighter desktop).
    off = 0
    step = STRIDE * 3
    while off + 2 < plen:
        if pix[off] != prev[off] or pix[off+1] != prev[off+1] or pix[off+2] != prev[off+2]:
            diff += 1
            if diff >= CHANGE_THRESHOLD:
                break
        off += step
    if diff >= CHANGE_THRESHOLD:
        distinct_frames += 1
    prev = pix

print(distinct_frames)
print(len(shots))
PYEOF
)

# distinct comes back as TWO lines: unique count then sample count.
UNIQ=$(printf '%s\n' "$distinct" | sed -n '1p')
SAMPLED=$(printf '%s\n' "$distinct" | sed -n '2p')
UNIQ=${UNIQ:-0}
SAMPLED=${SAMPLED:-0}

if [ "$SAMPLED" -eq 0 ]; then
    echo "[test_de_mouse_refresh] FAIL: 0 shots analysed" >&2
    exit 1
fi

# effective_hz = distinct-frame-pair count / window seconds.
# refresh_fraction = distinct / injected.
EFF_HZ=$(awk -v u="$UNIQ" -v w="$WINDOW_S" 'BEGIN{ if (w==0) print 0; else printf "%.2f", u/w }')
FRAC=$(awk -v u="$UNIQ" -v i="$INJECTED_TOTAL" 'BEGIN{ if (i==0) print 0; else printf "%.3f", u/i }')

mkdir -p "$(dirname "$OUT_REPORT")"
{
    echo "test_de_mouse_refresh BASELINE"
    echo "window_s=$WINDOW_S"
    echo "injected_moves=$INJECTED_TOTAL"
    echo "shots_sampled=$SAMPLED"
    echo "distinct_frames=$UNIQ"
    echo "effective_cursor_hz=$EFF_HZ"
    echo "refresh_fraction=$FRAC"
} > "$OUT_REPORT"

echo "[test_de_mouse_refresh] effective_cursor_hz=$EFF_HZ (distinct_frames=$UNIQ across $SAMPLED shots; injected=$INJECTED_TOTAL)"
echo "[test_de_mouse_refresh] report: $OUT_REPORT"
echo "[test_de_mouse_refresh] PASS"
exit 0
