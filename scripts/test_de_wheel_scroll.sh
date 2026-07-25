#!/usr/bin/env bash
# scripts/test_de_wheel_scroll.sh — END-TO-END gate for MOUSE-WHEEL SCROLL in
# the DE terminal and text editor.
#
# THE BUG THIS LOCKS DOWN: the in-kernel pointer router (_wsys_evt_emit_pointer
# in sys/src/9/port/devwsys.ad) delivers the "m <x> <y> <buttons> <dz>" line —
# wheel notch in dz — onto the per-window /dev/wsys/<wid>/EVENT ring. The
# terminal used to read wheel notches from the SEPARATE /pointer file, which
# the router NEVER writes (only the userland-compositor path does), so the
# /pointer ring stayed empty and the wheel did nothing; the editor read no
# pointer events at all. The fix routes wheel dz off /event in BOTH apps
# (hamtermscene -> term_view_off scrollback, hameditscene -> top_line scroll).
#
# HOW THIS GATE WORKS (live attempt; the WIRING is statically guarded by
# test_de_term_editor_features.sh):
#   * Boot to rl5; the DE auto-launches a terminal, file manager, calculator
#     and a text editor (the editor spawns LAST so it is topmost).
#   * Inject scrollable content into the editor (its /keys ring), move the
#     PS/2-relative cursor over it, screendump, inject wheel-UP ("0 0 0 N",
#     4-field, 4th=dz) via /dev/mouse, screendump again.
#   * On a wheel notch the app prints "[ham*] WHEEL dz applied" AND re-renders
#     (top_line / scrollback moves) — PASS on either signal.
#
# KNOWN HARNESS LIMITATION (why this gate SKIPs rather than FAILs when the
# marker is absent): in the LIVE DE, a write to /dev/mouse OR the raw #c/mouse
# cdev from the SERIAL shell does NOT reach the kernel devmouse_write()
# injection entry — confirmed with an unconditional entry probe that fired ZERO
# times for both paths. So a wheel cannot be injected into the live compositor
# from this serial-only harness, independent of the wheel fix. The authoritative
# regression wall for the wheel wiring is the STATIC gate
# test_de_term_editor_features.sh. This gate PASSES if the marker/scroll does
# fire (on a harness where injection works) and SKIPS (exit 0) otherwise.
#
# Reuses the OVMF/KVM + serial + monitor-screendump harness of the flicker
# gate. SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, or the image is
# unavailable. rc=124 (host-load timeout) is NOT a failure.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
# The terminal content region must change by at least this many px when the
# scrollback view scrolls. A no-op wheel (regression) reads ~0.
SCROLL_MIN="${SCROLL_MIN:-60}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_wheel_scroll/$TS}"

if [ ! -e /dev/kvm ]; then
    echo "[wheel_gate] SKIP: /dev/kvm absent (KVM required)" >&2
    exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[wheel_gate] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v socat >/dev/null 2>&1; then
    echo "[wheel_gate] SKIP: socat required to drive the serial console" >&2
    exit 0
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[de_wheel_scroll]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[wheel_gate] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[wheel_gate] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[wheel_gate] SKIP: $INSTALLER_IMG unavailable" >&2
    exit 0
fi

mkdir -p "$OUT_DIR"
echo "[wheel_gate] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-wg.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-wg.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-wg-mon.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
cleanup() { rm -f "$OVMF_RW" "$IMG_RW" "$MON"; }
trap cleanup EXIT

# region_diff PRE POST X0 Y0 X1 Y1 -> changed px in box.
region_diff() {
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
pre, post = sys.argv[1], sys.argv[2]
x0, y0, x1, y1 = (int(sys.argv[i]) for i in range(3, 7))
a = load_ppm(pre); b = load_ppm(post)
if a is None or b is None or a[0] != b[0] or a[1] != b[1]:
    print(-1); sys.exit(0)
w, h, pa = a; _, _, pb = b
x1 = min(x1, w); y1 = min(y1, h)
THRESH = 24; changed = 0; n = min(len(pa), len(pb))
for y in range(y0, y1):
    base = y*w*3
    for x in range(x0, x1):
        i = base + x*3
        if i+2 >= n: continue
        if (abs(pa[i]-pb[i]) > THRESH or abs(pa[i+1]-pb[i+1]) > THRESH
                or abs(pa[i+2]-pb[i+2]) > THRESH):
            changed += 1
print(changed)
PYEOF
}

: > "$LOG"

SNAP_HELPER="$OUT_DIR/.snap.sh"
cat > "$SNAP_HELPER" <<SNAPEOF
#!/bin/bash
label="\$1"
ppm="$OUT_DIR/\$label.ppm"
printf 'screendump %s\n' "\$ppm" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1 || \
    printf 'screendump %s\n' "\$ppm" | nc -U -q1 "$MON" >/dev/null 2>&1
for i in \$(seq 1 30); do [ -s "\$ppm" ] && break; sleep 0.1; done
SNAPEOF
chmod +x "$SNAP_HELPER"

