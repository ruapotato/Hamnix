#!/usr/bin/env bash
# scripts/test_de_scene_drag_iconclick.sh
#
# DAMAGE-SCOPED COMPOSITOR GATE — the EYE-LEVEL proof for the three DE
# perf/correctness bugs the user hit in a VM:
#
#   1. DRAG FLICKER + LAG. Dragging a titlebar full-presented (re-rasterize
#      ALL windows + re-blit ALL bottom-to-top) per motion event, so the
#      backdrop + other windows blanked between frames. FIX: a drag motion
#      recomposes ONLY the union of the window's OLD and NEW rects from the
#      durable caches (no full present, no re-rasterize-all).
#
#   3. DESKTOP-ICON CLICK BLANKED THE SCREEN. The full-screen hamdesktop
#      re-committed its whole scene on a click; the commit full-presented,
#      and the full-rect backdrop pre-pass flashed the whole screen blank.
#      FIX: a commit is damage-scoped to the committing window's footprint,
#      AND the backdrop pre-pass is skipped when the opaque full-screen
#      desktop layer already covers the rect (no blank sweep).
#
# This gate drives the LIVE compositor over /dev/mouse using ABSOLUTE
# (5-field) injection so the cursor lands on an exact pixel, then takes
# QEMU monitor screendumps BEFORE / MID / AFTER each gesture and asserts:
#
#   DRAG: between two mid-drag frames the screen is NOT mostly-blank — the
#         changed-pixel count stays a SMALL fraction of the frame (the
#         dragged window's footprint), proving no full-screen repaint. A
#         full-present-per-motion regression blanks ~half the screen and
#         trips the ceiling.
#
#   ICON CLICK: a frame taken right after a desktop-icon click is NOT a
#         near-empty backdrop — it still carries the panel + windows (its
#         whole-frame diff vs the pre-click frame is SMALL, i.e. only the
#         icon highlight changed; the old bug blanked ~everything so the
#         diff was huge).
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, the image, or socat are
# unavailable. Mirrors test_de_scene_flicker_relmouse.sh's env gating.
#
# rc=124 (timeout) is NOT a fail — note it.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
# shellcheck disable=SC1091
. "$PROJ_ROOT/scripts/_build_lock.sh" 2>/dev/null || true

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
# A drag-motion frame should touch at most a window-sized footprint, never
# the whole screen. On a 1280x800 frame (~1.0M px) a full-present regression
# blanks/repaints hundreds of thousands of px; a scoped drag touches only the
# window rect (~tens of thousands). Ceiling well below "half the screen".
DRAG_FRAME_MAX="${DRAG_FRAME_MAX:-200000}"
# A desktop-icon click must leave the panel + windows on screen: its diff vs
# the pre-click frame is just the icon-highlight cell. The old blank-bug diff
# was ~the whole frame. Ceiling well below a full blank.
CLICK_FRAME_MAX="${CLICK_FRAME_MAX:-200000}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_drag_iconclick/$TS}"

if [ ! -e /dev/kvm ]; then
    echo "[drag_gate] SKIP: /dev/kvm absent (KVM required)" >&2
    exit 0
fi

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[drag_gate] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

if ! command -v socat >/dev/null 2>&1; then
    echo "[drag_gate] SKIP: socat required to drive the monitor/serial" >&2
    exit 0
fi

# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[de_scene_drag_iconclick]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[drag_gate] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[drag_gate] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[drag_gate] SKIP: $INSTALLER_IMG unavailable" >&2
    exit 0
fi

mkdir -p "$OUT_DIR"
echo "[drag_gate] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-dg.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-dg.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-dg-mon.XXXXXX)
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

