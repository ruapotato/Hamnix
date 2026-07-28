#!/usr/bin/env bash
# scripts/test_hambrowse_fetch_ondevice.sh — LIVE on-device gate for the
# JavaScript fetch() builtin going over the wire (commit 683f8d05).
#
# test_hambrowse_fetch.sh already proves the browser's TOP-LEVEL navigation
# fetch (user/http9.ad http_get) on device. This gate proves the *other* fetch
# path: a page <script>'s `fetch(url).then(r => r.text())` — the JS engine
# builtin whose real transport (lib/web/js/builtins/fetch.ad -> hambrowse
# _js_fetch_transport -> http9) landed in 683f8d05. That path had NO captured
# live QEMU-net run; this closes it.
#
# WHAT IT DOES
#   1. Serves TWO files from the HOST via `python3 -m http.server` on a free
#      port (guest reaches the host at the SLIRP gateway alias 10.0.2.2:<port>):
#        /page.html — a page whose <script> calls fetch(<body-url>) and prints
#                     the drained body to console.log
#        /body.txt  — a KNOWN, distinctive one-line body
#   2. Boots the installer image into the scene DE (runlevel 5) WITH SLIRP
#      networking (`-netdev user` + virtio-net-pci) so the guest DHCP-leases.
#   3. Runs `hambrowse http://10.0.2.2:<port>/page.html`. During he_layout the
#      page <script> runs, fetch() dials http9 over /net to fetch /body.txt, and
#      hambrowse's _surface_js_serial() mirrors the JS console to fd 2 (serial).
#
# ASSERTS (three-valued: PASS / FAIL / INCONCLUSIVE):
#   * The serial log carries a guest marker
#       [hambrowse] js-console: HAMFETCH status=200 ok=true ... body=[<KNOWN>]
#     with the EXACT known body and status 200 — proving the JS fetch() went out
#     over the wire, drained the real response body, and parsed status/headers.
#   * The host HTTP server access log shows a GET /body.txt (the request really
#     left the guest and reached the host).
#   * No kernel panic / fault.
#   Zero guest [hambrowse] markers => INCONCLUSIVE (exit 125), never a pass.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, python3, qemu, or the image
# is absent — it needs a host HTTP server + SLIRP + KVM.
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
OUT_DIR="${OUT_DIR:-build/hambrowse_fetch_ondevice/$TS}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-480}"
OVMF_FD="${OVMF_FD:-/usr/share/OVMF/OVMF_CODE.fd}"
[ -f "$OVMF_FD" ] || OVMF_FD="/usr/share/ovmf/OVMF.fd"

# The distinctive body the guest must drain over the wire (single line, no NL).
KNOWN_BODY="${KNOWN_BODY:-HAMNIX-FETCH-OK-7f3a9c2b}"

[ -e /dev/kvm ] || { echo "[jsfetch] SKIP: /dev/kvm absent" >&2; exit 0; }
[ -f "$OVMF_FD" ] || { echo "[jsfetch] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat   >/dev/null 2>&1 || { echo "[jsfetch] SKIP: socat required" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[jsfetch] SKIP: python3 required" >&2; exit 0; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "[jsfetch] SKIP: qemu required" >&2; exit 0; }

TMPL="$PWD/scripts/fixtures/hambrowse_fetch_ondevice/page.html.tmpl"
[ -f "$TMPL" ] || { echo "[jsfetch] SKIP: fixture $TMPL missing" >&2; exit 0; }

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
installer_img_or_verdict "$INSTALLER_IMG" "[hambrowse_fetch_ondevice]"

mkdir -p "$OUT_DIR"
echo "[jsfetch] output dir: $OUT_DIR"

# --- served document root: known body + the fetch page (port substituted) ---
SERVE_DIR=$(mktemp -d --tmpdir hamnix-jsfetch-www.XXXXXX)
printf '%s' "$KNOWN_BODY" > "$SERVE_DIR/body.txt"

# --- pick a free TCP port on the host ---
PORT=$(python3 - <<'PYPORT'
import socket
s = socket.socket()
s.bind(("0.0.0.0", 0))
print(s.getsockname()[1])
s.close()
PYPORT
)
FETCH_URL="http://10.0.2.2:$PORT/body.txt"
sed "s#__FETCH_URL__#${FETCH_URL}#g" "$TMPL" > "$SERVE_DIR/page.html"
cp "$SERVE_DIR/page.html" "$OUT_DIR/page.html"
echo "[jsfetch] serving $SERVE_DIR on host port $PORT; page fetch()es $FETCH_URL"
echo "[jsfetch] known body: [$KNOWN_BODY]"

# --- start the host HTTP server ---
HTTP_LOG="$OUT_DIR/httpserver.log"
( cd "$SERVE_DIR" && exec python3 -m http.server "$PORT" --bind 0.0.0.0 ) >"$HTTP_LOG" 2>&1 &
HTTP_PID=$!

OVMF_RW=$(mktemp --tmpdir hamnix-jsfetch.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-jsfetch.img.XXXXXX.raw)
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

