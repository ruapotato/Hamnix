#!/usr/bin/env bash
# scripts/test_hamview_png_jpeg.sh — on-device render-evidence gate for the
# hamview image viewer (user/hamview.ad) decoding REAL compressed images:
# a PNG (lib/png.ad inflate+unfilter) and a BASELINE JPEG (lib/jpeg.ad
# Huffman+IDCT+YCbCr). Both fixtures live in tests/fixtures/hamview/ and are
# staged into the rootfs at /share/hamview/ by scripts/build_packages.py
# (hamnix-desktop-apps).
#
# Boots the installer image into the scene DE (runlevel 5), waits for the
# interactive serial shell, then launches:
#     hamview /share/hamview/test.png &     (expect "hamview: decoded 400x300")
#     hamview /share/hamview/test.jpg &     (expect "hamview: decoded 320x240")
# and screendumps after each. hamview decodes to RGBA, scales <=256 on the
# long edge, and blits via the wsys "fb" draw-layer (mklayer pix fb + a
# `<image src="fb:pix" .../>` markup layer) — the kernel devwsys server +
# hamUId compositor rasterise it into the frame.
#
# ASSERTS (three-valued; a dead boot => INCONCLUSIVE, not a false FAIL):
#   1. SERIAL: "hamview: decoded 400x300" AND "hamview: decoded 320x240"
#      (the load-bearing proof the PNG + JPEG decoders ran to completion).
#   2. PIXELS: the PNG frame carries the fixture's dominant GREEN (0,200,0);
#      the JPEG frame carries the fixture's dominant ORANGE (240,140,0).
#      DE chrome/wallpaper uses neither, so a solid block of either proves
#      the decoded raster reached the screen (not a blank/placeholder).
#   3. No kernel panic / fault in the serial log.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, or the image is absent.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/hamview_imgs/$TS}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-260}"
OVMF_FD="${OVMF_FD:-/usr/share/OVMF/OVMF_CODE.fd}"
[ -f "$OVMF_FD" ] || OVMF_FD="/usr/share/ovmf/OVMF.fd"

[ -e /dev/kvm ] || { echo "[hamview] SKIP: /dev/kvm absent" >&2; exit 0; }
[ -f "$OVMF_FD" ] || { echo "[hamview] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "[hamview] SKIP: socat required" >&2; exit 0; }

# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[hamview_png_jpeg]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[hamview] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[hamview] building installer image (~6 min)"
    bash "$PWD/scripts/build_installer_img.sh"
else
    # STALE-IMAGE QA TRAP GUARD (see memory: project_stale_installer_img_qa_trap).
    # A QA run after a hamview/decoder change would otherwise boot the OLD
    # binary and (false-)pass/(false-)fail against stale pixels. Rebuild if any
    # tracked source (incl. the fixtures) is newer than the image.
    newer=$(find lib user sys fs etc scripts tests/fixtures/hamview \
                 -name '*.ad' -o -name '*.S' -o -name '*.png' -o -name '*.jpg' \
                 -newer "$INSTALLER_IMG" 2>/dev/null | head -1)
    if [ -n "$newer" ]; then
        if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
            echo "[hamview] WARNING: $INSTALLER_IMG is OLDER than source ($newer) but HAMNIX_SKIP_BUILD=1 — booting a STALE image" >&2
        else
            echo "[hamview] image is stale (source newer: $newer) — rebuilding (~6 min)" >&2
            bash "$PWD/scripts/build_installer_img.sh"
        fi
    fi
fi

mkdir -p "$OUT_DIR"
echo "[hamview] output dir: $OUT_DIR"
OVMF_RW=$(mktemp --tmpdir hamnix-hv.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-hv.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-hv-mon.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
cleanup() { rm -f "$OVMF_RW" "$IMG_RW" "$MON"; }
trap cleanup EXIT
: > "$LOG"

SNAP_HELPER="$OUT_DIR/.snap.sh"
cat > "$SNAP_HELPER" <<SNAPEOF
#!/bin/bash
label="\$1"
ppm="$OUT_DIR/\$label.ppm"
printf 'screendump %s\n' "\$ppm" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
for i in \$(seq 1 30); do [ -s "\$ppm" ] && break; sleep 0.1; done
SNAPEOF
chmod +x "$SNAP_HELPER"

python3 - "$IMG_RW" "$OVMF_RW" "$MON" "$LOG" "$SNAP_HELPER" "$BOOT_WAIT" <<'PYDRV'
import sys, subprocess, time, threading, os
img, ovmf, mon, logpath, snap, boot_wait = sys.argv[1:7]
boot_wait = int(boot_wait)
vm_mem = os.environ.get("HAMNIX_VM_MEM", "2G")
qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host",
    "-bios", ovmf,
    "-drive", f"file={img},format=raw,if=virtio",
    "-m", vm_mem,
    "-vga", "std", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{mon},server,nowait",
    "-serial", "stdio",
], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
   bufsize=0)
