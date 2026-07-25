#!/usr/bin/env bash
# scripts/test_hambrowse_navigation_ondevice.sh — LIVE on-device gate for the
# browser-USABILITY tier: a LINK CLICK NAVIGATES over the wire, and a FORM POST
# submit sends its urlencoded body — both on the REAL EFI framebuffer boot, both
# proven by the HOST server's request log.
#
# Sibling of test_hambrowse_post_ondevice.sh (JS fetch() POST). This gate proves
# the FRONT-END navigation glue in user/hambrowse.ad end-to-end:
#   (1) LINK CLICK: hambrowse loads /start.html (an <a href="/page2.html">), then
#       the --click-link 0 test entry fires the SAME _navigate()/_resolve()/_fetch
#       path a real pointer click runs. The guest resolves the relative href
#       against the current URL and http_gets it. PROOF: the host server logs
#       GET /page2.html and the guest prints a SECOND "[hambrowse] fetched http"
#       line + the "scripted click-link" marker.
#   (2) FORM POST: hambrowse loads /postform.html whose onload script calls
#       form.submit() on a method=POST form. The front-end serializes the controls
#       into a urlencoded BODY and http_posts it to the action. PROOF: the host
#       server logs POST /login with the exact body, and the guest prints
#       "[hambrowse] form-POST http status=200".
#
# Pointer/keyboard injection is deliberately avoided (flaky, per memory) — the
# navigation is driven through programmatic entry points a test can call
# (--click-link and an on-load form.submit()).
#
# ASSERTS (three-valued: PASS / FAIL / INCONCLUSIVE):
#   * host server log: GET /page2.html  (link click navigated over the wire)
#   * host server log: POST /login body=[user=ada+love&...]  (POST body left the guest)
#   * guest serial: "[hambrowse] scripted click-link" + a 2nd fetched-http line
#   * guest serial: "[hambrowse] form-POST http status=200"
#   * no kernel panic / fault
#   Zero guest [hambrowse] markers => INCONCLUSIVE (exit 2), never a pass.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, python3, qemu, or the image
# is absent — it needs a host HTTP server + SLIRP + KVM.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/hambrowse_navigation_ondevice/$TS}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-480}"
OVMF_FD="${OVMF_FD:-/usr/share/OVMF/OVMF_CODE.fd}"
[ -f "$OVMF_FD" ] || OVMF_FD="/usr/share/ovmf/OVMF.fd"

# The distinctive username the guest must POST (space -> '+' urlencoded).
POSTUSER="${POSTUSER:-ada love}"
POSTENC="user=ada+love&remember=yes&role=admin"

[ -e /dev/kvm ] || { echo "[hb-nav-od] SKIP: /dev/kvm absent" >&2; exit 0; }
[ -f "$OVMF_FD" ] || { echo "[hb-nav-od] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[hb-nav-od] SKIP: python3 required" >&2; exit 0; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "[hb-nav-od] SKIP: qemu required" >&2; exit 0; }

# --- build / stale-guard the installer image (mirrors test_hambrowse_post) ---
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[hambrowse_navigation_ondevice]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[hb-nav-od] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[hb-nav-od] building installer image (~6 min)"
    bash "$PWD/scripts/build_installer_img.sh"
else
    newer=$(find lib user sys fs etc scripts -name '*.ad' -o -name '*.S' -newer "$INSTALLER_IMG" 2>/dev/null | head -1)
    if [ -n "$newer" ]; then
        if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
            echo "[hb-nav-od] WARNING: $INSTALLER_IMG OLDER than source ($newer) but HAMNIX_SKIP_BUILD=1 — booting STALE image" >&2
        else
            echo "[hb-nav-od] image stale (source newer: $newer) — rebuilding (~6 min)" >&2
            bash "$PWD/scripts/build_installer_img.sh"
        fi
    fi
fi

mkdir -p "$OUT_DIR"
echo "[hb-nav-od] output dir: $OUT_DIR"

SERVE_DIR=$(mktemp -d --tmpdir hamnix-navod-www.XXXXXX)

# --- pick a free TCP port on the host ---
PORT=$(python3 - <<'PYPORT'
import socket
s = socket.socket()
s.bind(("0.0.0.0", 0))
print(s.getsockname()[1])
s.close()
PYPORT
)

# --- served documents ---
cat > "$SERVE_DIR/start.html" <<'EOF'
<html><head><title>Start</title></head><body>
<h1>START PAGE</h1>
<p>The link below click-navigates to page two.</p>
<a href="/page2.html">go to page two</a>
</body></html>
EOF
cat > "$SERVE_DIR/page2.html" <<'EOF'
<html><head><title>Two</title></head><body>
<h1>PAGE TWO LOADED</h1>
<p>Link click-navigation reached the second page over the wire.</p>
</body></html>
EOF
cat > "$SERVE_DIR/postform.html" <<'EOF'
<html><head><title>Login</title></head><body>
<form id="f" action="/login" method="POST">
  <input id="u" name="user" type="text" value="">
  <input id="c1" name="remember" type="checkbox" value="yes" checked>
  <input id="c2" name="ads" type="checkbox" value="no">
  <select id="s" name="role">
    <option>guest</option>
    <option selected>admin</option>
  </select>
  <input type="submit" value="Sign in">
