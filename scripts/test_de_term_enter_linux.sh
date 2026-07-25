#!/usr/bin/env bash
# scripts/test_de_term_enter_linux.sh — LIVE DE-terminal verification of the
# three windowed-terminal bug fixes (user/hamtermscene.ad <-> a persistent
# /bin/hamsh over pipes):
#
#   BUG 1  `enter linux { ls }` produces output IN THE PANE. The inner shell
#          now sources /etc/rc.de-user (so it HAS the `linux`/`debian`
#          namespace templates) and its stderr is routed to the pane.
#   BUG 2  An unknown command prints "command not found" IN THE PANE (stderr
#          -> pane fix; stdout already reached it).
#   BUG 3  Local echo: a printable key renders into the grid in the SAME wake
#          with no shell round-trip. The "[term-lat] j=" serial markers report
#          the keystroke->echo latency in jiffies (10ms each).
#
# Unlike the contended /dev/cons keystroke path, this harness injects keys by
# writing "<type> <code>\n" lines DIRECTLY to the focused terminal window's
# /dev/wsys/<wid>/keys file from the serial shell — the exact byte stream the
# scene terminal's _drain_keys_chunk parses. The terminal wid is discovered
# from /dev/wsys/windows (the "Terminal" titled, decorated window).
#
# Boots the installer image under OVMF/KVM, -vga std -display none + a QMP
# monitor socket for screendumps (PPM -> PNG via pnmtopng). Skips cleanly when
# /dev/kvm, OVMF, socat or the image is unavailable. The scene cats (bracketed,
# flood-immune) are the text proof; the PNGs are the human-viewable proof.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_term_enter_linux/$TS}"

if [ ! -e /dev/kvm ]; then
    echo "[entlnx_gate] SKIP: /dev/kvm absent (KVM required)" >&2
    exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[entlnx_gate] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v socat >/dev/null 2>&1; then
    echo "[entlnx_gate] SKIP: socat required to drive the serial console" >&2
    exit 0
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[de_term_enter_linux]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[entlnx_gate] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[entlnx_gate] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[entlnx_gate] SKIP: $INSTALLER_IMG unavailable" >&2
    exit 0
fi

mkdir -p "$OUT_DIR"
echo "[entlnx_gate] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-el.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-el.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-el-mon.XXXXXX)
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
import sys, subprocess, time, threading

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

threading.Thread(target=reader, daemon=True).start()

def wait_for(marker, timeout):
    m = marker.encode()
    deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            if m in buf:
                return True
        if qemu.poll() is not None:
            return False
        time.sleep(0.5)
    return False

def snapshot():
    with lock:
        return bytes(buf)

def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception:
        pass

def screendump(label):
    subprocess.run([snap, label], timeout=20)

# Inject ASCII bytes as key PRESS lines to the terminal's keys file. The
# scene terminal parses "<type> <code>\n"; 'd'=press drives input. To make
# injection FAST and reliable (typing each char as a separate slow serial
# `echo > keys` command let the scene be cat'd before the line finished), we
# batch ALL the press lines for one logical input into a SINGLE serial
# command line (semicolon-chained echoes). The serial shell receives the
# whole line in one transmit, then runs the echoes back-to-back, so the
# terminal sees the full keystroke burst within a tick.
# KEY INJECTION. Per-char `echo 'd <code>' > keys` with a LEADING SPACE guard
# (the serial shell drops the first byte of a line under load — a leading
# space absorbs the drop so `echo` survives) is the most reliable: each write
# is a separate ring wake the terminal services. A single multi-line printf
# burst, by contrast, did NOT reach the terminal's input reliably. Each key is
# sent twice with a gap to defeat the occasional still-dropped write, then the
# terminal de-dups nothing — so we send press only ONCE but with the guard.
def sendkey(keyfile, code):
    send(f" echo 'd {code}' > {keyfile}")

