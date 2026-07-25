#!/usr/bin/env bash
# scripts/test_hambrowse_post_ondevice.sh — LIVE on-device gate for the
# JavaScript fetch() builtin doing a REAL over-the-wire HTTP POST.
#
# Sibling of scripts/test_hambrowse_fetch_ondevice.sh (which proves GET). GET was
# already proven live; http9 used to be GET-only, so fetch(url,{method:'POST'})
# forwarded the method/body but the request still went out as GET. This gate
# proves the POST path added to user/http9.ad (http_post) end-to-end: a page
# <script> calls fetch(url,{method:'POST',body:'<token>'}) and the HOST echo
# server returns the received body — we assert BOTH the guest marker shows the
# echoed token AND the host server log shows a POST with the correct
# Content-Length / body.
#
# WHAT IT DOES
#   1. Runs a tiny HOST echo server (python http.server subclass) on a free port
#      (guest reaches the host at the SLIRP gateway alias 10.0.2.2:<port>):
#        GET  /page.html — a page whose <script> POSTs <token> to /echo
#        POST /echo      — reads the request body and returns it verbatim; logs
#                          "POST-RECV path=/echo clen=<n> body=[<body>]"
#   2. Boots the installer image into the scene DE (runlevel 5) WITH SLIRP
#      networking so the guest DHCP-leases.
#   3. Runs `hambrowse http://10.0.2.2:<port>/page.html`. During he_layout the
#      page <script> runs, fetch() dials http9's http_post over /net, POSTs the
#      token, drains the echoed response, and _surface_js_serial() mirrors the
#      JS console to fd 2 (serial).
#
# ASSERTS (three-valued: PASS / FAIL / INCONCLUSIVE):
#   * The serial log carries a guest marker
#       [hambrowse] js-console: HAMPOST status=200 ok=true ... echo=[<TOKEN>]
#     with the EXACT token and status 200 — proving the JS fetch() POST went out
#     over the wire, sent the body, and drained the echoed response.
#   * The host echo-server log shows POST /echo with the correct Content-Length
#     and body (the request body really left the guest and reached the host).
#   * No kernel panic / fault.
#   Zero guest [hambrowse] markers => INCONCLUSIVE (exit 2), never a pass.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, python3, qemu, or the image
# is absent — it needs a host HTTP server + SLIRP + KVM.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/hambrowse_post_ondevice/$TS}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-480}"
OVMF_FD="${OVMF_FD:-/usr/share/OVMF/OVMF_CODE.fd}"
[ -f "$OVMF_FD" ] || OVMF_FD="/usr/share/ovmf/OVMF.fd"

# The distinctive token the guest must POST (and the server must echo back).
TOKEN="${TOKEN:-HAMNIX-POST-9d41ce7a}"

[ -e /dev/kvm ] || { echo "[jspost] SKIP: /dev/kvm absent" >&2; exit 0; }
[ -f "$OVMF_FD" ] || { echo "[jspost] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat   >/dev/null 2>&1 || { echo "[jspost] SKIP: socat required" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[jspost] SKIP: python3 required" >&2; exit 0; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "[jspost] SKIP: qemu required" >&2; exit 0; }

TMPL="$PWD/scripts/fixtures/hambrowse_post_ondevice/page.html.tmpl"
[ -f "$TMPL" ] || { echo "[jspost] SKIP: fixture $TMPL missing" >&2; exit 0; }

# --- build / stale-guard the installer image (mirrors test_hambrowse_fetch) ---
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[hambrowse_post_ondevice]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[jspost] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[jspost] building installer image (~6 min)"
    bash "$PWD/scripts/build_installer_img.sh"
else
    newer=$(find lib user sys fs etc scripts -name '*.ad' -o -name '*.S' -newer "$INSTALLER_IMG" 2>/dev/null | head -1)
    if [ -n "$newer" ]; then
        if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
            echo "[jspost] WARNING: $INSTALLER_IMG OLDER than source ($newer) but HAMNIX_SKIP_BUILD=1 — booting STALE image" >&2
        else
            echo "[jspost] image stale (source newer: $newer) — rebuilding (~6 min)" >&2
            bash "$PWD/scripts/build_installer_img.sh"
        fi
    fi
fi

mkdir -p "$OUT_DIR"
echo "[jspost] output dir: $OUT_DIR"

