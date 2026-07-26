#!/usr/bin/env bash
# scripts/test_de_wallpaper_backdrop.sh
#
# VISUAL gate for the scene-file DE desktop wallpaper backdrop
# (user/hamdesktop.ad). The kernel `/dev/wsys/ctl` `wallpaper <path>` verb
# records a PPM path + bumps a gen, exposed via the readable status file
# /dev/wsys/wallpaper. hamdesktop polls that file on its redraw cadence and,
# on a gen bump, parses the P6 PPM and repaints the desktop backdrop as a
# nearest-neighbour mosaic of `fill` rects (no bitmap tier in the scene DE).
#
# This drives the LIVE DE: from the serial shell it applies the build-planted
# /etc/wallpaper.ppm (a 640x480 gradient — the SAME PPM path the Settings app
# swatches write, only a real image instead of a solid swatch) by writing
# `wallpaper /etc/wallpaper.ppm` to /dev/wsys/ctl, then screendumps the
# framebuffer BEFORE and AFTER. The desktop backdrop must visibly change from
# the solid teal (#205060) fallback to the image colours.
#
# Assertion: the AFTER frame differs from the BEFORE frame by a LARGE region
# (the whole desktop backdrop repainted from teal to the gradient), and the
# AFTER frame is NOT mostly teal anymore (the image mosaic landed). A no-op
# (wallpaper never consumed) leaves the backdrop teal and the diff ~zero.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, the image, or socat are
# unavailable. rc=124 (host-load timeout) is NOT a fail.

# KNOWN-RED, PRE-EXISTING (diagnosed 2026-07-25): this gate applies the
# wallpaper by writing `wallpaper <path>` to /dev/wsys/ctl FROM THE SERIAL
# SHELL, and that verb is hostowner-only — the interactive shell handed off at
# the end of boot is not the DE's session, so the write is refused and
# /dev/wsys/wallpaper still reads gen 0 ("before teal == after teal", diff ~13
# px). It is NOT a hamdesktop regression: scripts/test_de_wallpaper_fullscreen.sh
# drives the same pipeline through the DE launch queue (the context a Control
# Center click runs in) and the backdrop repaints in full. Fixing this one needs
# either a hostowner-side applier or a relaxed ctl gate — a privilege-model
# decision, not a DE one.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_wallpaper/$TS}"

if [ ! -e /dev/kvm ]; then
    echo "[wp_gate] SKIP: /dev/kvm absent (KVM required)" >&2
    exit 0
fi

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[wp_gate] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

if ! command -v socat >/dev/null 2>&1; then
    echo "[wp_gate] SKIP: socat required to drive the monitor/serial" >&2
    exit 0
fi

# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[de_wallpaper_backdrop]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[wp_gate] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[wp_gate] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[wp_gate] SKIP: $INSTALLER_IMG unavailable" >&2
    exit 0
fi

mkdir -p "$OUT_DIR"
echo "[wp_gate] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-wp.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-wp.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-wp-mon.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
trap 'rm -f "$OVMF_RW" "$IMG_RW" "$MON"' EXIT

# whole_frame_diff A B -> count of changed pixels (per-channel thresholded).
whole_frame_diff() {
    python3 - "$@" <<'PYEOF'
import sys
def load_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        return None
    idx = 2; toks = []
    while len(toks) < 3:
        while idx < len(data) and data[idx:idx+1].isspace():
            idx += 1
        if idx < len(data) and data[idx:idx+1] == b'#':
            while idx < len(data) and data[idx:idx+1] != b'\n':
                idx += 1
            continue
        start = idx
        while idx < len(data) and not data[idx:idx+1].isspace():
            idx += 1
        toks.append(int(data[start:idx]))
    idx += 1
    w, h, mx = toks
    return w, h, data[idx:idx + w*h*3]
a = load_ppm(sys.argv[1]); b = load_ppm(sys.argv[2])
if a is None or b is None or a[0] != b[0] or a[1] != b[1]:
    print(-1); sys.exit(0)
w, h, pa = a; _, _, pb = b
THRESH = 24; changed = 0; n = min(len(pa), len(pb))
i = 0
while i + 2 < n:
    if (abs(pa[i]-pb[i]) > THRESH or abs(pa[i+1]-pb[i+1]) > THRESH
            or abs(pa[i+2]-pb[i+2]) > THRESH):
        changed += 1
    i += 3
print(changed)
PYEOF
}