</form>
<script>
  var f = document.getElementById('f');
  document.getElementById('u').value = 'ada love';
  f.submit();
</script>
</body></html>
EOF
echo "[hb-nav-od] serving $SERVE_DIR on host port $PORT"

# --- the host server: serves files, echoes+logs POST bodies ---
SRV_PY="$OUT_DIR/nav_server.py"
cat > "$SRV_PY" <<'PYSRV'
import sys, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DOCROOT = sys.argv[2]

class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[nav] " + (fmt % args) + "\n"); sys.stderr.flush()
    def do_GET(self):
        path = self.path.split("?", 1)[0].lstrip("/")
        # LOUD host-side proof line for every GET (the gate greps for it).
        sys.stderr.write("[nav] GET-RECV path=%s\n" % self.path); sys.stderr.flush()
        fp = os.path.join(DOCROOT, path or "start.html")
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
        sys.stderr.write("[nav] POST-RECV path=%s clen=%d ct=%s body=[%s]\n"
                         % (self.path, clen, ct, body.decode("latin1")))
        sys.stderr.flush()
        page = b"<html><body><h1>LOGIN OK</h1></body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers(); self.wfile.write(page)

port = int(sys.argv[1])
ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
PYSRV

HTTP_LOG="$OUT_DIR/httpserver.log"
python3 "$SRV_PY" "$PORT" "$SERVE_DIR" >"$HTTP_LOG" 2>&1 &
HTTP_PID=$!

OVMF_RW=$(mktemp --tmpdir hamnix-navod.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-navod.img.XXXXXX.raw)
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

# --- host-side sanity: server serves + echoes ---
sleep 0.5
if command -v curl >/dev/null 2>&1; then
    curl -fs "http://127.0.0.1:$PORT/start.html" -o /dev/null \
        || { echo "[hb-nav-od] SKIP: host server not serving start.html" >&2; exit 0; }
    GOT=$(curl -fs -X POST --data "$POSTENC" "http://127.0.0.1:$PORT/login" || true)
    echo "[hb-nav-od] host sanity: server up (POST /login -> $(echo "$GOT" | head -c 24)...)"
fi

export NAV_PORT="$PORT"

python3 - "$IMG_RW" "$OVMF_RW" "$LOG" "$BOOT_WAIT" <<'PYDRV'
import sys, subprocess, time, threading, os
img, ovmf, logpath, boot_wait = sys.argv[1:5]
boot_wait = int(boot_wait)
vm_mem = os.environ.get("HAMNIX_VM_MEM", "2G")
port = os.environ["NAV_PORT"]
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
def count_from(marker, base):
    with lock:
        return buf.count(marker.encode(), base)
def wait_count(marker, base, want, timeout):
    m = marker.encode(); deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            if buf.count(m, base) >= want: return True
        if qemu.poll() is not None: return False
        time.sleep(0.2)
    return False
def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception: pass
def launch_and_wait(cmd, markers, tries=6, per=40):
    for attempt in range(tries):
        with lock: base = len(buf)
        send(cmd)
        print("[hb-nav-od] driver: launch attempt %d: %s" % (attempt+1, cmd), file=sys.stderr)
        deadline = time.time() + per
        while time.time() < deadline:
            with lock:
                for i, mk in enumerate(markers):
                    if buf.find(mk.encode(), base) != -1:
                        print("[hb-nav-od] driver: got marker %r on attempt %d" % (mk, attempt+1), file=sys.stderr)
                        return True
            if qemu.poll() is not None: return False
            time.sleep(0.2)
        print("[hb-nav-od] driver: no marker on attempt %d, retrying" % (attempt+1), file=sys.stderr)
    return False