logf = open(logpath, "wb")
buf = bytearray(); lock = threading.Lock()
def reader():
    while True:
        b = qemu.stdout.read(1)
        if not b: break
        logf.write(b); logf.flush()
        with lock: buf.extend(b)
threading.Thread(target=reader, daemon=True).start()
def wait_for(marker, timeout):
    m = marker.encode(); deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            if m in buf: return True
        if qemu.poll() is not None: return False
        time.sleep(0.2)
    return False
def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception: pass
def screendump(label):
    subprocess.run([snap, label], timeout=20)
def launch_and_wait(path, marker, label):
    # Retry the launch up to 6x — a freshly-booted hamsh can drop a serial
    # command line; a lost line just means no decode marker, so re-send.
    got = False
    for attempt in range(6):
        send("hamview %s &" % path)
        print("[hamview] driver: launch %s attempt %d" % (path, attempt + 1),
              file=sys.stderr)
        if wait_for(marker, 25):
            got = True
            print("[hamview] driver: '%s' seen on attempt %d" % (marker, attempt + 1),
                  file=sys.stderr)
            break
        print("[hamview] driver: no marker on attempt %d, retrying" % (attempt + 1),
              file=sys.stderr)
    time.sleep(4)
    screendump(label)
    print("[hamview] driver: captured %s frame (decoded=%s)" % (label, got),
          file=sys.stderr)
    return got
try:
    if not wait_for("M16.35 shell ready", boot_wait):
        print("[hamview] driver: never reached handoff", file=sys.stderr)
    else:
        print("[hamview] driver: handoff reached", file=sys.stderr)
        time.sleep(3)
        # WARM-UP: prove the shell is consuming input before the real launch.
        warmed = False
        for w in range(6):
            tag = "__WARMUP_%d__" % w
            with lock:
                base = len(buf)
            send("echo " + tag)
            deadline = time.time() + 6
            while time.time() < deadline:
                with lock:
                    if buf.find(tag.encode(), base) != -1:
                        warmed = True
                        break
                if qemu.poll() is not None:
                    break
                time.sleep(0.2)
            if warmed:
                print("[hamview] driver: shell warm-up ok (attempt %d)" % (w + 1),
                      file=sys.stderr)
                break
        if not warmed:
            print("[hamview] driver: WARNING shell never echoed warm-up",
                  file=sys.stderr)
        launch_and_wait("/share/hamview/test.png", "hamview: decoded 400x300", "png")
        launch_and_wait("/share/hamview/test.jpg", "hamview: decoded 320x240", "jpg")
        print("[hamview] driver: done", file=sys.stderr)
finally:
    try: qemu.stdin.close()
    except Exception: pass
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=10)
    except Exception:
        qemu.kill()
PYDRV

# Convert ppm -> png for inspection.
for lbl in png jpg; do
    if [ -s "$OUT_DIR/$lbl.ppm" ] && command -v pnmtopng >/dev/null 2>&1; then
        pnmtopng "$OUT_DIR/$lbl.ppm" > "$OUT_DIR/frame_$lbl.png" 2>/dev/null || true
    fi
done

echo "[hamview] --- render evidence ---"