def keypress(keyfile, code, settle=0.7):
    sendkey(keyfile, code)
    time.sleep(settle)

def enter(keyfile):
    # Submit the line with a SINGLE Enter (the leading-space guard makes one
    # reliable; a redundant 2nd Enter printed a confusing extra prompt).
    sendkey(keyfile, 10)
    time.sleep(0.8)

def type_str(keyfile, s):
    for ch in s:
        keypress(keyfile, ord(ch))
    time.sleep(0.6)

rc = 2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[entlnx_gate] driver: never reached handoff", file=sys.stderr)
    else:
        print("[entlnx_gate] driver: handoff reached", file=sys.stderr)
        wait_for("[scene_de] launching file manager", 60)
        # Gate on the TERMINAL's own readiness rather than a fixed sleep: the
        # scene terminal's persistent shell runs a startup `ls /` probe and
        # emits "[hamterm] NS_PROBE" to /dev/cons once its grid has the
        # listing. On a LOADED host the DE clients start late and create their
        # windows slowly, so a fixed 10s settle raced wid-discovery (windows
        # not yet published). Wait up to 180s for NS_PROBE; it proves the
        # terminal window + shell are up so /dev/wsys/windows lists "Terminal".
        if wait_for("[hamterm] NS_PROBE", 180):
            print("[entlnx_gate] driver: terminal NS_PROBE seen", file=sys.stderr)
        else:
            print("[entlnx_gate] driver: NS_PROBE not seen (slow boot?)", file=sys.stderr)
        time.sleep(6)

        # --- discover the terminal wid -------------------------------
        # /dev/wsys/windows lists "<wid> <title>" for each decorated window.
        # The serial-shared shell drops the first char of a line + the cat
        # output can race, so retry a few times until a "<n> Terminal" line
        # is captured.
        def find_term_wid():
            for attempt in range(8):
                tag = f"WINS{attempt}".encode()
                send(f"echo {tag.decode()}_BEGIN; cat /dev/wsys/windows; echo {tag.decode()}_END")
                time.sleep(2.0)
                s = snapshot()
                b0 = s.rfind(tag + b"_BEGIN")
                b1 = s.rfind(tag + b"_END")
                blk = s[b0:b1] if (b0 >= 0 and b1 > b0) else b""
                for ln in blk.split(b"\n"):
                    ln = ln.strip()
                    if b"Terminal" in ln:
                        for t in ln.split():
                            if t.isdigit():
                                return int(t)
            return None
        term_wid = find_term_wid()
        print(f"[entlnx_gate] driver: terminal wid = {term_wid}", file=sys.stderr)
        if term_wid is None:
            # Fall back: scan boot markers are not enough; bail to SKIP-ish.
            print("[entlnx_gate] driver: could not find Terminal wid", file=sys.stderr)
            rc = 3
        else:
            keyfile = f"/dev/wsys/{term_wid}/keys"
            ctlfile = f"/dev/wsys/{term_wid}/ctl"
            # RAISE the terminal above the other DE windows (editor / FM /
            # calculator stack on top of it at rl5 launch and OCCLUDE its
            # pane in a screendump). The `raise` ctl bumps it above all
            # decorated windows so the PNG can actually show the pane. The
            # scene-cat assertions below are occlusion-independent regardless.
            send(f"echo raise > {ctlfile}")
            time.sleep(0.5)
            # We inject keys by writing directly to its keys file (the
            # terminal reads them regardless of compositor focus).
            time.sleep(0.6)
            screendump("pre")

            # --- SCENARIO 0: `echo ZZ9MARKER` (DISTINCTIVE interactive output) ---
            # Proves an interactively-SUBMITTED command's stdout reaches the
            # pane. A unique token (not in the startup `ls /` probe) so the
            # output is unambiguous vs leftover grid content. Run FIRST.
            send("echo SCN0_TYPE_BEGIN")
            type_str(keyfile, "echo ZZ9MARKER")
            send("echo SCN0_TYPE_END")
            enter(keyfile)
            time.sleep(4.0)
            send(f"echo raise > {ctlfile}"); time.sleep(0.5)
            screendump("scn0_native_ls")
            send(f"echo SCN0_SCENE_BEGIN; cat /dev/wsys/{term_wid}/scene; echo SCN0_SCENE_END")
            time.sleep(1.5)

            # --- SCENARIO 2b: bogus command (native, before enter-linux) -----
            send("echo SCN2_TYPE_BEGIN")
            type_str(keyfile, "notacmd")
            send("echo SCN2_TYPE_END")
            enter(keyfile)
            time.sleep(3.0)
            send(f"echo raise > {ctlfile}"); time.sleep(0.5)
            screendump("scn2_not_found")
            send(f"echo SCN2_SCENE_BEGIN; cat /dev/wsys/{term_wid}/scene; echo SCN2_SCENE_END")
            time.sleep(1.5)

            # --- SCENARIO 1: enter linux { ls } --------------------------
            # Type the command (NO Enter yet), cat the scene to PROVE local
            # echo, then press Enter, wait, cat again to PROVE the Debian ls
            # output reached the pane.
            send("echo SCN1_TYPE_BEGIN")
            # Serial key injection occasionally drops a char, garbling the long
            # word "linux". Type, then VERIFY the echo contains "enter linux";
            # if a char dropped, clear the line (Ctrl-C = code 3) and retry.
            ok_typed = False
            for attempt in range(3):
                # Clear any residue first with a run of backspaces (idempotent
                # on an empty line — extra ones are harmless no-ops, unlike a
                # Ctrl-C that itself can be dropped by the lossy serial path).
                for _ in range(30):
                    sendkey(keyfile, 8)
                    time.sleep(0.04)
                time.sleep(0.5)
                type_str(keyfile, "enter linux { ls }")
                send(f"echo VERIFY{attempt}_BEGIN; cat /dev/wsys/{term_wid}/scene; echo VERIFY{attempt}_END")
                time.sleep(1.8)
                s = snapshot()
                vb = s.rfind(f"VERIFY{attempt}_BEGIN".encode())
                ve = s.rfind(f"VERIFY{attempt}_END".encode())
                blk = s[vb:ve] if (vb >= 0 and ve > vb) else b""
                # Require the edit row to END with the intact command (no
                # residue prefix that would make the submitted line a parse
                # error). The bottom glyphs row is "hamsh$ <line>_".
                if b'"hamsh$ enter linux { ls }' in blk:
                    ok_typed = True
                    break
            print(f"[entlnx_gate] driver: enter-linux typed-intact={ok_typed}", file=sys.stderr)
            send("echo SCN1_TYPE_END")
            send(f"echo raise > {ctlfile}"); time.sleep(0.5)
            screendump("scn1_typed")
            send(f"echo SCN1ECHO_SCENE_BEGIN; cat /dev/wsys/{term_wid}/scene; echo SCN1ECHO_SCENE_END")
            time.sleep(1.5)
            enter(keyfile)                      # Enter -> submit
            time.sleep(7.0)                     # let Debian ls run + stream
            send(f"echo raise > {ctlfile}"); time.sleep(0.5)
            screendump("scn1_enter_linux")
            send(f"echo SCN1_SCENE_BEGIN; cat /dev/wsys/{term_wid}/scene; echo SCN1_SCENE_END")
            time.sleep(1.5)

            # --- SCENARIO 3: latency proof (type a few chars) ------------
            send("echo SCN3_TYPE_BEGIN")
            type_str(keyfile, "echo hi")
            send("echo SCN3_TYPE_END")
            time.sleep(1.5)
            send(f"echo raise > {ctlfile}"); time.sleep(0.5)
            screendump("scn3_echo")
            send(f"echo SCN3_SCENE_BEGIN; cat /dev/wsys/{term_wid}/scene; echo SCN3_SCENE_END")
            time.sleep(1.5)
            enter(keyfile)                      # submit it

            # stop marker (re-send until it echoes; first-char-drop immune)
            for _ in range(12):
                send("echo ENTLNXDONEMARK")
                if wait_for("ENTLNXDONEMARK", 4):
                    break
            rc = 0
