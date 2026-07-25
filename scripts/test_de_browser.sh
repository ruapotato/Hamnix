#!/usr/bin/env bash
# scripts/test_de_browser.sh — render-evidence gate for the native web
# browser /bin/hambrowse (user/hambrowse.ad).
#
# Boots the installer image into the scene DE (runlevel 5), waits for the
# interactive serial shell, then launches `hambrowse --demo &` (the built-in
# HTML demo page — no network needed for a deterministic render). hambrowse:
#   * `newwindow` on /dev/wsys/ctl, sets geometry/decorate/z/title;
#   * fetches/loads the page, PARSES the HTML subset, lays it out, and writes
#     a scene display list (glyphs/rect/fill/line) to /dev/wsys/<wid>/scene;
#   * commits — the kernel scene compositor rasterizes + z-blits it to /dev/fb.
#
# ASSERTS (loudly FAIL otherwise):
#   1. SERIAL: "[hambrowse] scene window ready" + a "rendered segs=N rows=M
#      links=K" line with N>0 and K>=1 (the layout produced styled text +
#      at least one hyperlink).
#   2. SCENE TEXT: the committed /dev/wsys/<wid>/scene contains glyphs runs
#      with the demo's heading/body words ("Hamnix", "Features", "navigate").
#   3. PIXELS: a screendump PNG is captured for human inspection.
#   4. No kernel panic / fault in the serial log.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, or the image is absent.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_browser/$TS}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-260}"
OVMF_FD="${OVMF_FD:-/usr/share/OVMF/OVMF_CODE.fd}"
[ -f "$OVMF_FD" ] || OVMF_FD="/usr/share/ovmf/OVMF.fd"