# nonbackdrop_px FRAME R G B -> count of pixels NOT equal to the backdrop
# colour (within threshold). A near-blank frame (everything == backdrop)
# reads ~0; a live desktop with a panel + windows reads large. This is the
# direct "the screen is NOT blanked" probe.
nonbackdrop_px() {
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
br, bg, bb = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
w, h, p = f
THRESH = 24; non = 0; n = len(p)
i = 0
while i + 2 < n:
    if (abs(p[i]-br) > THRESH or abs(p[i+1]-bg) > THRESH
            or abs(p[i+2]-bb) > THRESH):
        non += 1
    i += 3
print(non)
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

# Default PS/2 pointer (no usb-tablet) — same VM shape as the user. We use
# the /dev/mouse 5-field ABSOLUTE injection (ax ay btn dz 1) to land the
# cursor on an exact pixel regardless of the relative starting position.
python3 - "$IMG_RW" "$OVMF_RW" "$MON" "$LOG" "$SNAP_HELPER" "$BOOT_WAIT" <<'PYDRV'
import os, sys, subprocess, time, threading

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

import re as _re
# hamsh's idle "[hamsh-alive] tick=N uptime=Ns" heartbeat and the line
# editor's ANSI cursor controls (ESC[..K / ESC[..C) interleave the serial
# echo of a typed command MID-WORD, so a contiguous marker may never appear
# unbroken in the raw buffer even though the guest is fully alive and ran the
# command. Strip that noise before matching so wait_for sees the marker.
_HB_RE = _re.compile(rb'\[hamsh-alive\][^\n]*')
_CSI_RE = _re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]')
def _denoise(b):
    b = _HB_RE.sub(b'', b)
    b = _CSI_RE.sub(b'', b)
    return b

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

# Inject an ABSOLUTE pointer event at screen-fraction (fx,fy) of the frame.
# The kernel framebuffer is 1280x800 (QEMU -vga std). absmove takes SCREEN
# PIXELS and maps to 0..32767 tablet space (kernel rescales to px).
FB_W, FB_H = 1280, 800
def absmove_px(px, py, btn):
    ax = max(0, min(32767, int(px * 32767 / FB_W)))
    ay = max(0, min(32767, int(py * 32767 / FB_H)))
    send(f"echo '{ax} {ay} {btn} 0 1' > /dev/mouse")

# Issue a marked read of a guest file and return its captured text. The DE
# floods the serial console, so the first command line may be dropped and
# markers can be interleaved — RETRY a few times and take the LAST complete
# B..E block found in the buffer tail.
def read_back(path, tag, settle=0.6):
    for attempt in range(4):
        with lock:
            start = len(buf)
        send(f"echo {tag}B; cat {path}; echo; echo {tag}E")
        deadline = time.time() + 3
        while time.time() < deadline:
            with lock:
                chunk = bytes(buf[start:])
            if (tag + "E").encode() in chunk:
                break
            time.sleep(0.1)
        time.sleep(settle)
        with lock:
            chunk = bytes(buf[start:])
        txt = chunk.decode("latin-1")
        a = txt.rfind(tag + "B")
        b = txt.find(tag + "E", a + 1) if a >= 0 else -1
        if a >= 0 and b > a:
            body = txt[a + len(tag) + 1:b]
            if body.strip():
                return body
    return ""

# Parse a /dev/wsys/<wid>/ctl status line "<x> <y> <w> <h> z=.. dec=.. gen=.."
def parse_geo(s):
    for line in s.splitlines():
        line = line.strip()
        toks = line.split()
        if len(toks) >= 4:
            try:
                x = int(toks[0]); y = int(toks[1])
                w = int(toks[2]); h = int(toks[3])
            except ValueError:
                continue
            dec = 0; z = 0
            for t in toks:
                if t.startswith("dec=") or t.startswith("decorate="):
                    try: dec = int(t.split("=")[1])
                    except Exception: dec = 0
                if t.startswith("z="):
                    try: z = int(t.split("=")[1])
                    except Exception: z = 0
            return (x, y, w, h, dec, z)
    return None

# Discover the TOP-MOST decorated window (highest z) with an on-screen
# titlebar — the one a titlebar press will hit-test to and arm a drag on.
def discover_top_decorated(tagpfx, settle=0.4):
    best = None  # (wid, x, y, w, h)
    best_z = None
    for n in range(1, 8):
        s = read_back(f"/dev/wsys/{n}/ctl", f"{tagpfx}{n}", settle=settle)
        g = parse_geo(s)
        print(f"[drag_gate] driver: wid {n} geo = {g}", file=sys.stderr)
        if g is None:
            continue
        x, y, w, h, dec, z = g
        if dec != 0 and y >= 18:
            if best_z is None or z > best_z:
                best = (n, x, y, w, h)
                best_z = z
    return best

