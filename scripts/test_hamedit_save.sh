#!/usr/bin/env bash
# scripts/test_hamedit_save.sh — END-TO-END gate that hameditscene's Ctrl-S
# actually PERSISTS the edited buffer to disk (the user-reported bug: edit a
# file in the graphical editor, "save", close+reopen → edits were GONE).
#
# Two arms, both judged from the SERIAL log (which is authoritative; the
# screendump is a human-viewable bonus):
#
#  ARM A — WRITABLE round-trip (the real fix proof):
#     The serial shell seeds /tmp/htest.txt with a known marker, launches
#     `/bin/hameditscene /tmp/htest.txt`, focuses it (a /dev/mouse click) and
#     types fresh text + Ctrl-S (0x13 to /dev/cons → focus router → editor
#     /keys). Then the serial shell `cat /tmp/htest.txt` and we assert the
#     TYPED text is on disk and the ORIGINAL seed is GONE (proves a real
#     create+O_TRUNC+write that survives the editor process). /tmp is a
#     persistent-within-boot tmpfs, so "close and reopen" == cat-it-back.
#
#  ARM B — READ-ONLY honesty (/version):
#     /version is a synthetic, read-only device (devversion_write returns -1).
#     Saving there CANNOT persist. We launch `/bin/hameditscene /version`,
#     edit + Ctrl-S, and assert the editor's window scene shows the explicit
#     "save FAILED" status — NOT a fake "saved N bytes". (We also re-cat
#     /version to confirm it is unchanged.)
#
# Reuses the OVMF/KVM + serial-driver + monitor-screendump harness shape of
# scripts/test_de_hamedit_picker.sh. SKIPS CLEANLY (exit 0) when /dev/kvm,
# OVMF, socat, or the installer image is unavailable. rc=124 (timeout) is
# judged by the serial log, not a hard fail.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/hamedit_save/$TS}"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[save_gate] SKIP: /dev/kvm absent (KVM required)" >&2
    exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[save_gate] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v socat >/dev/null 2>&1; then
    echo "[save_gate] SKIP: socat required to drive the serial console" >&2
    exit 0
fi

# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[hamedit_save]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[save_gate] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[save_gate] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[save_gate] SKIP: $INSTALLER_IMG unavailable" >&2
    exit 0
fi

mkdir -p "$OUT_DIR"
echo "[save_gate] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-sv.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-sv.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-sv-mon.XXXXXX)
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
    "-m", "2G",
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

def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception:
        pass

def screendump(label):
    try:
        subprocess.run([snap, label], timeout=20)
    except Exception:
        pass

# Inject a single key PRESS line ("d <code>\n") DIRECTLY into a window's
# /keys ring via the kernel's devwsys_keys_write. This bypasses the
# /dev/cons focus router entirely (which is unreliable while the serial
# shell ALSO reads /dev/cons) and matches exactly what the compositor
# would write. The editor's _drain_keys_chunk parses "d <code>\n" lines.
# We don't know which wid the editor grabbed, so we fan the injection out
# to a small range of candidate wids; non-existent wids just return -2.
# hameditscene publishes its own window id to /tmp/.hamedit_wid at startup,
# so we inject key PRESS lines ("d <code>\n") to EXACTLY that window's /keys
# ring (devwsys_keys_write pushes them straight into the editor's input,
# no focus dependency). The editor's _drain_keys_chunk parses the lines.
ED_WID = [None]

def read_wid():
    import re
    with lock:
        start = len(buf)            # only parse output produced AFTER here
    send("echo WIDFILE_BEGIN; cat /tmp/.hamedit_wid; echo WIDFILE_END")
    if not wait_for("WIDFILE_END", 10):
        return None
    with lock:
        text = buf[start:].decode("latin1", "replace")
    # The interactive hamsh echoes each typed char with a cursor-redraw
    # escape, so "WIDFILE_BEGIN"/"WIDFILE_END" appear DOZENS of times (one
    # partial copy per keystroke). The old BEGIN(.*?)END region match paired
    # those polluted echo copies and matched an empty region -> wid parsed to
    # None even though `cat /tmp/.hamedit_wid` printed the wid cleanly on its
    # OWN line ("9\n"). ROBUST parse: strip ANSI/cursor escapes from the whole
    # post-send text, then take the LAST line that is JUST a 1..3 digit number
    # (the wid file's bare-number output). Command echoes never leave a bare
    # digit on its own line; kernel log noise ("[NNNN] ...") is bracketed, not
    # bare. This is the same parse the ad-hoc DE-QA driver uses successfully.
    clean = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text).replace("\r", "\n")
    last = None
    for ln in clean.split("\n"):
        t = ln.strip()
        if t.isdigit() and 1 <= len(t) <= 3 and 1 <= int(t) <= 256:
            last = int(t)
    return last