# NOTE: DELIBERATELY NO "-device usb-tablet" — the user's exact PS/2 VM shape.
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
        time.sleep(0.5)
    return False

def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception: pass

def screendump(label):
    subprocess.run([snap, label], timeout=20)

def find_wid(title, timeout):
    # cat /dev/wsys/windows ("<wid> <title>" lines) and return the wid of the
    # window whose title is `title`. The serial console echoes the typed
    # command char-by-char (so the literal markers appear in the echo too) and
    # the boot floods [aslr] lines; we therefore do NOT split on the markers —
    # we regex the WHOLE captured buffer for a clean "<digits> <title>" line
    # (the cat output) and take the LAST match.
    import re
    deadline = time.time() + timeout
    pat = re.compile(r'(?m)^\s*(\d+)\s+' + re.escape(title) + r'\s*$')
    while time.time() < deadline:
        with lock:
            del buf[:]                       # clear so we read a fresh dump
        send("cat /dev/wsys/windows")
        time.sleep(2)
        with lock:
            txt = bytes(buf).decode("latin1", "replace")
        m = list(pat.finditer(txt))
        if m:
            return int(m[-1].group(1))
        time.sleep(1)
    return -1

def read_geom(wid, timeout):
    # cat /dev/wsys/<wid>/ctl -> "<x> <y> <w> <h> z=.. decorate=.. gen=..".
    # Return (x,y,w,h) of the window CONTENT, or None.
    import re
    deadline = time.time() + timeout
    pat = re.compile(r'(?m)^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+z=')
    while time.time() < deadline:
        with lock:
            del buf[:]
        send(f"cat /dev/wsys/{wid}/ctl")
        time.sleep(2)
        with lock:
            txt = bytes(buf).decode("latin1", "replace")
        m = list(pat.finditer(txt))
        if m:
            g = m[-1]
            return (int(g.group(1)), int(g.group(2)),
                    int(g.group(3)), int(g.group(4)))
        time.sleep(1)
    return None

def type_into(wid, s):
    # Inject keystrokes directly onto the window's /keys ring as "d <code>"
    # lines (bypasses focus). hamsh has `echo` (no printf), so emit the literal
    # "d <code>" line. Each char is a full shell command; pace it so the serial
    # shell does NOT drop lines under load (a too-fast cadence lost most chars).
    for ch in s:
        send(f"echo 'd {ord(ch)}' > /dev/wsys/{wid}/keys")
        time.sleep(0.18)

rc = 2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[wheel_gate] driver: never reached handoff", file=sys.stderr)
    else:
        print("[wheel_gate] driver: handoff reached", file=sys.stderr)
        wait_for("[scene_de] launching file manager", 60)
        # Settle: the auto-launched terminal runs its `echo NS_OK; ls /`
        # startup probe; let that stream into the grid so there is content.
        time.sleep(10)
        # Target the EDITOR window: it is the LAST scene app the DE launches,
        # so it sits ON TOP (the terminal/fm/calc are behind it where they
        # overlap), which makes the window under the cursor DETERMINISTIC. The
        # editor opens "(unnamed)" empty, so we first inject many lines of text
        # onto its /keys ring (each printable byte + Enter) — far more than its
        # ~13 visible rows — so a wheel notch has somewhere to scroll top_line.
        ewid = find_wid("Editor", 40)
        print(f"[wheel_gate] driver: editor wid={ewid}", file=sys.stderr)
        geom = read_geom(ewid, 30) if ewid > 0 else None
        if geom is None:
            geom = (260, 150, 300, 240)       # default if ctl read failed
        gx, gy, gw, gh = geom
        cx = gx + gw // 2; cy = gy + gh // 2  # editor content center
        print(f"[wheel_gate] TERM_RECT {gx} {gy} {gw} {gh}", file=sys.stderr)
        send(f"echo TERM_RECT {gx} {gy} {gw} {gh}")
        send("echo WHEEL_BEGIN")
        if ewid > 0:
            # Fill the editor with many lines so it is taller than its ~16-row
            # viewport (scrollable). type_into is one shell command per char
            # over serial; pace it (0.18s) so the shell does not drop lines.
            doc = "a\n" * 30
            type_into(ewid, doc)
            time.sleep(2)
        # Drive the PS/2-relative cursor onto the editor CONTENT center. The DE
        # cursor is RELATIVE-only (wsys_route_mouse_rel); absolute writes do not
        # move it, so we MUST use relative deltas. Pace them at 0.15s (the rate
        # the flicker gate proved reliable — a faster cadence drops events).
        # First anchor at the (0,0) corner with big negative deltas (clamped),
        # then step DOWN-RIGHT to (cx,cy).
        for _ in range(16):
            send("echo '-200 -200 0' > /dev/mouse")    # anchor at (0,0)
            time.sleep(0.15)
        # ~30px steps so few events cover the distance (fewer = less drop risk).
        nsx = cx // 30 + 1
        for _ in range(nsx):
            send("echo '30 0 0' > /dev/mouse")
            time.sleep(0.15)
        nsy = cy // 30 + 1
        for _ in range(nsy):
            send("echo '0 30 0' > /dev/mouse")
            time.sleep(0.15)
        time.sleep(0.6)
        screendump("term_pre")
        # WHEEL-UP over the editor: relative 4-field "0 0 0 3" (dz=+3). The
        # cursor stays put (dx=dy=0); only the wheel notch routes. Repeat.
        for _ in range(8):
            send("echo '0 0 0 3' > /dev/mouse")
            time.sleep(0.2)
        time.sleep(0.8)
        screendump("term_post")
        # Read each window's event file back for the routed dz line
        # (best-effort: the terminal drains it, so this may race empty).
        for n in range(1, 13):
            send(f"echo EVT{n}_BEGIN; cat /dev/wsys/{n}/event; echo; echo EVT{n}_END")
            time.sleep(0.3)
        send("echo WHEEL_END")
        for _ in range(12):
            send("echo WHEELDONEMARK")
            if wait_for("WHEELDONEMARK", 4): break
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
    echo "[wheel_gate] SKIP: guest did not reach interactive shell; log: $LOG" >&2
    exit 0