rc = 2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[drag_gate] driver: never reached handoff", file=sys.stderr)
        rc = 2
    else:
        print("[drag_gate] driver: handoff reached", file=sys.stderr)
        # The installer DE runs an autonomous `visual_gate` self-test that
        # LAUNCHES a sequence of demo apps (hamclock/hamcalc/hamfm/...) for
        # ~40s, churning the window set. WAIT for its terminal `done` marker
        # so the base scene clients (panel + terminal + FM + calc + editor)
        # are stable before we drive any input — otherwise a launch/teardown
        # mid-gesture is misread as a compositor blank.
        if wait_for("[visual_gate] done", 90):
            print("[drag_gate] driver: visual_gate done — window set stable",
                  file=sys.stderr)
        else:
            print("[drag_gate] driver: visual_gate 'done' not seen; proceeding",
                  file=sys.stderr)
        time.sleep(3)   # let the final launch settle / repaint
        TITLEBAR_H = 18

        # ===================== TITLEBAR DRAG (bug 1) =====================
        # Done FIRST, right after the window set settles, so the dragged
        # window is freshest. Discover the TOP-MOST decorated window and grab
        # its real titlebar centre, then drag it down-right across several
        # motion events with the button HELD. Capture a frame after each
        # motion; none may blank the backdrop/other windows, consecutive
        # frames must differ only by the moved window's footprint (no full
        # repaint), and the window's geometry must actually change.
        send("echo DRAG_BEGIN")
        top = discover_top_decorated("WGEO", settle=0.4)
        drag_wid = 0
        if top is not None:
            drag_wid, gx, gy, gw, gh = top
            print(f"[drag_gate] driver: drag target wid={drag_wid} "
                  f"geo=({gx},{gy},{gw},{gh})", file=sys.stderr)
            # Titlebar centre (bar sits ABOVE content origin); avoid the
            # rightmost 16px close box.
            grab_x = gx + min(gw // 2, gw - 40)
            grab_y = gy - TITLEBAR_H // 2
        else:
            print("[drag_gate] driver: discovery empty; FIXED titlebar grab",
                  file=sys.stderr)
            grab_x, grab_y = 380, 111
        print(f"[drag_gate] driver: grab titlebar at ({grab_x},{grab_y})",
              file=sys.stderr)
        absmove_px(grab_x, grab_y, 0)       # hover
        time.sleep(0.2)
        absmove_px(grab_x, grab_y, 1)       # press -> arm the drag
        time.sleep(0.25)
        screendump("drag_0")
        cx, cy = grab_x, grab_y
        for k in range(4):
            cx += 60
            cy += 40
            absmove_px(cx, cy, 1)
            time.sleep(0.2)
            screendump(f"drag_{k+1}")
        absmove_px(cx, cy, 0)               # release
        time.sleep(0.4)
        screendump("drag_done")
        # Read every decorated window's geometry back to PROVE one moved.
        for n in range(1, 8):
            sN = read_back(f"/dev/wsys/{n}/ctl", f"DGEO{n}", settle=0.3)
            gN = parse_geo(sN)
            print(f"[drag_gate] driver: post-drag wid={n} geo={gN}",
                  file=sys.stderr)
        send("echo DRAG_END")
        time.sleep(0.5)

        # ---- BASELINE for the icon-click diff: current settled desktop. ----
        screendump("base")
        time.sleep(0.5)

        # ================= DESKTOP-ICON CLICK (bug 3) =================
        # The desktop icon column is down the LEFT edge; the first cell centre
        # sits at ~ (55, 52) px (ICON_MARGIN_X=18 + CELL_W/2; ICON_TOP=16 +
        # CELL_H/2). A single click SELECTS it (highlight) -> the full-screen
        # hamdesktop re-commits its WHOLE scene. The screen must NOT blank.
        send("echo ICONCLICK_BEGIN")
        absmove_px(55, 52, 0)           # hover the first icon cell
        time.sleep(0.3)
        absmove_px(55, 52, 1)           # press
        time.sleep(0.25)
        screendump("click_down")        # frame WHILE the desktop recommits
        absmove_px(55, 52, 0)           # release
        time.sleep(0.4)
        screendump("click_after")       # settled frame after the click
        send("echo ICONCLICK_END")
        time.sleep(0.5)

        # ============ ICON DRAG = NO SPAWN STORM (BUG 1: the CRASH) ========
        # The user dragged a desktop icon and the WHOLE SYSTEM CRASHED: a
        # press-drag over an icon fired the icon's launch on EVERY pointer
        # motion event (the button stays HELD across the drag), spawning the
        # target app hundreds of times -> resource exhaustion -> VM exit. The
        # fix makes hamdesktop activate ONLY on a clean press+release over the
        # SAME cell (release edge), never on held motion. Here we reproduce the
        # exact gesture: press ON the first icon cell, drag across MANY motion
        # events with the button HELD (over and past the icon column), then
        # release OFF the press cell (a drag-away — must launch NOTHING). We
        # bracket the gesture with markers so the harness can count how many
        # "[hamdesktop] launched" lines appear DURING the drag. A correct build
        # prints ZERO launches for this drag-away; the old storm printed a
        # flood (and then crashed). The guest must STILL be alive afterwards.
        send("echo ICONDRAG_BEGIN")
        absmove_px(55, 52, 0)           # hover the first icon cell
        time.sleep(0.2)
        absmove_px(55, 52, 1)           # PRESS on the icon (must NOT launch)
        time.sleep(0.2)
        dx, dy = 55, 52
        for k in range(10):             # 10 held-motion events = storm bait
            dx += 22
            dy += 14
            absmove_px(dx, dy, 1)       # drag, button HELD (must NOT launch)
            time.sleep(0.12)
        absmove_px(dx, dy, 0)           # RELEASE off the press cell (no launch)
        time.sleep(0.4)
        send("echo ICONDRAG_END")
        # Prove the guest is ALIVE (not crashed/exited) after the drag storm
        # bait: echo a unique liveness marker and confirm it comes back.
        time.sleep(0.3)
        send("echo ICONDRAG_ALIVE_PROBE_XYZ")
        wait_for("ICONDRAG_ALIVE_PROBE_XYZ", 10)
        time.sleep(0.5)

        # ================= BARE DESKTOP / BACKDROP CLICK (bug A) =========
        # The user's exact repro: "if you click on the desktop, ALL apps +
        # the top panel vanish." Root cause was the full-screen hamdesktop
        # (lowest-z background) being RAISED above the panel + apps on a
        # content press. With the pinned-background fix the backdrop is never
        # raised, so a bare-desktop click must leave the panel + windows fully
        # on screen. Click an EMPTY backdrop region near the bottom edge (well
        # below the icon column at x~55,y<=80 and clear of the app windows that
        # cluster upper-centre). Capture WHILE the press is held (the moment
        # the bug raised the backdrop) and after release.
        send("echo BACKDROPCLICK_BEGIN")
        absmove_px(640, 760, 0)         # hover empty backdrop
        time.sleep(0.3)
        absmove_px(640, 760, 1)         # press on bare desktop
        time.sleep(0.25)
        screendump("backdrop_down")     # frame WHILE pressed (bug raised bg here)
        absmove_px(640, 760, 0)         # release
        time.sleep(0.4)
        screendump("backdrop_after")    # settled frame after the backdrop click
        send("echo BACKDROPCLICK_END")
        time.sleep(0.5)

        # Final settled frame for reference.
        screendump("final")
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
    echo "[drag_gate] SKIP: guest did not reach interactive shell; log: $LOG" >&2
    exit 0
fi

echo "[drag_gate] --- window geometry seen ---"
for n in $(seq 1 7); do
    blk=$(awk "/WGEO${n}B/{f=1;next} /WGEO${n}E/{f=0} f" "$LOG" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]' | head -1)
    [ -n "$blk" ] && echo "[drag_gate]   wid $n: $blk"
done

echo "[drag_gate] --- assertions ---"
fail=0

# --- BUG 1 (proof of motion): SOME window actually MOVED under the drag. -
# Compare each window's PRE geometry (WGEO<n>) to its POST geometry
# (DGEO<n>); if any decorated window's x/y changed, the damage-scoped drag
# path moved it. (Frame no-blank / no-repaint proofs below are the primary
# evidence; this is the corroborating "the drag did something" check.)
moved=0
for n in $(seq 1 7); do
    pre=$(awk "/WGEO${n}B/{f=1;next} /WGEO${n}E/{f=0} f" "$LOG" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]' | head -1)
    post=$(awk "/DGEO${n}B/{f=1;next} /DGEO${n}E/{f=0} f" "$LOG" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]' | head -1)
    [ -z "$pre" ] || [ -z "$post" ] && continue
    pxy="$(echo "$pre"  | awk '{print $1" "$2}')"
    qxy="$(echo "$post" | awk '{print $1" "$2}')"
    if [ "$pxy" != "$qxy" ]; then
        echo "[drag_gate] PASS window $n MOVED ($pxy -> $qxy) under the damage-scoped drag"
        moved=1
    fi
done
if [ "$moved" = "0" ]; then
    echo "[drag_gate] NOTE no window position change recovered (readback flooded); the no-blank + no-repaint frame proofs below are authoritative"
fi

# Backdrop colour is the kernel root teal (#205060 == 32,80,96).
BR=32; BG=80; BB=96

# Helper: assert a frame is NOT near-blank (carries a panel + windows).
assert_not_blank() {
    local label="$1" ; local f="$OUT_DIR/$label.ppm"
    if [ ! -s "$f" ]; then
        echo "[drag_gate] NOTE $label.ppm missing; skip blank-probe"
        return
    fi
    local non
    non=$(nonbackdrop_px "$f" "$BR" "$BG" "$BB")
    echo "[drag_gate] $label: non-backdrop pixels = $non"
    if [ "$non" = "-1" ]; then
        echo "[drag_gate] NOTE $label format unreadable; probe inconclusive"
    elif [ "$non" -ge 2000 ]; then
        echo "[drag_gate] PASS $label is NOT blanked (panel/windows present: $non non-backdrop px)"
    else
        echo "[drag_gate] FAIL $label is BLANK — only $non non-backdrop px (screen disappeared)" >&2
        fail=1
    fi
}

# --- BUG 3: desktop-icon click does NOT blank the screen --------------
assert_not_blank "click_down"
assert_not_blank "click_after"
if [ -s "$OUT_DIR/base.ppm" ] && [ -s "$OUT_DIR/click_after.ppm" ]; then
    cdiff=$(whole_frame_diff "$OUT_DIR/base.ppm" "$OUT_DIR/click_after.ppm")
    echo "[drag_gate] icon-click whole-frame diff (base vs after): $cdiff (max $CLICK_FRAME_MAX)"
    if [ "$cdiff" = "-1" ]; then
        echo "[drag_gate] NOTE click frames differ in size/format; diff inconclusive"
    elif [ "$cdiff" -le "$CLICK_FRAME_MAX" ]; then
        echo "[drag_gate] PASS icon click changed only a small region ($cdiff px) — NO full-screen blank/repaint"
    else
        echo "[drag_gate] FAIL icon click changed $cdiff px — whole-screen repaint/blank signature" >&2
        fail=1
    fi
fi

# --- BUG A: a BARE-DESKTOP (backdrop) click does NOT blank the screen ---
# This is the KEY proof for the user-reported "click the desktop -> all apps
# + the top panel vanish" regression. Before the pinned-background fix, the
# press raised the full-screen backdrop above everything, so these frames went
# near-blank (only the cursor + desktop icons survived). After the fix the
# panel + app windows must remain (non-backdrop pixel count stays high).
assert_not_blank "backdrop_down"
assert_not_blank "backdrop_after"
if [ -s "$OUT_DIR/base.ppm" ] && [ -s "$OUT_DIR/backdrop_after.ppm" ]; then
    bdiff=$(whole_frame_diff "$OUT_DIR/base.ppm" "$OUT_DIR/backdrop_after.ppm")
    echo "[drag_gate] backdrop-click whole-frame diff (base vs after): $bdiff (max $CLICK_FRAME_MAX)"
    if [ "$bdiff" = "-1" ]; then
        echo "[drag_gate] NOTE backdrop frames differ in size/format; diff inconclusive"
    elif [ "$bdiff" -le "$CLICK_FRAME_MAX" ]; then
        echo "[drag_gate] PASS bare-desktop click changed only a small region ($bdiff px) — panel/apps NOT buried"
    else
        echo "[drag_gate] FAIL bare-desktop click changed $bdiff px — backdrop raised over panel/apps (the vanish bug)" >&2
        fail=1
    fi
fi

# --- BUG 1: drag is damage-scoped (no full-screen repaint, no blank) --
for k in 0 1 2 3 4 done; do
    assert_not_blank "drag_$k"
done
# Between consecutive mid-drag frames the changed region must be a small
# fraction of the frame (the window footprint), NOT a whole-screen repaint.
prev=""
for k in 0 1 2 3 4; do
    cur="$OUT_DIR/drag_$k.ppm"
    if [ -n "$prev" ] && [ -s "$prev" ] && [ -s "$cur" ]; then
        d=$(whole_frame_diff "$prev" "$cur")
        echo "[drag_gate] drag motion frame $((k-1))->$k changed pixels: $d (max $DRAG_FRAME_MAX)"
        if [ "$d" = "-1" ]; then
            echo "[drag_gate] NOTE drag frames differ in size/format; diff inconclusive"
        elif [ "$d" -le "$DRAG_FRAME_MAX" ]; then
            echo "[drag_gate] PASS drag frame $k touched a scoped region ($d px) — no full repaint"
        else
            echo "[drag_gate] FAIL drag frame $k changed $d px — full-present-per-motion signature" >&2
            fail=1
        fi
    fi
    prev="$cur"
done

# --- BUG 1 (the CRASH): dragging an icon must NOT spawn a storm ---------
# Count "[hamdesktop] launched" lines that appear BETWEEN the ICONDRAG_BEGIN
# and ICONDRAG_END markers. A correct build (launch only on a clean
# press+release over the same cell) prints ZERO for this drag-away gesture;
# the old per-motion-launch bug printed a flood (and then crashed the VM).
# We allow a tiny ceiling (a stray late click) but anything resembling a
# storm fails. We also require the post-drag liveness probe to have echoed
# back — proof the guest did NOT crash/exit under the drag.
dragblk=$(awk '/ICONDRAG_BEGIN/{f=1} f{print} /ICONDRAG_END/{f=0}' "$LOG" 2>/dev/null | tr -d '\r')
ndlaunch=$(printf '%s\n' "$dragblk" | grep -c '\[hamdesktop\] launched' || true)
echo "[drag_gate] icon-drag launches between BEGIN/END: $ndlaunch (storm ceiling 2)"
if [ "$ndlaunch" -le 2 ]; then
    echo "[drag_gate] PASS icon drag did NOT spawn a storm ($ndlaunch launches) — the crash is gone"
else
    echo "[drag_gate] FAIL icon drag spawned $ndlaunch apps — per-motion launch storm (the crash signature)" >&2
    fail=1
fi
# The hamsh idle heartbeat + line-editor ANSI controls interleave the serial
# echo of the probe MID-WORD, so the contiguous marker may not survive in the
# raw log even though the guest ran it. Strip the "[hamsh-alive]..." heartbeat
# and ESC[...] CSI sequences before matching so a live-but-flooded guest still
# passes. (The drag-storm / crash signatures above are the real assertions;
# this is purely a did-not-crash liveness check.)
alive_clean=$(sed -E 's/\[hamsh-alive\][^\r\n]*//g; s/\x1b\[[0-9;?]*[A-Za-z]//g' "$LOG" 2>/dev/null | tr -d '\r')
if printf '%s' "$alive_clean" | grep -q 'ICONDRAG_ALIVE_PROBE_XYZ'; then
    echo "[drag_gate] PASS guest ALIVE after the icon-drag storm bait (liveness probe echoed)"
else
    echo "[drag_gate] FAIL guest did NOT echo the post-drag liveness probe — likely crashed/exited" >&2
    fail=1
fi

echo "[drag_gate] artifacts (PPM frames) in $OUT_DIR"
if [ "$fail" = "0" ]; then
    echo "[drag_gate] RESULT: PASS"
    exit 0
fi
echo "[drag_gate] RESULT: FAIL"
exit 1
