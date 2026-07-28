#!/usr/bin/env bash
# scripts/test_hambrowse_http_features.sh — on-device gate for the two
# HTTP/1.1 features user/http9.ad just gained: CHUNKED transfer-decoding and
# 3xx REDIRECT following. Sibling of scripts/test_hambrowse_fetch.sh (plain
# Content-Length fetch); reuses its SLIRP `-netdev user` + 10.0.2.2 setup.
#
# A tiny CUSTOM host HTTP server (python http.server can't chunk) serves:
#   /page.html  — the rich fixture page (Content-Length)      [reference]
#   /sig.png    — a solid-magenta PNG the page <img>-references
#   /chunked    — the SAME page.html body, Transfer-Encoding: chunked
#   /redir      — HTTP 302 with Location: /page.html
#
# In ONE boot the driver launches hambrowse twice: first on /chunked, then on
# /redir. It asserts (three-valued PASS / FAIL / INCONCLUSIVE):
#   * CHUNKED: the guest GETs /chunked and reports
#     "[hambrowse] fetched http status=200 bytes=N" (N>=200) with NO
#     "fetch FAILED rc=-7" — i.e. the chunked body decoded, not rejected.
#   * REDIRECT: the guest GETs /redir AND then GETs /page.html (the server
#     access log proves the 302 was FOLLOWED to the target), and reports a
#     second "fetched http status=200" (the FINAL 200, not the 302).
#   * PIXELS: the served magenta PNG (255,0,255) — a colour nothing else on
#     screen uses — is present in a screendump, proving a served page (via
#     both chunked and redirect) actually rendered on device.
#   * No kernel panic / fault.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, python3, or the image is
# absent. Count guest markers; zero => INCONCLUSIVE (exit 125).
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
OUT_DIR="${OUT_DIR:-build/hambrowse_http_features/$TS}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-480}"
OVMF_FD="${OVMF_FD:-/usr/share/OVMF/OVMF_CODE.fd}"
[ -f "$OVMF_FD" ] || OVMF_FD="/usr/share/ovmf/OVMF.fd"

[ -e /dev/kvm ] || { echo "[httpfeat] SKIP: /dev/kvm absent" >&2; exit 0; }
[ -f "$OVMF_FD" ] || { echo "[httpfeat] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat   >/dev/null 2>&1 || { echo "[httpfeat] SKIP: socat required" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[httpfeat] SKIP: python3 required" >&2; exit 0; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "[httpfeat] SKIP: qemu required" >&2; exit 0; }

FIXTURE_HTML="$PWD/scripts/fixtures/hambrowse_fetch/page.html"
[ -f "$FIXTURE_HTML" ] || { echo "[httpfeat] SKIP: fixture $FIXTURE_HTML missing" >&2; exit 0; }

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
installer_img_or_verdict "$INSTALLER_IMG" "[hambrowse_http_features]"

mkdir -p "$OUT_DIR"
echo "[httpfeat] output dir: $OUT_DIR"

# --- served document root (page.html + generated magenta PNG) ---
SERVE_DIR=$(mktemp -d --tmpdir hamnix-httpfeat-www.XXXXXX)
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
    raw.append(0)
    raw += row
ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
       + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))
open(path, "wb").write(png)
PYPNG
cp "$SERVE_DIR/sig.png" "$OUT_DIR/sig.png"

# --- the custom chunked + redirect HTTP server ---
SERVER_PY="$OUT_DIR/feat_server.py"
cat > "$SERVER_PY" <<'PYSRV'
import sys, os
from http.server import BaseHTTPRequestHandler, HTTPServer

root = sys.argv[1]
port = int(sys.argv[2])

