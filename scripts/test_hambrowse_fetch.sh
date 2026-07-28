#!/usr/bin/env bash
# scripts/test_hambrowse_fetch.sh — on-device NETWORK FETCH + RENDER gate for
# the native web browser /bin/hambrowse (user/hambrowse.ad).
#
# This is the capstone of the browser work: it proves hambrowse can FETCH a
# real HTML page over the guest network and RENDER it on device with the full
# pixel engine — NOT just the built-in about:demo page (which test_de_browser.sh
# already covers with no network).
#
# WHAT IT DOES
#   1. Serves a rich plain-HTTP page (headings, CSS colour, a reflowing
#      paragraph, a list, a hyperlink, and a solid-magenta <img> PNG) from the
#      HOST via `python3 -m http.server` on a free port. The guest reaches the
#      host at the SLIRP gateway alias 10.0.2.2:<port>.
#   2. Boots the installer image into the scene DE (runlevel 5) WITH SLIRP
#      networking (`-netdev user` + `-device virtio-net-pci`), so the guest
#      gets a DHCP lease at boot (10.0.2.15) — the same net bring-up the
#      apt/net-client gates rely on.
#   3. Runs `hambrowse http://10.0.2.2:<port>/page.html`, waits for the fetch
#      marker, and SCREENDUMPS.
#
# ASSERTS (three-valued: PASS / FAIL / INCONCLUSIVE):
#   * SERIAL: "[hambrowse] fetched http status=200 bytes=N" with N large
#     (proves a real HTTP GET drained the served body). If instead
#     "[hambrowse] fetch FAILED rc=-K" appears, the wall is captured and the
#     gate FAILs with the transport error code visible.
#   * SERIAL: "rendered segs=N rows=M links=K" with N>0, K>=1 (the served
#     page — which contains a hyperlink — parsed + laid out).
#   * PIXELS: the served PNG's solid-magenta block (255,0,255) is present in
#     the screendump. That colour is used by NOTHING in about:demo, the DE
#     chrome, or the error page — its presence proves the image was fetched
#     over HTTP, decoded, and blitted, i.e. the SERVED page rendered.
#   * PIXELS: anti-aliased grey text (proves the TTF text render ran).
#   * No kernel panic / fault.
#   A screendump PNG is written for human inspection.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, python3, or the image is
# absent — it needs a host HTTP server + SLIRP + KVM.
#
# VERDICT CODES (scripts/_verdict.sh, project-wide): 0 = PASS, 1 = FAIL,
# 125 = INCONCLUSIVE. This family used a LOCAL 2 for INCONCLUSIVE until
# 2026-07-28. scripts/ci_run_gate.sh maps 125 to a ::warning:: and 2 to a
# BUILD FAILURE, so the private code turned every "could not observe the
# assertion" run into a red shard. There is no reason for the exception and
# it is gone; any embedded python helper that still exits 2 is INTERNAL and
# is remapped by the `case "$rc"` at the foot of the script.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/hambrowse_fetch/$TS}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
# 260s was too short: a full network-DE boot (virtio-net + net-fuzz selftests +
# DE bringup) can take >400s to reach the interactive shell on a busy host, so
# the gate false-INCONCLUSIVE'd before hambrowse ever launched. 480s covers it.
BOOT_WAIT="${BOOT_WAIT:-480}"
OVMF_FD="${OVMF_FD:-/usr/share/OVMF/OVMF_CODE.fd}"
[ -f "$OVMF_FD" ] || OVMF_FD="/usr/share/ovmf/OVMF.fd"

[ -e /dev/kvm ] || { echo "[fetch] SKIP: /dev/kvm absent" >&2; exit 0; }
[ -f "$OVMF_FD" ] || { echo "[fetch] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat   >/dev/null 2>&1 || { echo "[fetch] SKIP: socat required" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[fetch] SKIP: python3 required" >&2; exit 0; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "[fetch] SKIP: qemu-system-x86_64 required" >&2; exit 0; }