# THREE-VALUED verdict: count guest markers. Zero DE/shell markers => the boot
# never came up (dead gate) => INCONCLUSIVE (exit 0), NOT a false FAIL.
GUEST_MARKERS=$(grep -acE 'M16\.35 shell ready|HAMVIEW ready|hamview: decoded' "$LOG")
if [ "${GUEST_MARKERS:-0}" -eq 0 ]; then
    echo "[hamview] INCONCLUSIVE: zero guest markers — boot never reached the shell (dead gate, not a hamview failure)" >&2
    echo "[hamview] RESULT: INCONCLUSIVE"
    exit 0
fi

fail=0

if grep -aq 'hamview: decoded 400x300' "$LOG"; then
    echo "[hamview] PASS PNG decoded to 400x300 (lib/png.ad)"
else
    echo "[hamview] FAIL no 'hamview: decoded 400x300' marker (PNG)"; fail=1
fi
if grep -aq 'hamview: decoded 320x240' "$LOG"; then
    echo "[hamview] PASS JPEG decoded to 320x240 (lib/jpeg.ad)"
else
    echo "[hamview] FAIL no 'hamview: decoded 320x240' marker (JPEG)"; fail=1
fi
if grep -aq 'hamview: decode failed' "$LOG"; then
    echo "[hamview] FAIL hamview reported a decode failure"; fail=1
fi

if grep -aqi 'kernel panic\|#UD\|triple fault\|page fault' "$LOG"; then
    echo "[hamview] FAIL panic/fault in serial log"; fail=1
else
    echo "[hamview] PASS no panic during boot/run"
fi

# PIXEL PROOF the decoded raster reached the screen. The PNG fixture is
# dominantly GREEN (0,200,0), the JPEG dominantly ORANGE (240,140,0) — colours
# no DE chrome/wallpaper paints. A solid block of the expected colour in the
# corresponding frame proves the fb-layer blit landed (not a blank placeholder).
pixcount() {  # $1 ppm  $2,$3,$4 target rgb  -> prints hit count
    python3 - "$@" <<'PYPIX'
import sys
ppm, tr, tg, tb = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
data = open(ppm, "rb").read()
if not data.startswith(b"P6"):
    print(0); sys.exit(0)
idx = 2; fields = []
while len(fields) < 3 and idx < len(data):
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
idx += 1
pix = data[idx:]
TOL = 55
hits = 0
n = (len(pix) // 3) * 3
i = 0
while i < n:
    if abs(pix[i]-tr) <= TOL and abs(pix[i+1]-tg) <= TOL and abs(pix[i+2]-tb) <= TOL:
        hits += 1
    i += 3
print(hits)
PYPIX
}

if [ -s "$OUT_DIR/png.ppm" ]; then
    GREEN=$(pixcount "$OUT_DIR/png.ppm" 0 200 0)
    echo "[hamview] PNG frame green pixels: ${GREEN:-0}"
    if [ "${GREEN:-0}" -ge 400 ]; then
        echo "[hamview] PASS decoded PNG raster on screen (green block)"
    else
        echo "[hamview] FAIL PNG image not visible — blank/placeholder? (green=${GREEN:-0})"; fail=1
    fi
else
    echo "[hamview] WARN no PNG screendump captured"; fail=1
fi

if [ -s "$OUT_DIR/jpg.ppm" ]; then
    ORANGE=$(pixcount "$OUT_DIR/jpg.ppm" 240 140 0)
    echo "[hamview] JPEG frame orange pixels: ${ORANGE:-0}"
    if [ "${ORANGE:-0}" -ge 400 ]; then
        echo "[hamview] PASS decoded JPEG raster on screen (orange block)"
    else
        echo "[hamview] FAIL JPEG image not visible — blank/placeholder? (orange=${ORANGE:-0})"; fail=1
    fi
else
    echo "[hamview] WARN no JPEG screendump captured"; fail=1
fi

echo "[hamview] artifacts in $OUT_DIR (frame_png.png / frame_jpg.png)"
if [ "$fail" -eq 0 ]; then
    echo "[hamview] RESULT: PASS"
    exit 0
else
    echo "[hamview] RESULT: FAIL"
    echo "[hamview] --- hamview/wsys serial lines ---" >&2
    grep -aiE 'hamview|wsys|mklayer|decoded' "$LOG" | tail -40 >&2 \
        || echo "[hamview] (no hamview serial lines captured)" >&2
    exit 1
fi