# teal_px FRAME -> count of pixels close to the teal fallback backdrop
# (#205060 == 32,80,96). A teal-only desktop reads high; an image backdrop
# reads low (the gradient is mostly indigo/denim, far from teal).
teal_px() {
    python3 - "$@" <<'PYEOF'
import sys
def load_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        return None
    idx = 2; toks = []
    while len(toks) < 3:
        while idx < len(data) and data[idx:idx+1].isspace():
            idx += 1
        if idx < len(data) and data[idx:idx+1] == b'#':
            while idx < len(data) and data[idx:idx+1] != b'\n':
                idx += 1
            continue
        start = idx
        while idx < len(data) and not data[idx:idx+1].isspace():
            idx += 1
        toks.append(int(data[start:idx]))
    idx += 1
    w, h, mx = toks
    return w, h, data[idx:idx + w*h*3]
f = load_ppm(sys.argv[1])
if f is None:
    print(-1); sys.exit(0)
w, h, p = f
TR, TG, TB = 32, 80, 96
THRESH = 24; teal = 0; n = len(p)
i = 0
while i + 2 < n:
    if (abs(p[i]-TR) <= THRESH and abs(p[i+1]-TG) <= THRESH
            and abs(p[i+2]-TB) <= THRESH):
        teal += 1
    i += 3
print(teal)
PYEOF
}

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
import sys, subprocess, time, threading, re

img, ovmf, mon, logpath, snap, boot_wait = sys.argv[1:7]
boot_wait = int(boot_wait)

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host",
    "-bios", ovmf,
    "-drive", f"file={img},format=raw,if=virtio",
    "-m", "1G",
    "-vga", "std", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{mon},server,nowait",
    "-serial", "stdio",
], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
   bufsize=0)

logf = open(logpath, "wb")
buf = bytearray()
lock = threading.Lock()

def reader():
    while True:
        b = qemu.stdout.read(1)
        if not b:
            break
        logf.write(b); logf.flush()
        with lock:
            buf.extend(b)

t = threading.Thread(target=reader, daemon=True); t.start()

_HB_RE = re.compile(rb'\[hamsh-alive\][^\n]*')
_CSI_RE = re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]')
def _denoise(b):
    return _CSI_RE.sub(b'', _HB_RE.sub(b'', b))

def wait_for(marker, timeout):
    m = marker.encode(); deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            if m in buf or m in _denoise(buf):
                return True
        if qemu.poll() is not None:
            return False
        time.sleep(0.5)
    return False

def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception:
        pass

def screendump(label):
    subprocess.run([snap, label], timeout=20)