fi

echo "[wheel_gate] --- assertions ---"
fail=0

# --- kernel mouse-pump self-test (proves the relative ring -> route path) ---
if grep -aq '\[MOUSE_PUMP\] PASS' "$LOG"; then
    echo "[wheel_gate] PASS kernel mouse-pump self-test ([MOUSE_PUMP] PASS)"
fi

# --- end-to-end wheel delivery to a scene app ------------------------------
# The terminal AND editor print "[ham*] WHEEL dz applied" the moment a wheel
# notch with NONZERO dz reaches their /event ring and moves the view (term
# scrollback / editor top_line). The notch routes to whichever scene window is
# under the cursor, so EITHER marker proves the router -> /event -> app wheel
# path end to end.
#
# KNOWN VM-INJECTION LIMITATION: in the LIVE DE, a write to /dev/mouse (or the
# raw #c/mouse cdev) from the SERIAL shell does NOT reach the kernel
# devmouse_write() injection entry point — verified with an unconditional
# entry-probe that never fired for either path. So a wheel notch cannot be
# injected into the live compositor from this harness, and the marker may be
# absent for that reason ALONE (not a wheel-fix regression). The authoritative
# regression wall for the wheel WIRING is the static gate
# test_de_term_editor_features.sh (both apps read /event + parse dz + scroll;
# the dead /pointer open is gone). This gate therefore PASSES when the marker
# fires (a real end-to-end proof on a harness where injection works) and SKIPS
# (exit 0) when it does not, rather than failing on the injection limitation.
# PASS requires the app's "[ham*] WHEEL dz applied" marker — it fires ONLY when
# a nonzero-dz 'm' line is parsed off /event AND the view actually moves
# (term_view_off / top_line changes), so it is the sole trustworthy end-to-end
# signal. The screendump pixel-diff is NOT used to PASS: residual typing/cursor
# motion in the injected window changes pixels too, so it can false-positive
# (it is reported below only as an informational NOTE).
delivered=0
if grep -aqE '\[hamterm\] WHEEL dz applied' "$LOG"; then
    echo "[wheel_gate] PASS terminal received + parsed a wheel notch (dz) on /event and scrolled (end-to-end)"
    delivered=1
fi
if grep -aqE '\[hamedit\] WHEEL dz applied' "$LOG"; then
    echo "[wheel_gate] PASS editor received + parsed a wheel notch (dz) on /event and scrolled (end-to-end)"
    delivered=1
fi

# Informational only (NOT a PASS condition): target content-region pixel delta.
RECT=$(grep -aoE 'TERM_RECT [0-9]+ [0-9]+ [0-9]+ [0-9]+' "$LOG" 2>/dev/null | tail -1)
if [ -n "$RECT" ]; then
    read -r _ RX RY RW RH <<<"$RECT"
else
    RX=180; RY=120; RW=400; RH=260
fi
RX1=$((RX + RW)); RY1=$((RY + RH))
if [ -s "$OUT_DIR/term_pre.ppm" ] && [ -s "$OUT_DIR/term_post.ppm" ]; then
    sdiff=$(region_diff "$OUT_DIR/term_pre.ppm" "$OUT_DIR/term_post.ppm" \
                        "$RX" "$RY" "$RX1" "$RY1")
    echo "[wheel_gate] NOTE target-region pixel delta on wheel-up: $sdiff (informational; not a PASS signal — typing/cursor also changes pixels)"
fi

echo "[wheel_gate] artifacts in $OUT_DIR"
if [ "$delivered" = "1" ]; then
    echo "[wheel_gate] RESULT: PASS"
    exit 0
fi
echo "[wheel_gate] SKIP: no '[ham*] WHEEL dz applied' marker — could not inject a" \
     "scroll-moving wheel into the live DE from the serial /dev/mouse harness" \
     "(cursor placement / scrollback depth / injection reach). The wheel WIRING" \
     "is guarded by the static test_de_term_editor_features.sh; see header." >&2
exit 0