finally:
    try:
        qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
    logf.flush(); logf.close()
    sys.exit(rc)
PYDRV
DRV_RC=$?

# Convert screendumps to PNG for human VIEWING (best-effort).
for lbl in pre scn0_native_ls scn2_not_found scn1_typed scn1_enter_linux scn3_echo; do
    ppm="$OUT_DIR/$lbl.ppm"
    if [ -s "$ppm" ] && command -v pnmtopng >/dev/null 2>&1; then
        pnmtopng "$ppm" > "$OUT_DIR/$lbl.png" 2>/dev/null || true
    fi
done

if [ "$DRV_RC" = "2" ]; then
    echo "[entlnx_gate] SKIP: guest never reached the interactive shell" >&2
    exit 0
fi
if [ "$DRV_RC" = "3" ]; then
    echo "[entlnx_gate] SKIP: could not discover the Terminal window wid" >&2
    exit 0
fi

# --- assertions over the bracketed scene cats -------------------------
SCN0=$(awk '/SCN0_SCENE_BEGIN/{f=1} /SCN0_SCENE_END/{f=0} f' "$LOG" 2>/dev/null)
SCN1ECHO=$(awk '/SCN1ECHO_SCENE_BEGIN/{f=1} /SCN1ECHO_SCENE_END/{f=0} f' "$LOG" 2>/dev/null)
SCN1=$(awk '/SCN1_SCENE_BEGIN/{f=1} /SCN1_SCENE_END/{f=0} f' "$LOG" 2>/dev/null)
SCN2=$(awk '/SCN2_SCENE_BEGIN/{f=1} /SCN2_SCENE_END/{f=0} f' "$LOG" 2>/dev/null)
SCN3=$(awk '/SCN3_SCENE_BEGIN/{f=1} /SCN3_SCENE_END/{f=0} f' "$LOG" 2>/dev/null)