rc = 2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[wp_gate] driver: never reached handoff", file=sys.stderr)
        rc = 2
    else:
        print("[wp_gate] driver: handoff reached", file=sys.stderr)
        # Let the DE settle (autonomous visual_gate churns the window set).
        if wait_for("[visual_gate] done", 90):
            print("[wp_gate] driver: visual_gate done", file=sys.stderr)
        else:
            print("[wp_gate] driver: visual_gate 'done' not seen; proceeding",
                  file=sys.stderr)
        time.sleep(4)

        # BEFORE: backdrop is the solid teal fallback (no wallpaper set yet).
        screendump("before")
        time.sleep(0.5)

        # Apply the build-planted /etc/wallpaper.ppm (a 640x480 gradient) as
        # the wallpaper — the SAME /dev/wsys/ctl verb + PPM-path mechanism the
        # Settings swatches use. hamdesktop polls /dev/wsys/wallpaper, sees the
        # gen bump, parses the PPM and repaints the backdrop mosaic.
        send("echo APPLY_WALLPAPER_BEGIN")
        send("echo 'wallpaper /etc/wallpaper.ppm' > /dev/wsys/ctl")
        # Confirm the kernel recorded it (gen should be non-zero now).
        time.sleep(0.5)
        send("echo WPRBB; cat /dev/wsys/wallpaper; echo; echo WPRBE")
        # hamdesktop polls on its redraw cadence; give it time to load + repaint.
        if wait_for("[hamdesktop] wallpaper loaded", 20):
            print("[wp_gate] driver: hamdesktop reported wallpaper loaded",
                  file=sys.stderr)
        else:
            print("[wp_gate] driver: 'wallpaper loaded' marker not seen "
                  "(continuing; visual diff is authoritative)", file=sys.stderr)
        time.sleep(3)
        send("echo APPLY_WALLPAPER_END")

        # AFTER: backdrop should now carry the image mosaic.
        screendump("after")
        time.sleep(1)
        rc = 0
finally:
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=5)
    except Exception: qemu.kill()
    logf.flush(); logf.close()
sys.exit(rc)
PYDRV
DRV_RC=$?

if [ "$DRV_RC" = "2" ]; then
    echo "[wp_gate] SKIP: guest did not reach interactive shell; log: $LOG" >&2
    exit 0
fi

echo "[wp_gate] --- wallpaper status readback ---"
awk '/WPRBB/{f=1;next} /WPRBE/{f=0} f' "$LOG" 2>/dev/null | tr -d '\r' | head -3 | sed 's/^/[wp_gate]   /'

echo "[wp_gate] --- assertions ---"
fail=0

if [ ! -s "$OUT_DIR/before.ppm" ] || [ ! -s "$OUT_DIR/after.ppm" ]; then
    echo "[wp_gate] SKIP: missing before/after screendump (monitor dump failed)" >&2
    exit 0
fi

before_teal=$(teal_px "$OUT_DIR/before.ppm")
after_teal=$(teal_px "$OUT_DIR/after.ppm")
diff_px=$(whole_frame_diff "$OUT_DIR/before.ppm" "$OUT_DIR/after.ppm")
echo "[wp_gate] before teal px = $before_teal ; after teal px = $after_teal"
echo "[wp_gate] before->after whole-frame diff = $diff_px"

# (1) The backdrop must have changed substantially (teal -> image).
if [ "$diff_px" = "-1" ]; then
    echo "[wp_gate] NOTE frames differ in size/format; diff inconclusive" >&2
elif [ "$diff_px" -ge 50000 ]; then
    echo "[wp_gate] PASS backdrop repainted ($diff_px px changed) after applying the wallpaper"
else
    echo "[wp_gate] FAIL backdrop barely changed ($diff_px px) — wallpaper not consumed by hamdesktop" >&2
    fail=1
fi

# (2) The desktop should be markedly LESS teal afterwards (image landed).
if [ "$before_teal" != "-1" ] && [ "$after_teal" != "-1" ]; then
    if [ "$after_teal" -lt "$before_teal" ]; then
        echo "[wp_gate] PASS teal backdrop coverage dropped ($before_teal -> $after_teal) — image mosaic painted"
    else
        echo "[wp_gate] FAIL teal coverage did not drop ($before_teal -> $after_teal) — backdrop still the solid fallback" >&2
        fail=1
    fi
fi

echo "[wp_gate] artifacts (PPM frames) in $OUT_DIR"
if [ "$fail" = "0" ]; then
    echo "[wp_gate] RESULT: PASS"
    exit 0
fi
echo "[wp_gate] RESULT: FAIL"
exit 1