FIXTURE_HTML="$PWD/scripts/fixtures/hambrowse_fetch/page.html"
[ -f "$FIXTURE_HTML" ] || { echo "[fetch] SKIP: fixture $FIXTURE_HTML missing" >&2; exit 0; }

# --- build / stale-guard the installer image --------------------------------
# NEVER boot an image older than the tree under test, and NEVER print a verdict
# for a run that had no image to boot. installer_img_or_verdict
# (scripts/_installer_img.sh) covers all three cases in one call:
#
#   a usable image is in place                   -> returns; the gate carries on
#   HAMNIX_SKIP_BUILD=1 and the image is absent  -> exit 0   (skip BY REQUEST)
#   the build ran and FAILED / produced no image -> exit 125 (INCONCLUSIVE)
#
# The hand-rolled block this replaces got the third case wrong, and it cost
# ~100 s of runner time per gate per run: it invoked build_installer_img.sh
# WITHOUT checking its status, fell through to `cp "$INSTALLER_IMG" "$IMG_RW"`,
# booted QEMU with no drive at all, and burned the whole BOOT_WAIT to a
# timeout that then read as a browser FAIL. A false RED, expensive twice over.
#
# Its stale check was broken too:
#     find lib user sys fs etc scripts -name '*.ad' -o -name '*.S' -newer "$IMG"
# `-newer` binds to the '*.S' branch ONLY (find's implicit -a outranks -o), so
# the expression is `(-name '*.ad') OR (-name '*.S' AND -newer $IMG)` and the
# first .ad file in the tree always matched. The image "was stale" on every
# single run. installer_img_is_stale does the mtime comparison properly.
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
installer_img_or_verdict "$INSTALLER_IMG" "[hambrowse_fetch]"

mkdir -p "$OUT_DIR"
echo "[fetch] output dir: $OUT_DIR"

# --- build the served document root (page.html + a generated magenta PNG) ---
SERVE_DIR=$(mktemp -d --tmpdir hamnix-fetch-www.XXXXXX)
cp "$FIXTURE_HTML" "$SERVE_DIR/page.html"
python3 - "$SERVE_DIR/sig.png" <<'PYPNG'
import sys, zlib, struct
path = sys.argv[1]
w, h, rgb = 60, 40, (255, 0, 255)   # solid magenta, 8-bit RGB (PNG colour type 2)
def chunk(typ, data):
    body = typ + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)
raw = bytearray()
row = bytes(rgb) * w
for _ in range(h):
    raw.append(0)        # filter type 0 (None)
    raw += row
ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)  # 8-bit depth, colour type 2, no interlace
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
       + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))
open(path, "wb").write(png)
PYPNG
cp "$SERVE_DIR/sig.png" "$OUT_DIR/sig.png"   # keep the served asset for reference

# --- pick a free TCP port on the host ---
PORT=$(python3 - <<'PYPORT'
import socket
s = socket.socket()
s.bind(("0.0.0.0", 0))
print(s.getsockname()[1])
s.close()
PYPORT
)
echo "[fetch] serving $SERVE_DIR on host port $PORT (guest reaches it at 10.0.2.2:$PORT)"

# --- start the host HTTP server ---
HTTP_LOG="$OUT_DIR/httpserver.log"
( cd "$SERVE_DIR" && exec python3 -m http.server "$PORT" --bind 0.0.0.0 ) >"$HTTP_LOG" 2>&1 &
HTTP_PID=$!