# --- served document root: the POST page (URL substituted below) ---
SERVE_DIR=$(mktemp -d --tmpdir hamnix-jspost-www.XXXXXX)

# --- pick a free TCP port on the host ---
PORT=$(python3 - <<'PYPORT'
import socket
s = socket.socket()
s.bind(("0.0.0.0", 0))
print(s.getsockname()[1])
s.close()
PYPORT
)
POST_URL="http://10.0.2.2:$PORT/echo"
sed -e "s#__POST_URL__#${POST_URL}#g" -e "s#__TOKEN__#${TOKEN}#g" \
    "$TMPL" > "$SERVE_DIR/page.html"
cp "$SERVE_DIR/page.html" "$OUT_DIR/page.html"
echo "[jspost] serving $SERVE_DIR on host port $PORT; page POSTs token to $POST_URL"
echo "[jspost] token: [$TOKEN]"

# --- the host echo server: GET serves files, POST echoes the body + logs it ---
SRV_PY="$OUT_DIR/echo_server.py"
cat > "$SRV_PY" <<'PYSRV'
import sys, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DOCROOT = sys.argv[2]

class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[echo] " + (fmt % args) + "\n"); sys.stderr.flush()
    def do_GET(self):
        path = self.path.split("?", 1)[0].lstrip("/")
        fp = os.path.join(DOCROOT, path or "page.html")
        if not os.path.isfile(fp):
            self.send_response(404); self.end_headers(); return
        data = open(fp, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        clen = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(clen) if clen > 0 else b""
        ct = self.headers.get("Content-Type", "")
        # LOUD host-side proof line (the gate greps for this).
        sys.stderr.write("[echo] POST-RECV path=%s clen=%d ct=%s body=[%s]\n"
                         % (self.path, clen, ct, body.decode("latin1")))
        sys.stderr.flush()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

port = int(sys.argv[1])
ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
PYSRV

HTTP_LOG="$OUT_DIR/httpserver.log"
python3 "$SRV_PY" "$PORT" "$SERVE_DIR" >"$HTTP_LOG" 2>&1 &
HTTP_PID=$!

OVMF_RW=$(mktemp --tmpdir hamnix-jspost.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-jspost.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
cleanup() {
    kill "$HTTP_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW"
    rm -rf "$SERVE_DIR"
}
trap cleanup EXIT
: > "$LOG"

# --- host-side sanity: confirm the echo server round-trips a POST ---
sleep 0.5
if command -v curl >/dev/null 2>&1; then
    GOT=$(curl -fs -X POST --data "$TOKEN" "http://127.0.0.1:$PORT/echo" || true)
    if [ "$GOT" != "$TOKEN" ]; then
        echo "[jspost] SKIP: host echo server not echoing POST body (got [$GOT])" >&2
        exit 0
    fi
    echo "[jspost] host sanity: POST /echo round-trips the token"
    curl -fs "http://127.0.0.1:$PORT/page.html" -o /dev/null \
        || { echo "[jspost] SKIP: host server not serving page.html" >&2; exit 0; }
fi

export HAMBROWSE_URL="http://10.0.2.2:$PORT/page.html"

python3 - "$IMG_RW" "$OVMF_RW" "$LOG" "$BOOT_WAIT" <<'PYDRV'
import sys, subprocess, time, threading, os
img, ovmf, logpath, boot_wait = sys.argv[1:5]
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
        print("[jspost] driver: never reached DE shell handoff", file=sys.stderr)
    else:
        print("[jspost] driver: handoff reached", file=sys.stderr)
        time.sleep(3)
        # WARM-UP: a freshly-booted hamsh drops its first serial command.
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
                print("[jspost] driver: shell warm-up ok (attempt %d)" % (w+1), file=sys.stderr)
                break
        if not warmed:
            print("[jspost] driver: WARNING shell never echoed warm-up", file=sys.stderr)
        # Launch the browser on the page that POSTs the token.
        launch = "hambrowse %s &" % url
        outcome = -1
        for attempt in range(6):
            send(launch)
            print("[jspost] driver: launch attempt %d: %s" % (attempt+1, launch), file=sys.stderr)
            outcome = wait_for_any(
                ["[hambrowse] js-console:",
                 "[hambrowse] rendered segs=",
                 "[hambrowse] fetch FAILED"], 40)
            if outcome >= 0:
                print("[jspost] driver: got outcome %d on attempt %d" % (outcome, attempt+1), file=sys.stderr)
                break
            print("[jspost] driver: no marker on attempt %d, retrying" % (attempt+1), file=sys.stderr)
        # Give the console dump + any late microtask a moment to flush.
        wait_for("[hambrowse] js-console:", 15)
        time.sleep(3)
        print("[jspost] driver: done (outcome=%d)" % outcome, file=sys.stderr)
finally:
    try: qemu.stdin.close()
    except Exception: pass
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=10)
    except Exception: qemu.kill()
PYDRV

echo "[jspost] --- host echo-server log ---"
grep -a "POST-RECV\|POST /echo" "$HTTP_LOG" 2>/dev/null | sed 's/^/[jspost:httpd] /' || echo "[jspost:httpd] (no POST lines — guest never connected)"

echo "[jspost] --- evidence ---"
fail=0

# (0) INCONCLUSIVE guard: any guest hambrowse markers at all?
GUESTMARK=$(grep -ac '\[hambrowse\]' "$LOG")
echo "[jspost] guest hambrowse markers: $GUESTMARK"
if [ "$GUESTMARK" -eq 0 ]; then
    echo "[jspost] RESULT: INCONCLUSIVE (no guest [hambrowse] markers — boot/launch never happened)"
    tail -30 "$LOG" >&2
    exit 2
fi

# (1) The JS-console guest marker with the echoed token — the core proof.
JSLINE=$(grep -a '\[hambrowse\] js-console: HAMPOST' "$LOG" | tail -1)
if [ -n "$JSLINE" ]; then
    echo "[jspost] GUEST MARKER: $JSLINE"
else
    echo "[jspost] FAIL: no '[hambrowse] js-console: HAMPOST' guest marker"
    grep -a '\[hambrowse\] js-console:\|\[hambrowse\] fetch FAILED\|HAMPOST ERROR' "$LOG" | tail -10 >&2 || true
    fail=1
fi

# (2) EXACT echoed token + status 200 in the marker.
if echo "$JSLINE" | grep -Fq "echo=[$TOKEN]"; then
    echo "[jspost] PASS echoed POST body matches EXACTLY: [$TOKEN]"
else
    echo "[jspost] FAIL echoed body mismatch (want echo=[$TOKEN])"; fail=1
fi
if echo "$JSLINE" | grep -Fq "status=200"; then
    echo "[jspost] PASS status=200 over the wire"
else
    echo "[jspost] FAIL status not 200"; fail=1
fi
if echo "$JSLINE" | grep -Fq "ok=true"; then
    echo "[jspost] PASS Response.ok=true"
else
    echo "[jspost] WARN Response.ok not true (non-fatal)"
fi

# (3) The host echo server saw a real POST /echo with the token body + a
#     matching Content-Length (proving http_post wrote method+body onto the wire).
CLEN=${#TOKEN}
if grep -aq "POST-RECV path=/echo clen=$CLEN .*body=\[$TOKEN\]" "$HTTP_LOG"; then
    echo "[jspost] PASS host server saw POST /echo clen=$CLEN body=[$TOKEN]"
else
    echo "[jspost] FAIL host server never logged the expected POST body"
    grep -a "POST-RECV" "$HTTP_LOG" | tail -5 >&2 || true
    fail=1
fi

# (4) No panic / fault.
if grep -aqi 'kernel panic\|#UD\|triple fault\|page fault' "$LOG"; then
    echo "[jspost] FAIL panic/fault in serial log"; fail=1
else
    echo "[jspost] PASS no panic during boot/run"
fi

echo "[jspost] artifacts in $OUT_DIR (serial.log, page.html, httpserver.log)"
if [ "$fail" -eq 0 ]; then
    echo "[jspost] RESULT: PASS — JS fetch() POSTed the token [$TOKEN] and drained the echo status=200 over the wire on device"
    exit 0
else
    echo "[jspost] RESULT: FAIL"
    echo "[jspost] --- hambrowse/net serial lines ---" >&2
    grep -aiE 'hambrowse|dhcp|virtio-net|http|net_dial|10.0.2|HAMPOST' "$LOG" | tail -60 >&2 \
        || echo "[jspost] (no relevant serial lines)" >&2
    exit 1
fi