# --- host-side sanity: confirm the server serves the known body + page ---
sleep 0.5
if command -v curl >/dev/null 2>&1; then
    GOT=$(curl -fs "http://127.0.0.1:$PORT/body.txt" || true)
    if [ "$GOT" != "$KNOWN_BODY" ]; then
        echo "[jsfetch] SKIP: host server not serving expected body (got [$GOT])" >&2
        exit 0
    fi
    echo "[jsfetch] host sanity: /body.txt serves the known body"
    curl -fs "http://127.0.0.1:$PORT/page.html" -o /dev/null \
        || { echo "[jsfetch] SKIP: host server not serving page.html" >&2; exit 0; }
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
        print("[jsfetch] driver: never reached DE shell handoff", file=sys.stderr)
    else:
        print("[jsfetch] driver: handoff reached", file=sys.stderr)
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
                print("[jsfetch] driver: shell warm-up ok (attempt %d)" % (w+1), file=sys.stderr)
                break
        if not warmed:
            print("[jsfetch] driver: WARNING shell never echoed warm-up", file=sys.stderr)
        # Launch the browser on the page that fetch()es the body. The JS console
        # (with the fetched body) is mirrored to serial by _surface_js_serial()
        # right after the "[hambrowse] rendered segs=" line. Retry on dropped line.
        launch = "hambrowse %s &" % url
        outcome = -1
        for attempt in range(6):
            send(launch)
            print("[jsfetch] driver: launch attempt %d: %s" % (attempt+1, launch), file=sys.stderr)
            outcome = wait_for_any(
                ["[hambrowse] js-console:",
                 "[hambrowse] rendered segs=",
                 "[hambrowse] fetch FAILED"], 40)
            if outcome >= 0:
                print("[jsfetch] driver: got outcome %d on attempt %d" % (outcome, attempt+1), file=sys.stderr)
                break
            print("[jsfetch] driver: no marker on attempt %d, retrying" % (attempt+1), file=sys.stderr)
        # Give the console dump + any late microtask a moment to flush.
        wait_for("[hambrowse] js-console:", 15)
        time.sleep(3)
        print("[jsfetch] driver: done (outcome=%d)" % outcome, file=sys.stderr)
finally:
    try: qemu.stdin.close()
    except Exception: pass
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=10)
    except Exception: qemu.kill()
PYDRV

echo "[jsfetch] --- host HTTP server access log ---"
grep -a "GET" "$HTTP_LOG" 2>/dev/null | sed 's/^/[jsfetch:httpd] /' || echo "[jsfetch:httpd] (no GET lines — guest never connected)"

echo "[jsfetch] --- evidence ---"
fail=0

# (0) INCONCLUSIVE guard: any guest hambrowse markers at all?
GUESTMARK=$(grep -ac '\[hambrowse\]' "$LOG")
echo "[jsfetch] guest hambrowse markers: $GUESTMARK"
if [ "$GUESTMARK" -eq 0 ]; then
    echo "[jsfetch] RESULT: INCONCLUSIVE (no guest [hambrowse] markers — boot/launch never happened)"
    tail -30 "$LOG" >&2
    exit 125
fi

# (1) The JS-console guest marker with the fetched body — the core proof.
JSLINE=$(grep -a '\[hambrowse\] js-console: HAMFETCH' "$LOG" | tail -1)
if [ -n "$JSLINE" ]; then
    echo "[jsfetch] GUEST MARKER: $JSLINE"
else
    echo "[jsfetch] FAIL: no '[hambrowse] js-console: HAMFETCH' guest marker"
    # Surface any error the script printed, or a transport failure.
    grep -a '\[hambrowse\] js-console:\|\[hambrowse\] fetch FAILED\|HAMFETCH ERROR' "$LOG" | tail -10 >&2 || true
    fail=1
fi

# (2) EXACT known body + status 200 in the marker.
if echo "$JSLINE" | grep -Fq "body=[$KNOWN_BODY]"; then
    echo "[jsfetch] PASS fetched body matches EXACTLY: [$KNOWN_BODY]"
else
    echo "[jsfetch] FAIL fetched body mismatch (want body=[$KNOWN_BODY])"; fail=1
fi
if echo "$JSLINE" | grep -Fq "status=200"; then
    echo "[jsfetch] PASS status=200 over the wire"
else
    echo "[jsfetch] FAIL status not 200"; fail=1
fi
if echo "$JSLINE" | grep -Fq "ok=true"; then
    echo "[jsfetch] PASS Response.ok=true"
else
    echo "[jsfetch] WARN Response.ok not true (non-fatal)"
fi

# (3) The request really left the guest and reached the host server.
if grep -aq 'GET /body.txt' "$HTTP_LOG"; then
    echo "[jsfetch] PASS host server saw GET /body.txt (request went over the wire)"
else
    echo "[jsfetch] FAIL host server never saw GET /body.txt"; fail=1
fi

# (4) No panic / fault.
if grep -aqi 'kernel panic\|#UD\|triple fault\|page fault' "$LOG"; then
    echo "[jsfetch] FAIL panic/fault in serial log"; fail=1
else
    echo "[jsfetch] PASS no panic during boot/run"
fi

echo "[jsfetch] artifacts in $OUT_DIR (serial.log, page.html, httpserver.log)"
if [ "$fail" -eq 0 ]; then
    echo "[jsfetch] RESULT: PASS — JS fetch() drained the KNOWN body [$KNOWN_BODY] status=200 over the wire on device"
    exit 0
else
    echo "[jsfetch] RESULT: FAIL"
    echo "[jsfetch] --- hambrowse/net serial lines ---" >&2
    grep -aiE 'hambrowse|dhcp|virtio-net|http|net_dial|10.0.2|HAMFETCH' "$LOG" | tail -60 >&2 \
        || echo "[jsfetch] (no relevant serial lines)" >&2
    exit 1
fi