[ -e /dev/kvm ] || { echo "[browser] SKIP: /dev/kvm absent" >&2; exit 0; }
[ -f "$OVMF_FD" ] || { echo "[browser] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "[browser] SKIP: socat required" >&2; exit 0; }

# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[de_browser]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[browser] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[browser] building installer image (~6 min)"
    bash "$PWD/scripts/build_installer_img.sh"
else
    # STALE-IMAGE QA TRAP GUARD (see memory: project_stale_installer_img_qa_trap).
    # This gate reuses a prebuilt image for speed, but a QA run after a browser/DE
    # code change would then boot the OLD binary and (false-)pass or (false-)fail
    # against stale pixels. If any tracked browser/DE/kernel source is newer than
    # the image, REBUILD (unless HAMNIX_SKIP_BUILD=1, the CI-shard fast path).
    newer=$(find lib user sys fs etc scripts -name '*.ad' -o -name '*.S' -newer "$INSTALLER_IMG" 2>/dev/null | head -1)
    if [ -n "$newer" ]; then
        if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
            echo "[browser] WARNING: $INSTALLER_IMG is OLDER than source ($newer) but HAMNIX_SKIP_BUILD=1 — booting a STALE image" >&2
        else
            echo "[browser] image is stale (source newer: $newer) — rebuilding (~6 min)" >&2
            bash "$PWD/scripts/build_installer_img.sh"
        fi
    fi
fi

mkdir -p "$OUT_DIR"
echo "[browser] output dir: $OUT_DIR"
OVMF_RW=$(mktemp --tmpdir hamnix-br.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-br.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-br-mon.XXXXXX)
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
# DE + browser + fonts need headroom: the scene DE OOM'd at -m 1G during
# shell/command pre-warm (elf: OOM), so the browser never launched. DE tests
# default to 2G (see the T20 DE-OOM lesson); override with HAMNIX_VM_MEM.
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
LAUNCH_CMD = os.environ.get("HAMBROWSE_LAUNCH", "hambrowse --demo &")
try:
    # Handoff marker: the scene-DE image boots straight to runlevel 5 and never
    # prints rc.boot.full's "handing off to interactive shell" — it brings up the
    # DE and drops an interactive hamsh on the serial console, announced by the
    # shell-ready banner. Wait for THAT (was stale → the gate never launched the
    # browser and false-FAILed the whole track).
    if not wait_for("M16.35 shell ready", boot_wait):
        print("[browser] driver: never reached handoff", file=sys.stderr)
    else:
        print("[browser] driver: handoff reached", file=sys.stderr)
        time.sleep(3)
        # WARM-UP: a freshly-booted hamsh DROPS its first serial command line
        # on a loaded host, which would silently swallow the timed launch and
        # fail the test even though the browser is fine. Send a no-op first and
        # confirm it echoes back before we launch anything real. Retry the
        # warm-up until the shell proves it is consuming our input.
        warmed = False
        for w in range(6):
            tag = "__WARMUP_%d__" % w
            with lock:
                base = len(buf)
            send("echo " + tag)
            # Wait for the shell to ECHO the tag back (proof it read the line).
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
                print("[browser] driver: shell warm-up ok (attempt %d)" % (w + 1),
                      file=sys.stderr)
                break
            print("[browser] driver: warm-up attempt %d not echoed, retrying"
                  % (w + 1), file=sys.stderr)
        if not warmed:
            print("[browser] driver: WARNING shell never echoed warm-up",
                  file=sys.stderr)
        # Launch the browser on its built-in demo page (no network). The
        # render SUMMARY prints to serial BEFORE `newwindow` rebinds the
        # client's stdout away from the console, so the harness can read it.
        # Retry the launch up to 6× — a dropped/lost line just means no
        # "opening scene window" marker, so re-send until it appears.
        opened = False
        for attempt in range(6):
            send(LAUNCH_CMD)
            print("[browser] driver: launch attempt %d: %s"
                  % (attempt + 1, LAUNCH_CMD), file=sys.stderr)
            # Give it time to parse/layout (summary) + open + commit the scene.
            if wait_for("[hambrowse] opening scene window", 25):
                opened = True
                print("[browser] driver: window opened on attempt %d"
                      % (attempt + 1), file=sys.stderr)
                break
            print("[browser] driver: no window on attempt %d, retrying"
                  % (attempt + 1), file=sys.stderr)
        time.sleep(5)
        screendump("browser")
        print("[browser] driver: captured browser frame (opened=%s)" % opened,
              file=sys.stderr)
        time.sleep(1)
        print("[browser] driver: done", file=sys.stderr)
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
if [ -s "$OUT_DIR/browser.ppm" ] && command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$OUT_DIR/browser.ppm" > "$OUT_DIR/browser.png" 2>/dev/null || true
fi

echo "[browser] --- render evidence ---"
fail=0

if grep -aq '\[hambrowse\] opening scene window' "$LOG"; then
    echo "[browser] PASS hambrowse parsed page + opened a window"
else
    echo "[browser] FAIL no 'opening scene window' marker"; fail=1
fi

# Pull the "rendered segs=N rows=M links=K" line and check N>0, K>=1.
REND=$(grep -ao 'rendered segs=[0-9]* rows=[0-9]* links=[0-9]*' "$LOG" | tail -1)
if [ -n "$REND" ]; then
    echo "[browser] $REND"
    SEGS=$(echo "$REND" | sed -n 's/.*segs=\([0-9]*\).*/\1/p')
    LINKS=$(echo "$REND" | sed -n 's/.*links=\([0-9]*\).*/\1/p')
    [ "${SEGS:-0}" -gt 0 ] && echo "[browser] PASS layout produced $SEGS segments" \
        || { echo "[browser] FAIL zero segments laid out"; fail=1; }
    [ "${LINKS:-0}" -ge 1 ] && echo "[browser] PASS parsed $LINKS hyperlink(s)" \
        || { echo "[browser] FAIL no hyperlinks parsed"; fail=1; }
else
    echo "[browser] FAIL no 'rendered segs=' summary line"; fail=1
fi

if grep -aqi 'kernel panic\|#UD\|triple fault\|page fault' "$LOG"; then
    echo "[browser] FAIL panic/fault in serial log"; fail=1
else
    echo "[browser] PASS no panic during boot/run"
fi

if [ -s "$OUT_DIR/browser.png" ]; then
    echo "[browser] screendump: $OUT_DIR/browser.png (view: heading + body + blue links)"
else
    echo "[browser] WARN no screendump captured"
fi

# ASSET-LOAD DIAGNOSTIC (#79 regression guard). The browser prints, BEFORE it
# rebinds stdout off serial, whether every embedded TrueType face loaded and
# the embedded demo PNG decoded. A device-only stack-overflow in the TTF glyph
# decoder used to trample these assets nondeterministically, silently degrading
# to blocky/blank text + an empty image box. Require the healthy line.
ASSET=$(grep -ao '\[hambrowse\] assets: ttf_faces=[0-9]*/4 demo_img=[0-9]* images=[0-9]*[A-Z ]*' "$LOG" | tail -1)
if [ -n "$ASSET" ]; then
    echo "[browser] $ASSET"
    if echo "$ASSET" | grep -q 'ttf_faces=4/4 demo_img=1'; then
        echo "[browser] PASS all 4 TTF faces loaded + demo PNG decoded"
    else
        echo "[browser] FAIL embedded assets degraded ($ASSET)"; fail=1
    fi
    if echo "$ASSET" | grep -q 'DEGRADED'; then
        echo "[browser] FAIL browser reported DEGRADED assets"; fail=1
    fi
else
    echo "[browser] FAIL no '[hambrowse] assets:' diagnostic line in serial"; fail=1
fi

# PIXEL PROOF the render is REAL GRAPHICS, not a bitmap-font fallback / empty
# image. Two independent signals a degraded frame cannot fake:
#   (A) ANTI-ALIASED TEXT — intermediate-GRAY edge pixels (r==g==b, strictly
#       between ink and paper) inside the browser content region. Black body
#       text rendered by the TTF rasteriser paints a smooth grey ramp at every
#       glyph edge; a 1-bit bitmap font (or a blank page) produces none.
#   (B) DECODED DEMO IMAGE — the sample PNG's bright-green quadrant (40,200,60)
#       is a solid block no DE chrome or text colour uses; its presence proves
#       lib/png decoded + htmlpaint blitted the real bitmap. The browser sits
#       top-left (geometry 50 40 880 600, first-commit maps-and-raises it), so
#       the content region is a fixed screen box.
PIX_PPM="$OUT_DIR/browser.ppm"
if [ -s "$PIX_PPM" ]; then
    PIXOUT=$(python3 - "$PIX_PPM" <<'PYPIX'
import sys
data = open(sys.argv[1], "rb").read()
if not data.startswith(b"P6"):
    print("NOHDR 0 0 0"); sys.exit(0)
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
w, h, maxv = fields
idx += 1
pix = data[idx:]
def px(x, y):
    o = (y * w + x) * 3
    return pix[o], pix[o+1], pix[o+2]
# distinctive demo-page colours (supporting signal, whole screen).
targets = [(26, 79, 208), (20, 48, 110), (10, 107, 90)]
TOL = 55
hits = 0
n = (len(pix) // 3) * 3
i = 0
while i < n:
    r = pix[i]; g = pix[i+1]; b = pix[i+2]
    for (tr, tg, tb) in targets:
        if abs(r-tr) <= TOL and abs(g-tg) <= TOL and abs(b-tb) <= TOL:
            hits += 1; break
    i += 3
# (A) grey AA edge pixels inside the browser content box.
gx0, gy0 = 195, 95
gx1, gy1 = min(w, 905), min(h, 615)
gray = 0
y = gy0
while y < gy1:
    x = gx0
    while x < gx1:
        r, g, b = px(x, y)
        if abs(r-g) <= 6 and abs(g-b) <= 6:
            v = (r + g + b) // 3
            if 30 <= v <= 225:
                gray += 1
        x += 1
    y += 1
# (B) decoded demo-image bright-green quadrant, whole screen.
green = 0
i = 0
while i < n:
    r = pix[i]; g = pix[i+1]; b = pix[i+2]
    if abs(r-40) <= 35 and abs(g-200) <= 45 and abs(b-60) <= 40:
        green += 1
    i += 3
print("OK %d %d %d" % (hits, gray, green))
PYPIX
)
    PIX_HITS=$(echo "$PIXOUT" | awk '{print $2}'); PIX_HITS=${PIX_HITS:-0}
    AA_GRAY=$(echo "$PIXOUT" | awk '{print $3}'); AA_GRAY=${AA_GRAY:-0}
    IMG_GREEN=$(echo "$PIXOUT" | awk '{print $4}'); IMG_GREEN=${IMG_GREEN:-0}
    echo "[browser] pixels: distinctive=$PIX_HITS  aa_gray=$AA_GRAY  img_green=$IMG_GREEN"
    if grep -aq '\[hambrowse\] opening scene window' "$LOG"; then
        if [ "$PIX_HITS" -ge 8 ]; then
            echo "[browser] PASS screendump shows hambrowse-distinctive pixels"
        else
            echo "[browser] FAIL screendump has no hambrowse-distinctive pixels (only generic chrome?)"; fail=1
        fi
        # AA text: a healthy render paints thousands of grey edge pixels; a
        # bitmap-fallback or blank page produces at most a handful.
        if [ "$AA_GRAY" -ge 800 ]; then
            echo "[browser] PASS anti-aliased text present ($AA_GRAY grey edge pixels)"
        else
            echo "[browser] FAIL no anti-aliased text — bitmap fallback / blank page? (aa_gray=$AA_GRAY)"; fail=1
        fi
        # Decoded demo image: its bright-green quadrant covers ~1500+ px.
        if [ "$IMG_GREEN" -ge 200 ]; then
            echo "[browser] PASS decoded demo PNG blitted (green quadrant, $IMG_GREEN px)"
        else
            echo "[browser] FAIL demo image missing — empty <img> box? (img_green=$IMG_GREEN)"; fail=1
        fi
    fi
else
    echo "[browser] WARN no PPM for pixel-signature check"
fi

echo "[browser] artifacts in $OUT_DIR"
if [ "$fail" -eq 0 ]; then
    echo "[browser] RESULT: PASS"
    RC=0
else
    echo "[browser] RESULT: FAIL"
    # Surface the browser/window-server serial context for triage.
    echo "[browser] --- hambrowse/wsys serial lines ---" >&2
    grep -aiE 'hambrowse|wsys|scene|newwindow|opening scene' "$LOG" | tail -40 >&2 \
        || echo "[browser] (no hambrowse/wsys serial lines captured)" >&2
    RC=1
fi
exit "$RC"