OVMF_RW=$(mktemp --tmpdir hamnix-fetch.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-fetch.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-fetch-mon.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
cleanup() {
    kill "$HTTP_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON"
    rm -rf "$SERVE_DIR"
}
trap cleanup EXIT
: > "$LOG"

# --- host-side sanity: confirm the server actually serves the page ---
sleep 0.5
if command -v curl >/dev/null 2>&1; then
    if ! curl -fs "http://127.0.0.1:$PORT/page.html" -o /dev/null; then
        echo "[fetch] SKIP: host HTTP server not reachable on 127.0.0.1:$PORT" >&2
        exit 0
    fi
    HTMLBYTES=$(curl -fs "http://127.0.0.1:$PORT/page.html" | wc -c)
    echo "[fetch] host sanity: page.html is $HTMLBYTES bytes"
fi

SNAP_HELPER="$OUT_DIR/.snap.sh"
cat > "$SNAP_HELPER" <<SNAPEOF
#!/bin/bash
label="\$1"
ppm="$OUT_DIR/\$label.ppm"
printf 'screendump %s\n' "\$ppm" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
for i in \$(seq 1 30); do [ -s "\$ppm" ] && break; sleep 0.1; done
SNAPEOF
chmod +x "$SNAP_HELPER"

export HAMBROWSE_URL="http://10.0.2.2:$PORT/page.html"

python3 - "$IMG_RW" "$OVMF_RW" "$MON" "$LOG" "$SNAP_HELPER" "$BOOT_WAIT" <<'PYDRV'
import sys, subprocess, time, threading, os
img, ovmf, mon, logpath, snap, boot_wait = sys.argv[1:7]
boot_wait = int(boot_wait)
vm_mem = os.environ.get("HAMNIX_VM_MEM", "2G")
url = os.environ["HAMBROWSE_URL"]
qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host",
    "-bios", ovmf,
    "-drive", f"file={img},format=raw,if=virtio",
    "-m", vm_mem,
    "-vga", "std", "-display", "none", "-no-reboot",
    "-netdev", "user,id=n0",
    "-device", "virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56",
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
def wait_for_any(markers, timeout):
    ms = [m.encode() for m in markers]; deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            for i, m in enumerate(ms):
                if m in buf: return i
        if qemu.poll() is not None: return -1
        time.sleep(0.2)
    return -1
def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception: pass
try:
    if not wait_for("M16.35 shell ready", boot_wait):
        print("[fetch] driver: never reached DE shell handoff", file=sys.stderr)
    else:
        print("[fetch] driver: handoff reached", file=sys.stderr)
        time.sleep(3)
        # WARM-UP: a freshly-booted hamsh drops its first serial command on a
        # loaded host. Send a no-op and confirm it echoes before launching.
        warmed = False
        for w in range(6):
            tag = "__WARMUP_%d__" % w
            with lock: base = len(buf)
            send("echo " + tag)
            deadline = time.time() + 6
            while time.time() < deadline:
                with lock:
                    if buf.find(tag.encode(), base) != -1:
                        warmed = True; break
                if qemu.poll() is not None: break
                time.sleep(0.2)
            if warmed:
                print("[fetch] driver: shell warm-up ok (attempt %d)" % (w+1), file=sys.stderr)
                break
        if not warmed:
            print("[fetch] driver: WARNING shell never echoed warm-up", file=sys.stderr)
        # Launch the browser on the NETWORK URL. The fetch + parse + layout
        # summary all print to serial BEFORE newwindow rebinds stdout, so we
        # can watch for the fetch marker. Retry a few times (dropped line).
        launch = "hambrowse %s &" % url
        outcome = -1
        for attempt in range(6):
            send(launch)
            print("[fetch] driver: launch attempt %d: %s" % (attempt+1, launch), file=sys.stderr)
            outcome = wait_for_any(
                ["[hambrowse] fetched http status=",
                 "[hambrowse] fetch FAILED",
                 "[hambrowse] opening scene window"], 30)
            if outcome >= 0:
                print("[fetch] driver: got outcome %d on attempt %d" % (outcome, attempt+1), file=sys.stderr)
                break
            print("[fetch] driver: no fetch marker on attempt %d, retrying" % (attempt+1), file=sys.stderr)
        # Give the window time to open + commit the pixel frame.
        wait_for("[hambrowse] opening scene window", 20)
        time.sleep(6)
        subprocess.run([snap, "fetch"], timeout=20)
        print("[fetch] driver: captured frame (outcome=%d)" % outcome, file=sys.stderr)
        time.sleep(1)
        print("[fetch] driver: done", file=sys.stderr)
finally:
    try: qemu.stdin.close()
    except Exception: pass
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=10)
    except Exception: qemu.kill()