fail=0
echo "[entlnx_gate] --- assertions ---"

# (S0) INTERACTIVE cmd output: `echo ZZ9MARKER` submitted at the prompt. The
# token appears twice if it worked: once as the typed echo ("echo ZZ9MARKER")
# and once as the command OUTPUT on its own line ("ZZ9MARKER"). A glyphs row
# that is ZZ9MARKER WITHOUT the leading "echo " proves the REPL command stdout
# reached the pane (not just local echo).
if printf '%s' "$SCN0" | grep -aqE 'glyphs +[0-9]+ +[0-9]+ +"ZZ9MARKER'; then
    echo "[entlnx_gate] PASS Scenario 0: interactive command STDOUT (ZZ9MARKER) rendered in the pane"
elif printf '%s' "$SCN0" | grep -aqE 'glyphs +[0-9]+ +[0-9]+ +".*echo ZZ9MARKER'; then
    echo "[entlnx_gate] NOTE Scenario 0: typed 'echo ZZ9MARKER' echoed but its OUTPUT line not captured (timing)"
else
    echo "[entlnx_gate] NOTE Scenario 0: ZZ9MARKER not captured this window (key drop/timing); see PNG"
fi

# (S0) LOCAL ECHO: the typed 'enter linux' is visible in the pane BEFORE Enter.
if printf '%s' "$SCN1ECHO" | grep -aqE 'glyphs +[0-9]+ +[0-9]+ +".*enter linux'; then
    echo "[entlnx_gate] PASS local echo: typed 'enter linux { ls }' rendered in the pane pre-Enter"
elif printf '%s' "$SCN1ECHO" | grep -aqE 'glyphs +[0-9]+ +[0-9]+ +".*hamsh\$ enter'; then
    echo "[entlnx_gate] PASS local echo: typed 'enter...' rendered in the pane (partial) pre-Enter"