try:
    if not wait_for("M16.35 shell ready", boot_wait):
        print("[hb-nav-od] driver: never reached DE shell handoff", file=sys.stderr)
    else:
        print("[hb-nav-od] driver: handoff reached", file=sys.stderr)
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
                print("[hb-nav-od] driver: shell warm-up ok (attempt %d)" % (w+1), file=sys.stderr)
                break
        if not warmed:
            print("[hb-nav-od] driver: WARNING shell never echoed warm-up", file=sys.stderr)
        # (1) LINK CLICK: load start.html, scripted-click link 0 -> /page2.html.
        launch_and_wait(
            "hambrowse http://10.0.2.2:%s/start.html --click-link 0 &" % port,
            ["[hambrowse] scripted click-link", "[hambrowse] fetch FAILED"], tries=6, per=45)
        # give the second fetch + render a moment to complete.
        wait_for("[hambrowse] rendered segs=", 20)
        time.sleep(3)
        # (2) FORM POST: load a page whose onload form.submit() POSTs to /login.
        launch_and_wait(
            "hambrowse http://10.0.2.2:%s/postform.html &" % port,
            ["[hambrowse] form-POST http status=", "[hambrowse] form-POST FAILED",
             "[hambrowse] fetch FAILED"], tries=6, per=45)
        time.sleep(3)
        print("[hb-nav-od] driver: done", file=sys.stderr)
finally:
    try: qemu.stdin.close()
    except Exception: pass
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=10)
    except Exception: qemu.kill()
PYDRV

echo "[hb-nav-od] --- host server log ---"
grep -a "GET-RECV\|POST-RECV" "$HTTP_LOG" 2>/dev/null | sed 's/^/[hb-nav-od:httpd] /' || echo "[hb-nav-od:httpd] (no request lines — guest never connected)"

echo "[hb-nav-od] --- evidence ---"
fail=0

# (0) INCONCLUSIVE guard: any guest hambrowse markers at all?
GUESTMARK=$(grep -ac '\[hambrowse\]' "$LOG")
echo "[hb-nav-od] guest hambrowse markers: $GUESTMARK"
if [ "$GUESTMARK" -eq 0 ]; then
    echo "[hb-nav-od] RESULT: INCONCLUSIVE (no guest [hambrowse] markers — boot/launch never happened)"
    tail -30 "$LOG" >&2
    exit 2
fi

# (1) LINK CLICK NAVIGATION — host saw GET /page2.html + guest click marker.
if grep -aq 'GET-RECV path=/page2.html' "$HTTP_LOG"; then
    echo "[hb-nav-od] PASS host server saw GET /page2.html — link click navigated over the wire"
else
    echo "[hb-nav-od] FAIL host server never logged GET /page2.html"
    grep -a "GET-RECV" "$HTTP_LOG" | tail -8 >&2 || true
    fail=1
fi
if grep -aq '\[hambrowse\] scripted click-link' "$LOG"; then
    echo "[hb-nav-od] PASS guest fired the scripted link click"
else
    echo "[hb-nav-od] FAIL guest never logged the scripted click-link marker"; fail=1
fi
FETCHN=$(grep -ac '\[hambrowse\] fetched http status=200' "$LOG")
if [ "$FETCHN" -ge 2 ]; then
    echo "[hb-nav-od] PASS guest completed >=2 http fetches (start + navigated page): $FETCHN"
else
    echo "[hb-nav-od] FAIL guest did not complete a second fetch (count=$FETCHN)"; fail=1
fi

# (2) FORM POST — host saw POST /login with the body + guest form-POST marker.
if grep -aq "POST-RECV path=/login .*body=\[$POSTENC\]" "$HTTP_LOG"; then
    echo "[hb-nav-od] PASS host server saw POST /login body=[$POSTENC]"
else
    echo "[hb-nav-od] FAIL host server never logged the expected POST /login body"
    grep -a "POST-RECV" "$HTTP_LOG" | tail -5 >&2 || true
    fail=1
fi
if grep -aq '\[hambrowse\] form-POST http status=200' "$LOG"; then
    echo "[hb-nav-od] PASS guest completed a form POST (status=200) over the wire"
else
    echo "[hb-nav-od] FAIL guest never logged a successful form-POST"
    grep -a '\[hambrowse\] form-POST' "$LOG" | tail -5 >&2 || true
    fail=1
fi

# (3) No panic / fault.
if grep -aqi 'kernel panic\|#UD\|triple fault\|page fault' "$LOG"; then
    echo "[hb-nav-od] FAIL panic/fault in serial log"; fail=1
else
    echo "[hb-nav-od] PASS no panic during boot/run"
fi

echo "[hb-nav-od] artifacts in $OUT_DIR (serial.log, httpserver.log, *.html)"
cp "$SERVE_DIR"/*.html "$OUT_DIR"/ 2>/dev/null || true
if [ "$fail" -eq 0 ]; then
    echo "[hb-nav-od] RESULT: PASS — link click-navigation + form POST verified over the wire on device"
    exit 0
else
    echo "[hb-nav-od] RESULT: FAIL"
    echo "[hb-nav-od] --- hambrowse/net serial lines ---" >&2
    grep -aiE 'hambrowse|dhcp|virtio-net|http|net_dial|10.0.2|click-link|form-POST' "$LOG" | tail -60 >&2 \
        || echo "[hb-nav-od] (no relevant serial lines)" >&2
    exit 1
fi