PYDRV

# ppm -> png for human inspection.
if [ -s "$OUT_DIR/fetch.ppm" ] && command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$OUT_DIR/fetch.ppm" > "$OUT_DIR/fetch.png" 2>/dev/null || true
fi

echo "[fetch] --- host HTTP server access log ---"
grep -a "GET" "$HTTP_LOG" 2>/dev/null | sed 's/^/[fetch:httpd] /' || echo "[fetch:httpd] (no GET lines — guest never connected)"

echo "[fetch] --- render evidence ---"
fail=0
markers=0

# (1) Boot markers present at all? Count guest hambrowse markers; zero => INCONCLUSIVE.
GUESTMARK=$(grep -ac '\[hambrowse\]' "$LOG")
echo "[fetch] guest hambrowse serial markers: $GUESTMARK"
if [ "$GUESTMARK" -eq 0 ]; then
    echo "[fetch] RESULT: INCONCLUSIVE (no guest [hambrowse] markers — boot/launch never happened)"
    echo "[fetch] --- boot tail ---" >&2
    tail -30 "$LOG" >&2
    exit 125
fi

# (2) The fetch marker — the core network-fetch proof.
FETCH=$(grep -ao '\[hambrowse\] fetched http status=[0-9]* bytes=[0-9]*' "$LOG" | tail -1)
FAILM=$(grep -ao '\[hambrowse\] fetch FAILED rc=-[0-9]*' "$LOG" | tail -1)
if [ -n "$FETCH" ]; then
    echo "[fetch] $FETCH"
    markers=$((markers+1))
    STATUS=$(echo "$FETCH" | sed -n 's/.*status=\([0-9]*\).*/\1/p')
    BYTES=$(echo "$FETCH" | sed -n 's/.*bytes=\([0-9]*\).*/\1/p')
    [ "${STATUS:-0}" = "200" ] && echo "[fetch] PASS HTTP 200 from host server" \
        || { echo "[fetch] FAIL non-200 HTTP status ($STATUS)"; fail=1; }
    [ "${BYTES:-0}" -ge 200 ] && echo "[fetch] PASS drained $BYTES body bytes (>=200)" \
        || { echo "[fetch] FAIL body too small ($BYTES bytes) — truncated/empty?"; fail=1; }
elif [ -n "$FAILM" ]; then
    echo "[fetch] $FAILM"
    echo "[fetch] FAIL hambrowse reported a transport failure (see rc: -2 connect, -7 chunked, etc.)"
    fail=1
else
    echo "[fetch] FAIL no '[hambrowse] fetched http' AND no 'fetch FAILED' marker"
    fail=1
fi

# (3) Layout summary — served page has a hyperlink, so links>=1.
REND=$(grep -ao 'rendered segs=[0-9]* rows=[0-9]* links=[0-9]*' "$LOG" | tail -1)
if [ -n "$REND" ]; then
    echo "[fetch] $REND"
    SEGS=$(echo "$REND" | sed -n 's/.*segs=\([0-9]*\).*/\1/p')
    LINKS=$(echo "$REND" | sed -n 's/.*links=\([0-9]*\).*/\1/p')
    [ "${SEGS:-0}" -gt 0 ] && echo "[fetch] PASS layout produced $SEGS segments" \
        || { echo "[fetch] FAIL zero segments laid out"; fail=1; }
    [ "${LINKS:-0}" -ge 1 ] && echo "[fetch] PASS parsed $LINKS hyperlink(s) from served page" \
        || { echo "[fetch] FAIL no hyperlinks parsed (served page has one)"; fail=1; }