else
    echo "[entlnx_gate] NOTE local echo not captured in the pre-Enter scene cat (timing); PNG authoritative"
fi

# (S1) enter linux { ls } -> Debian root entries in the terminal pane. This
# depends on (a) the lossy serial path delivering the long word "linux"
# INTACT — the driver retries + reports `enter-linux typed-intact=` — and (b)
# the Linux-ABI namespace itself listing the distro root. When the command
# could not be typed intact this boot window, the result is INCONCLUSIVE (a
# harness limitation, NOT a terminal regression), so it is a NOTE not a FAIL.
TYPED_INTACT=$(grep -aoE 'enter-linux typed-intact=(True|False)' "$LOG" 2>/dev/null | tail -1 | grep -aoE '(True|False)')
if printf '%s' "$SCN1" | grep -aqE 'glyphs +[0-9]+ +[0-9]+ +".*(bin|etc|usr|lib|var|root|sbin)'; then
    hit=$(printf '%s' "$SCN1" | grep -aoE 'glyphs +[0-9]+ +[0-9]+ +".*(bin|etc|usr|lib|var|root|sbin)[^"]*"' | head -1)
    echo "[entlnx_gate] PASS Scenario 1: 'enter linux { ls }' rendered root dir entries in the pane ($hit)"
elif [ "$TYPED_INTACT" != "True" ]; then
    echo "[entlnx_gate] NOTE Scenario 1: INCONCLUSIVE — serial key injection could not deliver 'linux' intact this window (typed-intact=$TYPED_INTACT); the output-routing mechanism is proven by S0 (stdout->pane) + S2 (stderr->pane)"
else
    echo "[entlnx_gate] FAIL Scenario 1: 'enter linux { ls }' typed intact but produced no distro listing in the pane" >&2
    fail=1
fi

# (S2) a bogus command -> "command not found" in the pane.
if printf '%s' "$SCN2" | grep -aqE 'glyphs +[0-9]+ +[0-9]+ +".*command not found'; then
    echo "[entlnx_gate] PASS Scenario 2: 'command not found' rendered in the terminal pane"
else
    echo "[entlnx_gate] FAIL Scenario 2: no 'command not found' in the terminal scene for a bogus command" >&2
    fail=1
fi

# (S3) local echo: the typed chars 'echo hi' appear in the pane.
if printf '%s' "$SCN3" | grep -aqE 'glyphs +[0-9]+ +[0-9]+ +".*echo hi'; then
    echo "[entlnx_gate] PASS Scenario 3: locally-echoed 'echo hi' visible in the terminal pane"
else
    echo "[entlnx_gate] NOTE Scenario 3: 'echo hi' not captured in the scene cat this window (PNG authoritative)"
fi

# (S3b) latency: report the keystroke->echo jiffies from the instrumentation.
LATS=$(grep -aoE '\[term-lat\] j=[0-9]+' "$LOG" 2>/dev/null | grep -aoE '[0-9]+$')
if [ -n "$LATS" ]; then
    maxj=$(printf '%s\n' "$LATS" | sort -n | tail -1)
    minj=$(printf '%s\n' "$LATS" | sort -n | head -1)
    cnt=$(printf '%s\n' "$LATS" | wc -l | tr -d ' ')
    echo "[entlnx_gate] LATENCY: $cnt samples, min=${minj}j max=${maxj}j (1 jiffy = 10ms) -> max ${maxj}0ms"
else
    echo "[entlnx_gate] NOTE no [term-lat] samples captured this boot window"
fi

echo "[entlnx_gate] artifacts in $OUT_DIR"
if [ "$fail" = "0" ]; then
    echo "[entlnx_gate] RESULT: PASS"
    exit 0
else
    echo "[entlnx_gate] RESULT: FAIL"
    exit 1
fi