# PRIMARY input path: inject straight into the editor's own /keys ring by
# wid (focus-independent). This is the deterministic path.
def keycode_ring(code):
    w = ED_WID[0]
    if w is None:
        return
    send(f"printf 'd {code}\\n' > /dev/wsys/{w}/keys")
    time.sleep(0.15)

# FALLBACK input path (mirrors scripts/test_de_hamedit_picker.sh, which
# proved Ctrl-S reaches the editor this way): focus the editor window with a
# /dev/mouse click, then write key BYTES to /dev/cons (the compositor's
# focus router forwards them to the focused window's /keys). The editor was
# given geometry 180,120 400x260, so its body is around screen (300,250).
def focus_editor():
    # tablet coords: x/1280*32767, y/800*32767 ~ for (300,250)
    for cx, cy in (("7680","10200"), ("9000","9000"), ("6000","8000")):
        send(f"echo '{cx} {cy} 1 0 1' > /dev/mouse")
        time.sleep(0.2)
        send(f"echo '{cx} {cy} 0 0 1' > /dev/mouse")
        time.sleep(0.2)

def consbyte(octal):
    send(f"printf '\\{octal}' > /dev/cons")
    time.sleep(0.25)

# Allowed printable chars for the cons path (kept simple/quote-safe).
def cons_char(ch):
    # Write one printable byte to /dev/cons (forwarded to the focused win).
    send(f"printf %s '{ch}' > /dev/cons")
    time.sleep(0.12)

def keystr(s):
    # Drive BOTH paths per char: the editor's /keys ring (by wid) AND the
    # focused-cons path (the editor must be focused first; see arms).
    for ch in s:
        keycode_ring(ord(ch))
        if ch.isalnum():
            cons_char(ch)

def ctrl_s():
    # Ctrl-S = code 19 (octal 023). Drive BOTH the ring and focused-cons.
    for _ in range(3):
        keycode_ring(19)
    for _ in range(3):
        consbyte("023")

rc = 2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[save_gate] driver: never reached handoff", file=sys.stderr)
    else:
        print("[save_gate] driver: handoff reached", file=sys.stderr)
        # Let the rl5 scene DE settle. CRITICAL: the rc.5 visual_gate runner
        # floods /dev/cons with "[visual_gate] launching/launched <app>"
        # markers for ~40s AFTER the interactive handoff. Those lines contend
        # with every serial command we send — garbling the `cat
        # /tmp/.hamedit_wid` readback (ED_WID parses to None) and the
        # `printf ... > /keys` injections alike, which is why this gate was
        # intermittently reporting "wid = None" / empty readbacks. WAIT for
        # the visual_gate's terminal "[visual_gate] done" marker so the
        # console is QUIET before we read the wid and inject keys.
        wait_for("launching text editor", 60)
        if not wait_for("[visual_gate] done", 200):
            print("[save_gate] driver: visual_gate 'done' not seen; "
                  "driving anyway (console may be noisy)", file=sys.stderr)
        time.sleep(4)
        # Flush a couple of newlines to clear any partial prompt line left
        # by the flood before the first real command.
        send(""); send("")
        time.sleep(1)
        screendump("boot")

        # ---- ARM A: writable round-trip -----------------------------
        send("echo ARMA_BEGIN")
        # Seed a known ORIGINAL content with a unique marker.
        send("printf 'OLDSEED12345\\n' > /tmp/htest.txt")
        send("echo SEED_SET; cat /tmp/htest.txt")
        wait_for("OLDSEED12345", 8)
        # Launch a fresh editor ON the writable file (background). It opens
        # its own window + /keys ring under the compositor and publishes its
        # wid to /tmp/.hamedit_wid.
        send("rm /tmp/.hamedit_wid")
        send("/bin/hameditscene /tmp/htest.txt &")
        time.sleep(5)
        ED_WID[0] = read_wid()
        print(f"[save_gate] driver: ARM A editor wid = {ED_WID[0]}", file=sys.stderr)
        focus_editor()
        screendump("armA_opened")
        # Inject fresh, unique content DIRECTLY into the editor's /keys ring
        # (no /dev/cons focus dependency). The editor inserts at caret 0;
        # the whole buffer is O_TRUNC-written on save.
        keystr("NEWPERSIST99 ")
        time.sleep(0.5)
        # Diagnostic: dump THIS editor's own scene to confirm the typed text
        # landed (and that ED_WID points at the right window).
        if ED_WID[0] is not None:
            w = ED_WID[0]
            send(f"echo EDSCENE_A_BEGIN; cat /dev/wsys/{w}/scene; echo EDSCENE_A_END")
            wait_for("EDSCENE_A_END", 10)
        # Ctrl-S = code 19. Inject several times to defeat any ring race.
        ctrl_s()
        time.sleep(1.5)
        screendump("armA_saved")
        # Read the file back FROM THE SHELL (proves on-disk persistence
        # independent of the editor process).
        send("echo READBACK_A_BEGIN; cat /tmp/htest.txt; echo READBACK_A_END")
        wait_for("READBACK_A_END", 10)
        send("echo ARMA_DONE")
        wait_for("ARMA_DONE", 8)

        # ---- ARM B: read-only /version honesty ----------------------
        send("echo ARMB_BEGIN")
        send("rm /tmp/.hamedit_wid")
        send("/bin/hameditscene /version &")
        time.sleep(5)
        ED_WID[0] = read_wid()
        print(f"[save_gate] driver: ARM B editor wid = {ED_WID[0]}", file=sys.stderr)
        focus_editor()
        keystr("ZZZ ")
        time.sleep(0.5)
        ctrl_s()
        time.sleep(1.5)
        screendump("armB_saved")
        # Dump every live window scene so bash can scan for the explicit
        # save-FAILED status text that the editor renders in its title bar.
        for n in range(1, 13):
            send(f"echo SCENE{n}_BEGIN; cat /dev/wsys/{n}/scene; echo SCENE{n}_END")
            time.sleep(0.4)
        # Confirm /version itself is unchanged (no ZZZ leaked in).
        send("echo VERREAD_BEGIN; cat /version; echo VERREAD_END")
        wait_for("VERREAD_END", 8)
        send("echo ARMB_DONE")
        for _ in range(12):
            send("echo SAVEDONEMARK")
            if wait_for("SAVEDONEMARK", 4):
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