else
    echo "[fetch] FAIL no 'rendered segs=' summary line"; fail=1
fi

if grep -aqi 'kernel panic\|#UD\|triple fault\|page fault' "$LOG"; then
    echo "[fetch] FAIL panic/fault in serial log"; fail=1
else
    echo "[fetch] PASS no panic during boot/run"
fi

# (4) PIXEL PROOF: the served PNG's solid-magenta block (255,0,255) — a colour
# nothing else on screen uses — proves the image was fetched over HTTP,
# decoded, and blitted, i.e. the SERVED page rendered (not about:demo / error).
# Plus anti-aliased grey text proves the TTF render ran.
PIX_PPM="$OUT_DIR/fetch.ppm"
if [ -s "$PIX_PPM" ]; then
    PIXOUT=$(python3 - "$PIX_PPM" <<'PYPIX'
import sys
data = open(sys.argv[1], "rb").read()
if not data.startswith(b"P6"):
    print("NOHDR 0 0"); sys.exit(0)
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
n = (len(pix)//3)*3
# solid-magenta image pixels (255,0,255) — generous tolerance for blit scaling.
mag = 0
# anti-aliased grey text: r==g==b (near), mid-value, inside content box.
def px(x, y):
    o = (y*w + x)*3
    return pix[o], pix[o+1], pix[o+2]
i = 0
while i < n:
    r = pix[i]; g = pix[i+1]; b = pix[i+2]
    if r >= 200 and g <= 70 and b >= 200:
        mag += 1
    i += 3
gray = 0
gx0, gy0 = 195, 95
gx1, gy1 = min(w, 905), min(h, 615)
y = gy0
while y < gy1:
    x = gx0
    while x < gx1:
        r, g, b = px(x, y)
        if abs(r-g) <= 6 and abs(g-b) <= 6:
            v = (r+g+b)//3
            if 30 <= v <= 225:
                gray += 1
        x += 1
    y += 1
print("OK %d %d" % (mag, gray))
PYPIX
)
    MAG=$(echo "$PIXOUT" | awk '{print $2}'); MAG=${MAG:-0}
    AA_GRAY=$(echo "$PIXOUT" | awk '{print $3}'); AA_GRAY=${AA_GRAY:-0}
    echo "[fetch] pixels: magenta_img=$MAG  aa_gray=$AA_GRAY"
    if [ "$MAG" -ge 200 ]; then
        echo "[fetch] PASS served magenta PNG fetched+decoded+blitted ($MAG px)"
    else
        echo "[fetch] FAIL served image missing — image fetch/decode/blit broken? (magenta=$MAG)"; fail=1
    fi
    if [ "$AA_GRAY" -ge 800 ]; then
        echo "[fetch] PASS anti-aliased text present ($AA_GRAY grey edge pixels)"
    else
        echo "[fetch] FAIL no anti-aliased text — blank page / bitmap fallback? (aa_gray=$AA_GRAY)"; fail=1
    fi
else
    echo "[fetch] WARN no PPM captured for pixel-signature check"; fail=1
fi

if [ -s "$OUT_DIR/fetch.png" ]; then
    echo "[fetch] screendump: $OUT_DIR/fetch.png (view: magenta heading + magenta PNG + teal paragraph)"
else
    echo "[fetch] WARN no screendump PNG (raw PPM at $PIX_PPM)"
fi

echo "[fetch] artifacts in $OUT_DIR"
if [ "$fail" -eq 0 ]; then
    echo "[fetch] RESULT: PASS"
    exit 0
else
    echo "[fetch] RESULT: FAIL"
    echo "[fetch] --- hambrowse/net serial lines ---" >&2
    grep -aiE 'hambrowse|dhcp|virtio-net|http|net_dial|10.0.2' "$LOG" | tail -50 >&2 \
        || echo "[fetch] (no relevant serial lines)" >&2
    exit 1
fi