def load(name):
    with open(os.path.join(root, name), "rb") as f:
        return f.read()

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"   # match hambrowse's HTTP/1.0 GET
    def _send_bytes(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        p = self.path.split("?", 1)[0]
        if p in ("/page.html", "/"):
            self._send_bytes(load("page.html"), "text/html")
        elif p == "/sig.png":
            self._send_bytes(load("sig.png"), "image/png")
        elif p == "/redir":
            self.send_response(302)
            self.send_header("Location", "/page.html")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif p == "/chunked":
            # Same page.html body, framed as Transfer-Encoding: chunked in
            # several ~200-byte chunks + a terminating 0-chunk.
            body = load("page.html")
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            step = 200
            i = 0
            while i < len(body):
                part = body[i:i+step]
                self.wfile.write(("%x\r\n" % len(part)).encode())
                self.wfile.write(part)
                self.wfile.write(b"\r\n")
                i += step
            self.wfile.write(b"0\r\n\r\n")
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

HTTPServer(("0.0.0.0", port), H).serve_forever()
PYSRV

# --- pick a free TCP port ---
PORT=$(python3 - <<'PYPORT'
import socket
s = socket.socket(); s.bind(("0.0.0.0", 0)); print(s.getsockname()[1]); s.close()
PYPORT
)
echo "[httpfeat] serving $SERVE_DIR on host port $PORT (guest: 10.0.2.2:$PORT)"

HTTP_LOG="$OUT_DIR/httpserver.log"
python3 "$SERVER_PY" "$SERVE_DIR" "$PORT" >"$HTTP_LOG" 2>&1 &
HTTP_PID=$!

OVMF_RW=$(mktemp --tmpdir hamnix-httpfeat.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-httpfeat.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-httpfeat-mon.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
cleanup() {
    kill "$HTTP_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON"
    rm -rf "$SERVE_DIR"
}
trap cleanup EXIT
: > "$LOG"

# --- host sanity: confirm the server serves + actually chunks + redirects ---
sleep 0.5
if command -v curl >/dev/null 2>&1; then
    if ! curl -fs "http://127.0.0.1:$PORT/page.html" -o /dev/null; then
        echo "[httpfeat] SKIP: host server not reachable on 127.0.0.1:$PORT" >&2; exit 0
    fi
    # Confirm /chunked really uses chunked framing (GET; the server only
    # implements GET, so use -D to dump response headers, not HEAD).
    if curl -s -D - -o /dev/null "http://127.0.0.1:$PORT/chunked" | grep -qi 'transfer-encoding: *chunked'; then
        echo "[httpfeat] host sanity: /chunked emits Transfer-Encoding: chunked"
    else
        echo "[httpfeat] SKIP: host server did not chunk /chunked" >&2; exit 0
    fi
    RLOC=$(curl -s -D - -o /dev/null "http://127.0.0.1:$PORT/redir" | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}')
    echo "[httpfeat] host sanity: /redir -> 302 Location: ${RLOC:-<none>}"
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

export HF_CHUNKED_URL="http://10.0.2.2:$PORT/chunked"
export HF_REDIR_URL="http://10.0.2.2:$PORT/redir"

python3 - "$IMG_RW" "$OVMF_RW" "$MON" "$LOG" "$SNAP_HELPER" "$BOOT_WAIT" <<'PYDRV'
import sys, subprocess, time, threading, os
img, ovmf, mon, logpath, snap, boot_wait = sys.argv[1:7]
boot_wait = int(boot_wait)
vm_mem = os.environ.get("HAMNIX_VM_MEM", "2G")
url_chunked = os.environ["HF_CHUNKED_URL"]
url_redir = os.environ["HF_REDIR_URL"]
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
def count_from(marker, base):
    with lock:
        return buf.count(marker.encode(), base)
def wait_count(marker, base, want, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if count_from(marker, base) >= want: return True
        if qemu.poll() is not None: return False
        time.sleep(0.2)
    return False
def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception: pass
def launch_and_snap(url, label):
    with lock: base = len(buf)
    ok = False
    for attempt in range(6):
        send("hambrowse %s &" % url)
        print("[httpfeat] driver: launch %s attempt %d" % (label, attempt+1), file=sys.stderr)
        # wait for a fetch outcome AFTER this launch
        deadline = time.time() + 30
        while time.time() < deadline:
            with lock:
                seg = buf[base:]
            if b"[hambrowse] fetched http status=" in seg or b"[hambrowse] fetch FAILED" in seg:
                ok = True; break
            if qemu.poll() is not None: break
            time.sleep(0.2)
        if ok: break
    wait_for("[hambrowse] opening scene window", 20)
    time.sleep(6)
    subprocess.run([snap, label], timeout=20)
    print("[httpfeat] driver: snapped %s (outcome=%s)" % (label, ok), file=sys.stderr)
try:
    if not wait_for("M16.35 shell ready", boot_wait):
        print("[httpfeat] driver: never reached DE shell handoff", file=sys.stderr)
    else:
        print("[httpfeat] driver: handoff reached", file=sys.stderr)
        time.sleep(3)
        # WARM-UP: freshly-booted hamsh drops its first serial command.
        warmed = False
        for w in range(6):
            tag = "__WARMUP_%d__" % w
            with lock: b0 = len(buf)
            send("echo " + tag)
            dl = time.time() + 6
            while time.time() < dl:
                with lock:
                    if buf.find(tag.encode(), b0) != -1:
                        warmed = True; break
                if qemu.poll() is not None: break
                time.sleep(0.2)
            if warmed:
                print("[httpfeat] driver: warm-up ok (attempt %d)" % (w+1), file=sys.stderr)
                break
        if not warmed:
            print("[httpfeat] driver: WARNING shell never echoed warm-up", file=sys.stderr)
        # (1) CHUNKED page
        launch_and_snap(url_chunked, "chunked")
        # (2) REDIRECT page
        launch_and_snap(url_redir, "redir")
        print("[httpfeat] driver: done", file=sys.stderr)
finally:
    try: qemu.stdin.close()
    except Exception: pass
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=10)
    except Exception: qemu.kill()
PYDRV

# ppm -> png for human inspection.
for L in chunked redir; do
    if [ -s "$OUT_DIR/$L.ppm" ] && command -v pnmtopng >/dev/null 2>&1; then
        pnmtopng "$OUT_DIR/$L.ppm" > "$OUT_DIR/$L.png" 2>/dev/null || true
    fi
done

echo "[httpfeat] --- host HTTP server access log ---"
grep -aE '"GET ' "$HTTP_LOG" 2>/dev/null | sed 's/^/[httpfeat:httpd] /' || echo "[httpfeat:httpd] (no GET lines)"

echo "[httpfeat] --- evidence ---"
fail=0

# (0) INCONCLUSIVE guard: any guest hambrowse markers at all?
GUESTMARK=$(grep -ac '\[hambrowse\]' "$LOG")
echo "[httpfeat] guest hambrowse markers: $GUESTMARK"
if [ "$GUESTMARK" -eq 0 ]; then
    echo "[httpfeat] RESULT: INCONCLUSIVE (no guest [hambrowse] markers — boot/launch never happened)"
    tail -30 "$LOG" >&2
    exit 125
fi

# (1) CHUNKED: the guest fetched /chunked and did NOT reject it as rc=-7.
GOT_CHUNKED=$(grep -ac 'GET /chunked' "$HTTP_LOG")
FETCH200=$(grep -aoc '\[hambrowse\] fetched http status=200' "$LOG")
CHUNK_REJECT=$(grep -ac '\[hambrowse\] fetch FAILED rc=-7' "$LOG")
echo "[httpfeat] server saw GET /chunked: $GOT_CHUNKED ; guest fetched-200 count: $FETCH200 ; chunked-reject(rc=-7): $CHUNK_REJECT"
if [ "$GOT_CHUNKED" -ge 1 ]; then
    echo "[httpfeat] PASS guest issued GET /chunked"
else
    echo "[httpfeat] FAIL guest never requested /chunked"; fail=1
fi
if [ "$CHUNK_REJECT" -eq 0 ]; then
    echo "[httpfeat] PASS no chunked rejection (rc=-7) — chunked body decoded"
else
    echo "[httpfeat] FAIL hambrowse rejected chunked body (rc=-7)"; fail=1
fi

# (2) REDIRECT: guest GETs /redir AND then /page.html (302 followed to target).
GOT_REDIR=$(grep -ac 'GET /redir' "$HTTP_LOG")
GOT_TARGET=$(grep -ac 'GET /page.html' "$HTTP_LOG")
echo "[httpfeat] server saw GET /redir: $GOT_REDIR ; GET /page.html: $GOT_TARGET"
if [ "$GOT_REDIR" -ge 1 ]; then
    echo "[httpfeat] PASS guest issued GET /redir"
else
    echo "[httpfeat] FAIL guest never requested /redir"; fail=1
fi
if [ "$GOT_TARGET" -ge 1 ]; then
    echo "[httpfeat] PASS guest followed 302 to GET /page.html (redirect followed)"
else
    echo "[httpfeat] FAIL redirect not followed (no GET /page.html)"; fail=1
fi

# Two successful 200 fetches expected (chunked page + redirect final page).
if [ "${FETCH200:-0}" -ge 2 ]; then
    echo "[httpfeat] PASS two 200 fetches completed (chunked + redirect-final)"
else
    echo "[httpfeat] FAIL fewer than two 200 fetches ($FETCH200)"; fail=1
fi

if grep -aqi 'kernel panic\|#UD\|triple fault\|page fault' "$LOG"; then
    echo "[httpfeat] FAIL panic/fault in serial log"; fail=1
else
    echo "[httpfeat] PASS no panic during boot/run"
fi

# (3) PIXEL PROOF: magenta PNG present in at least one screendump.
count_magenta() {
    python3 - "$1" <<'PYPIX'
import sys
data = open(sys.argv[1], "rb").read()
if not data.startswith(b"P6"):
    print("0"); sys.exit(0)
idx = 2; fields = []
while len(fields) < 3 and idx < len(data):
    while idx < len(data) and data[idx:idx+1].isspace(): idx += 1
    if idx < len(data) and data[idx:idx+1] == b"#":
        while idx < len(data) and data[idx:idx+1] != b"\n": idx += 1
        continue
    start = idx
    while idx < len(data) and not data[idx:idx+1].isspace(): idx += 1
    fields.append(int(data[start:idx]))
idx += 1
pix = data[idx:]; n = (len(pix)//3)*3; mag = 0; i = 0
while i < n:
    if pix[i] >= 200 and pix[i+1] <= 70 and pix[i+2] >= 200: mag += 1
    i += 3
print(str(mag))
PYPIX
}
best_mag=0
for L in chunked redir; do
    P="$OUT_DIR/$L.ppm"
    if [ -s "$P" ]; then
        m=$(count_magenta "$P"); m=${m:-0}
        echo "[httpfeat] pixels[$L]: magenta_img=$m"
        [ "$m" -gt "$best_mag" ] && best_mag=$m
    else
        echo "[httpfeat] WARN no PPM for $L"
    fi
done
if [ "$best_mag" -ge 200 ]; then
    echo "[httpfeat] PASS served magenta PNG rendered ($best_mag px) — a served page reached the screen"
else
    echo "[httpfeat] FAIL served magenta image missing in both screendumps ($best_mag px)"; fail=1
fi

echo "[httpfeat] artifacts in $OUT_DIR"
if [ "$fail" -eq 0 ]; then
    echo "[httpfeat] RESULT: PASS"
    exit 0
else
    echo "[httpfeat] RESULT: FAIL"
    echo "[httpfeat] --- hambrowse/net serial lines ---" >&2
    grep -aiE 'hambrowse|dhcp|virtio-net|http|net_dial|10.0.2' "$LOG" | tail -60 >&2 \
        || echo "[httpfeat] (no relevant serial lines)" >&2
    exit 1
fi