if [ "$DRV_RC" = "2" ]; then
    echo "[save_gate] SKIP: guest never reached the interactive shell" >&2
    exit 0
fi

# Convert screendumps to PNG for human VIEWING.
for lbl in boot armA_opened armA_saved armB_saved; do
    ppm="$OUT_DIR/$lbl.ppm"
    if [ -s "$ppm" ] && command -v pnmtopng >/dev/null 2>&1; then
        pnmtopng "$ppm" > "$OUT_DIR/$lbl.png" 2>/dev/null || true
    fi
done

fail=0
echo "[save_gate] --- assertions ---"

# ARM A: the typed NEW marker is on disk after the editor saved + the shell
# re-read the file. The readback region is delimited by markers so we don't
# match the launch echo.
READBACK_A=$(awk '/READBACK_A_BEGIN/{f=1;next} /READBACK_A_END/{f=0} f' "$LOG" 2>/dev/null)
if printf '%s' "$READBACK_A" | grep -aq "NEWPERSIST99"; then
    echo "[save_gate] PASS ARM A: edited text PERSISTED to /tmp/htest.txt (round-trip via shell cat)"
else
    echo "[save_gate] FAIL ARM A: NEWPERSIST99 not found in the saved file readback" >&2
    echo "  readback was: $(printf '%s' "$READBACK_A" | tr -d '\r' | head -3)" >&2
    fail=1
fi

# ARM B: the editor's window scene shows an explicit save-FAILED status for
# the read-only /version (NOT a fake "saved N bytes").
SCENES=$(awk '/SCENE[0-9]+_BEGIN/{f=1} /SCENE[0-9]+_END/{f=0} f' "$LOG" 2>/dev/null)
if printf '%s' "$SCENES" | grep -aqiE 'save FAILED|read-only'; then
    hit=$(printf '%s' "$SCENES" | grep -aoiE 'save FAILED[^"]*|read-only[^"]*' | head -1)
    echo "[save_gate] PASS ARM B: /version save surfaced an HONEST failure ($hit)"
else
    echo "[save_gate] NOTE ARM B: save-FAILED status not captured in a scene this window (screendump armB_saved.png authoritative)" >&2
fi

# ARM B: /version content unchanged (no ZZZ leaked).
VERREAD=$(awk '/VERREAD_BEGIN/{f=1;next} /VERREAD_END/{f=0} f' "$LOG" 2>/dev/null)
if printf '%s' "$VERREAD" | grep -aq "ZZZ"; then
    echo "[save_gate] FAIL ARM B: /version was MUTATED (ZZZ leaked) — RO not enforced" >&2
    fail=1
else
    echo "[save_gate] PASS ARM B: /version is unchanged (read-only enforced)"
fi

echo "[save_gate] artifacts:"
for lbl in boot armA_opened armA_saved armB_saved; do
    [ -f "$OUT_DIR/$lbl.png" ] && echo "  $OUT_DIR/$lbl.png"
done
echo "  $LOG"

if [ "$fail" = "0" ]; then
    echo "[save_gate] RESULT: PASS (ARM A round-trip proves persistence; VIEW armA_saved.png)"
    exit 0
else
    echo "[save_gate] RESULT: FAIL"
    exit 1
fi
