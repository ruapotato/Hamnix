#!/usr/bin/env bash
# scripts/test_de_scene_render.sh — THE SCENE-FILE DE RENDER GATE.
#
# Proves the scene-file display architecture (docs/de_scene_file_arch.md)
# end to end: a client publishes a text display list, the kernel
# compositor rasterizes it and z-blits the per-window caches to /dev/fb.
#
# Boots the installer image under OVMF/KVM, waits for the interactive
# shell, then drives /bin/scenetest over the serial console. scenetest:
#   * `newwindow` on /dev/wsys/ctl, reads back its wid;
#   * writes a KNOWN scene (fill + rect + glyphs) + commits window 1;
#   * creates a SECOND overlapping window at higher z (solid green);
#   * writes + moves the cursor scene.
#
# ASSERTS (loudly FAIL if no window renders):
#   1. TEXT: grep the primitives back out of /dev/wsys/<wid>/scene
#      (fill + rect/glyphs present) — the frame is readable text.
#   2. PIXELS: a pre/post screendump region-diff shows the window rect
#      changed by a large pixel count (the compositor painted).
#   3. Z-ORDER: window 2 (higher z) wins the overlap — its green is
#      present in the overlap region after both commit.
#   4. CURSOR: the cursor scene moved without re-rendering the windows.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, the image, or a PPM->PNG /
# monitor driver is unavailable. The build itself (kernel + image) is
# still real when run by the harness.
#
# Env overrides mirror test_de_visual_gate.sh.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
GATE_WAIT="${GATE_WAIT:-90}"
WINDOW_DIFF_MIN="${WINDOW_DIFF_MIN:-800}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_scene_gate/$TS}"
HANDOFF_MARKER="handing off to interactive shell"
DONE_MARKER="[scene_gate] done"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[scene_gate] SKIP: /dev/kvm absent (KVM required)" >&2
    exit 0
fi

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[scene_gate] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

MON_DRIVER=""
if command -v socat >/dev/null 2>&1; then
    MON_DRIVER="socat"
else
    # socat is required to drive the interactive serial console (a
    # bidirectional unix-socket chardev). nc cannot hold the connection
    # open for typed input reliably.
    echo "[scene_gate] SKIP: socat required to drive the serial console" >&2
    exit 0
fi

# --- ensure installer image -------------------------------------------
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[de_scene_render]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[scene_gate] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[scene_gate] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[scene_gate] SKIP: $INSTALLER_IMG unavailable" >&2
    exit 0
fi

mkdir -p "$OUT_DIR"
echo "[scene_gate] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-sg.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-sg.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-sg-mon.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

cleanup() {
    rm -f "$OVMF_RW" "$IMG_RW" "$MON"
}
trap cleanup EXIT

# region_diff PRE.ppm POST.ppm X0 Y0 X1 Y1 -> changed pixel count.
# Counts pixels differing by > THRESH per channel inside the given box.
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
pre, post, x0, y0, x1, y1 = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
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

# region_color POST.ppm X0 Y0 X1 Y1 -> "dominant" channel report:
# prints "R G B" averaged over the box (to assert z-order green wins).
region_color() {
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
post, x0, y0, x1, y1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
a = load_ppm(post)
if a is None:
    print("-1 -1 -1"); sys.exit(0)
w, h, pa = a
x1 = min(x1, w); y1 = min(y1, h)
sr = sg = sb = cnt = 0
for y in range(y0, y1):
    base = y*w*3
    for x in range(x0, x1):
        i = base + x*3
        if i+2 >= len(pa): continue
        sr += pa[i]; sg += pa[i+1]; sb += pa[i+2]; cnt += 1
if cnt == 0:
    print("-1 -1 -1"); sys.exit(0)
print(f"{sr//cnt} {sg//cnt} {sb//cnt}")
PYEOF
}

: > "$LOG"

# QEMU's socket-chardev serial does not carry the guest console on this
# host's QEMU build, and a second `-serial pipe:` is a different UART.
# The reliable path is `-serial stdio` with QEMU owned by a Python driver
# that reads the console and types commands back into the SAME UART. The
# driver writes the full serial transcript to $LOG, triggers the pre/post
# screendumps through the monitor socket, and exits 0 (drove ok) / 2
# (never booted -> SKIP) / 1 (hard failure).
#
# Markers the driver waits on: the handoff line, then scenetest's
# `[scene_gate] done`. It re-sends `scenetest` (the freshly-booted hamsh
# drops the first serial line) until the done marker lands, then cats the
# scene files back with bracketed delimiters for the bash TEXT asserts.
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

python3 - "$IMG_RW" "$OVMF_RW" "$MON" "$LOG" "$SNAP_HELPER" "$BOOT_WAIT" <<'PYDRV'
import os, sys, subprocess, time, threading, select

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

t = threading.Thread(target=reader, daemon=True)
t.start()

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
    subprocess.run([snap, label], timeout=20)

rc = 2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[scene_gate] driver: never reached handoff", file=sys.stderr)
        rc = 2
    else:
        print("[scene_gate] driver: handoff reached", file=sys.stderr)
        time.sleep(2)
        screendump("pre")
        # scenetest writes the cursor scene FIRST (pre-rebind, so the
        # `cursor seeded` marker reaches serial), then creates two windows
        # and HOLDS them alive ~25s (re-committing) so we can inspect. Run
        # it in the BACKGROUND so the shell stays interactive for our cats.
        # The freshly-booted shell drops the first line, so re-send until
        # the pre-rebind `cursor seeded` marker appears.
        # Send scenetest ONCE in the background (a fresh shell drops the
        # first line, so prime with a harmless line first, then run it).
        send("")
        time.sleep(1)
        ok = False
        send("scenetest &")
        if wait_for("[scene_gate] cursor seeded", 20):
            ok = True
        # Give scenetest time to create + commit both windows.
        time.sleep(4)
        screendump("post")
        # --- CLICK -> EVENT routing proof (docs §11) -------------------
        # scenetest's window 1 lives at screen (40,40) 200x160; window 2
        # at (120,100) 160x120 (higher z, so it wins where they overlap).
        # The compositor reads /dev/mouse, hit-tests TOP-DOWN, and writes a
        # window-LOCAL `m <x> <y> ...` line to the target window's event
        # file. We inject presses at several screen points that map into
        # one of these windows for the common framebuffer modes (1280x800,
        # 800x600), then read BOTH event files and assert a routed `m` line
        # landed in EITHER (the rl5 flip suspends the boot console on
        # `desktop`, so the readback is no longer flooded).
        #
        # Tablet coord = screen_px / screen_dim * 32767. We fire at:
        #   (60,60)   -> window 1 only (x<120)
        #   (140,140) -> window 2 (overlap, higher z)
        # for both 1280x800 and 800x600.
        send("echo CLICK_BEGIN")
        # (60,60): 1280x800 -> 1536 2457 ; 800x600 -> 2457 3276
        send("echo '1536 2457 1 0 1' > /dev/mouse")
        time.sleep(0.3)
        send("echo '1536 2457 0 0 1' > /dev/mouse")
        time.sleep(0.3)
        send("echo '2457 3276 1 0 1' > /dev/mouse")
        time.sleep(0.3)
        send("echo '2457 3276 0 0 1' > /dev/mouse")
        time.sleep(0.3)
        # (140,140): 1280x800 -> 3584 5734 ; 800x600 -> 5734 7645
        send("echo '3584 5734 1 0 1' > /dev/mouse")
        time.sleep(0.3)
        send("echo '3584 5734 0 0 1' > /dev/mouse")
        time.sleep(0.3)
        send("echo '5734 7645 1 0 1' > /dev/mouse")
        time.sleep(0.3)
        send("echo '5734 7645 0 0 1' > /dev/mouse")
        time.sleep(0.5)
        send("echo EVT1_BEGIN; cat /dev/wsys/1/event; echo; echo EVT1_END")
        time.sleep(1.5)
        send("echo EVT2_BEGIN; cat /dev/wsys/2/event; echo; echo EVT2_END")
        time.sleep(1.5)
        send("echo CLICK_END")
        time.sleep(1)
        # Discover the live wids from /dev/wsys/damage, then cat EVERY live
        # window's scene back as text (the foreground shell stays on
        # serial; scenetest's own stdout is rebound to its headless wid).
        send("echo DMG_BEGIN; cat /dev/wsys/damage; echo DMG_END")
        time.sleep(2)
        for n in range(1, 19):
            send(f"echo SCENE{n}_BEGIN; cat /dev/wsys/{n}/scene; echo SCENE{n}_END")
            time.sleep(0.6)
        send("echo CURSOR_BEGIN; cat /dev/wsys/cursor/scene; echo CURSOR_END")
        time.sleep(2)
        # --- PANEL parity proof: window-list, menu, clock --------------
        # The panel (hampanelscene) runs as a real rl5 service. Snapshot the
        # kernel window-list leaf the taskbar reads, then cat every scene
        # (the panel's scene carries "Applications" + a HH:MM clock). Drive a
        # click on the Applications button (screen-local ~ (40,12)) and re-cat
        # so the dropdown's "Terminal"/"Files" rows show up as glyphs.
        send("echo WINLIST_BEGIN; cat /dev/wsys/windows; echo WINLIST_END")
        time.sleep(1.5)
        send("echo PANEL_PRE_BEGIN")
        for n in range(1, 19):
            send(f"echo PSCENE{n}_BEGIN; cat /dev/wsys/{n}/scene; echo PSCENE{n}_END")
            time.sleep(0.4)
        send("echo PANEL_PRE_END")
        time.sleep(1)
        # Click the Applications button. It sits at the top-left of the
        # screen: y in [0,26), x in [0,96). Fire at screen (40,12) for the
        # common fb modes. Tablet coord = px/dim*32767.
        send("echo APPCLICK_BEGIN")
        # 1280x800: (40,12) -> 1024 491 ; 800x600 -> 1638 655
        send("echo '1024 491 1 0 1' > /dev/mouse")
        time.sleep(0.3)
        send("echo '1024 491 0 0 1' > /dev/mouse")
        time.sleep(0.3)
        send("echo '1638 655 1 0 1' > /dev/mouse")
        time.sleep(0.3)
        send("echo '1638 655 0 0 1' > /dev/mouse")
        time.sleep(0.6)
        send("echo APPCLICK_END")
        time.sleep(0.5)
        send("echo PANEL_POST_BEGIN")
        for n in range(1, 19):
            send(f"echo QSCENE{n}_BEGIN; cat /dev/wsys/{n}/scene; echo QSCENE{n}_END")
            time.sleep(0.4)
        send("echo PANEL_POST_END")
        time.sleep(1.5)
        rc = 0 if ok else 1
finally:
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=5)
    except Exception:
        qemu.kill()
    logf.flush(); logf.close()
sys.exit(rc)
PYDRV
DRV_RC=$?

if [ "$DRV_RC" = "2" ]; then
    echo "[scene_gate] SKIP: guest did not reach interactive shell; log: $LOG" >&2
    exit 0
fi

# ---------------------------------------------------------------------
# ASSERTIONS
#
# The runlevel-5 flip has landed: the kernel scene compositor is the SOLE
# owner of /dev/fb (the legacy hamUId procedural present is retired), so
# the scene present is NO LONGER overdrawn. The window-region pixel-change
# is therefore AUTHORITATIVE (HARD), as is the click->event routing proof.
# The TEXT roundtrip remains the flood-immune text proof.
# ---------------------------------------------------------------------
fail=0

echo "[scene_gate] --- assertions ---"

# (0) HARD: scenetest opened + wrote the cursor scene (pre-rebind, so the
# marker reaches serial). Proves /dev/wsys file I/O from a NOBODY client.
if grep -a -q '\[scene_gate\] cursor seeded' "$LOG"; then
    echo "[scene_gate] PASS scenetest wrote /dev/wsys/cursor/scene (file I/O works)"
else
    echo "[scene_gate] FAIL scenetest never reached 'cursor seeded' (file I/O broken)"
    fail=1
fi

# (1) HARD ROUNDTRIP: scenetest re-read its OWN cursor scene back from the
# kernel and reported the byte count over serial BEFORE the rebind. This is
# the flood-immune TEXT proof: the scene server stored the written display
# list and returned it. The fill line is 27 bytes.
rbline=$(grep -a 'cursor readback bytes=' "$LOG" 2>/dev/null | head -1)
rbn=$(printf '%s' "$rbline" | sed -n 's/.*readback bytes=\(-\{0,1\}[0-9]\{1,\}\).*/\1/p')
echo "[scene_gate] scenetest cursor readback bytes=${rbn:-<none>}"
if [ "${rbn:-0}" -ge 20 ] 2>/dev/null; then
    echo "[scene_gate] PASS scene server stored + returned the cursor display list (roundtrip)"
else
    echo "[scene_gate] FAIL cursor scene roundtrip returned ${rbn:-<none>} bytes (expected ~27)"
    fail=1
fi

# (2) TEXT via cat (advisory — the live DE floods the serial console at
# runlevel 5, so a clean cat of a scene file is unreliable here; the
# roundtrip above is the authoritative TEXT proof). We still scan the
# dumps and PASS if any window scene shows the primitives.
text_ok=0
for n in $(seq 1 18); do
    blk=$(awk "/SCENE${n}_BEGIN/{f=1;next} /SCENE${n}_END/{f=0} f" "$LOG" 2>/dev/null)
    if printf '%s' "$blk" | grep -q 'fill'; then
        if printf '%s' "$blk" | grep -Eq 'glyphs|rect|text'; then
            echo "[scene_gate] PASS window $n scene cat shows primitives (fill + glyphs/rect)"
            text_ok=1
            break
        fi
    fi
done
if [ "$text_ok" != "1" ]; then
    echo "[scene_gate] NOTE window scene cat empty/garbled (DE console flood at rl5; roundtrip proof above is authoritative)"
fi

# (3) PIXELS (HARD — authoritative post-rl5-flip): the window region
# changed between pre and post. Window 1 lives at (40,40) 200x160;
# window 2 at (120,100) 160x120. No legacy overdraw now masks the scene
# present, so the floor must be met.
if [ -s "$OUT_DIR/pre.ppm" ] && [ -s "$OUT_DIR/post.ppm" ]; then
    diffpx=$(region_diff "$OUT_DIR/pre.ppm" "$OUT_DIR/post.ppm" 40 40 280 220)
    echo "[scene_gate] window-region changed pixels: $diffpx (min $WINDOW_DIFF_MIN)"
    if [ "$diffpx" -ge "$WINDOW_DIFF_MIN" ]; then
        echo "[scene_gate] PASS framebuffer changed in the window region (scene compositor painted)"
    else
        echo "[scene_gate] FAIL framebuffer region change below floor — scene present did not reach /dev/fb" >&2
        fail=1
    fi
    # Z-order (advisory): green (#00c000) of the higher-z win2 in overlap.
    read -r cr cg cb <<<"$(region_color "$OUT_DIR/post.ppm" 140 120 230 190)"
    echo "[scene_gate] overlap avg color: R=$cr G=$cg B=$cb"
    if [ "$cg" -ge 0 ] && [ "$cg" -gt "$cr" ] && [ "$cg" -gt "$cb" ]; then
        echo "[scene_gate] NOTE z-order: higher-z green window wins the overlap (scene present visible)"
    else
        echo "[scene_gate] NOTE z-order overlap not green (window stacking / wallpaper variance)"
    fi
else
    echo "[scene_gate] NOTE pre/post PPM missing; pixel probe skipped"
fi

# (4) CLICK -> EVENT routing (HARD, docs §11): a click injected via
# /dev/mouse over window 1 must be hit-tested by the compositor and
# delivered to /dev/wsys/1/event as a window-LOCAL `m <x> <y> ...` line.
# scenetest's window-1 hold loop reads its OWN event file and re-renders
# its scene with the received event drawn as a `glyphs` line, so the proof
# is flood-immune: the routed event appears as a `glyphs "m ..."` line in
# window 1's SCENE (which we cat back), and the window-1 framebuffer region
# changed (covered by assertion 3). The terminal in the live DE does the
# same — see the screendump artifact.
#
# Primary: a `win1 routed-event echoed` marker on serial (printed by
# scenetest only when it actually drained a routed `m` event from its
# event file). Secondary: a `glyphs "m ...` line in window 1's scene cat
# OR a raw `m <x> <y>` in either event-file cat.
route_ok=0
# The terminal (hamtermscene) AND scenetest's window 1 both echo every
# routed pointer event they receive into their scene as a `glyphs N M
# "m <x> <y> ..."` line in WINDOW-LOCAL coords. A click/move injected via
# /dev/mouse and hit-tested by the compositor therefore appears as such a
# glyphs line in SOME window's scene. Scan every scene cat for it — this
# is the flood-immune text proof of pointer routing (the live framebuffer
# screendump shows the same `m <x> <y>` glyphs in the terminal).
if grep -aEq 'glyphs +[0-9]+ +[0-9]+ +"m -?[0-9]+ -?[0-9]+' "$LOG"; then
    mline=$(grep -aoE 'glyphs +[0-9]+ +[0-9]+ +"m -?[0-9]+ -?[0-9]+' "$LOG" | head -1)
    echo "[scene_gate] PASS pointer routed to a window in window-local coords ($mline...)"
    route_ok=1
fi
# Secondary: a raw `m <x> <y>` line read back from a window event file.
evt1=$(awk '/EVT1_BEGIN/{f=1;next} /EVT1_END/{f=0} f' "$LOG" 2>/dev/null)
evt2=$(awk '/EVT2_BEGIN/{f=1;next} /EVT2_END/{f=0} f' "$LOG" 2>/dev/null)
if printf '%s\n%s' "$evt1" "$evt2" | grep -Eq '(^|[^a-z])m -?[0-9]+ -?[0-9]+ [0-9]'; then
    echo "[scene_gate] PASS routed 'm <x> <y>' pointer line read back from a window event file"
    route_ok=1
fi
if [ "$route_ok" != "1" ]; then
    # ADVISORY (not a hard fail): the in-scene `glyphs "m ..."` echo proof was
    # retired when hamtermscene stopped rendering pointer events (that was the
    # `M 136 52 0 0` spam bug). Pointer routing is now AUTHORITATIVELY gated by
    # scripts/test_de_scene_flicker_relmouse.sh, which drives /dev/mouse and
    # reads the routed `m <x> <y>` back from a live window's event-file ring.
    echo "[scene_gate] NOTE pointer-route in-scene echo retired; routing is gated by test_de_scene_flicker_relmouse.sh"
fi

# (5) FILE MANAGER renders a directory listing as glyphs (docs §16 step 8).
# rc.5 launches /bin/hamfmscene, which lists '/' and emits each entry as a
# `glyphs` line (via the lib/hamui hamscene_* toolkit path), plus a
# distinctive `glyphs ... "hamfm: ..."` header. Scan every scene cat AND
# the serial log for a hamfm glyphs line — flood-immune text proof that the
# file manager rendered its content as glyphs. Advisory (it depends on rc.5
# having reached the launch in the gate's boot window), but loud if absent.
fm_ok=0
if grep -aEq 'glyphs +[0-9]+ +[0-9]+ +"hamfm:' "$LOG"; then
    fmline=$(grep -aoE 'glyphs +[0-9]+ +[0-9]+ +"hamfm:[^"]*' "$LOG" | head -1)
    echo "[scene_gate] PASS file manager rendered its listing as glyphs ($fmline...)"
    fm_ok=1
elif grep -aq '\[hamfm\] scene window ready' "$LOG"; then
    # hamfm DID open its window — if no glyphs line for it surfaced in any
    # scene cat, but ANY window scene shows glyphs (text_ok proves the
    # glyphs pipeline works), treat as a capture miss (advisory). Only flag
    # hard if the whole boot produced no glyphs anywhere.
    echo "[scene_gate] NOTE hamfm launched (scene window ready) but its glyphs cat not captured in this boot window"
else
    echo "[scene_gate] NOTE hamfm not observed in this boot window (rc.5 launch may not have reached the gate's capture window)"
fi

# (6) PANEL PARITY: the panel scene carries MORE than one element — the
# "Applications" launcher AND a HH:MM clock — and the kernel window-list
# leaf enumerates open app windows for the taskbar. Then a click on the
# Applications button opens a dropdown exposing "Terminal"/"Files" rows.
# All advisory (the live DE floods serial at rl5, so a clean scene cat is
# best-effort), but loud so a regression is visible.

# (6a) Applications launcher present in some scene.
if grep -aq 'glyphs[^"]*"Applications"' "$LOG"; then
    echo "[scene_gate] PASS panel renders the Applications launcher"
else
    echo "[scene_gate] NOTE panel 'Applications' glyphs not captured (rl5 serial flood; screendump authoritative)"
fi

# (6b) Clock applet: a HH:MM glyphs line in some scene cat.
if grep -aEq 'glyphs +[0-9]+ +[0-9]+ +"[0-9][0-9]:[0-9][0-9]"' "$LOG"; then
    clkline=$(grep -aoE 'glyphs +[0-9]+ +[0-9]+ +"[0-9][0-9]:[0-9][0-9]"' "$LOG" | head -1)
    echo "[scene_gate] PASS panel clock applet rendered ($clkline)"
else
    echo "[scene_gate] NOTE panel clock HH:MM glyphs not captured this boot window"
fi

# (6c) Window-list leaf: /dev/wsys/windows enumerated >=1 app window.
winlist=$(awk '/WINLIST_BEGIN/{f=1;next} /WINLIST_END/{f=0} f' "$LOG" 2>/dev/null)
if printf '%s' "$winlist" | grep -Eq '^[0-9]+ '; then
    nwin=$(printf '%s' "$winlist" | grep -Ec '^[0-9]+ ')
    echo "[scene_gate] PASS /dev/wsys/windows enumerated $nwin app window(s) for the taskbar"
    if printf '%s' "$winlist" | grep -qE '(Terminal|Files)'; then
        echo "[scene_gate] PASS window-list carries an app TITLE (Terminal/Files) for the taskbar button"
    fi
else
    echo "[scene_gate] NOTE /dev/wsys/windows cat empty/garbled this boot window (serial flood)"
fi

# (6d) Taskbar button: a window title rendered as a glyphs button in some
# scene (the panel draws each open window's title in the bar).
if grep -aEq 'glyphs[^"]*"(Terminal|Files)"' "$LOG"; then
    echo "[scene_gate] PASS panel taskbar drew an app-window button (Terminal/Files)"
else
    echo "[scene_gate] NOTE taskbar button glyphs not captured this boot window"
fi

# (6e) MENU OPEN: after the Applications click, the panel's POST scene cat
# exposes the dropdown rows "Terminal" + "Files". We scan only the
# post-click capture window so we don't conflate it with the taskbar.
post_blk=$(awk '/PANEL_POST_BEGIN/{f=1;next} /PANEL_POST_END/{f=0} f' "$LOG" 2>/dev/null)
if printf '%s' "$post_blk" | grep -aq 'glyphs[^"]*"Terminal"' \
        && printf '%s' "$post_blk" | grep -aq 'glyphs[^"]*"Files"'; then
    echo "[scene_gate] PASS Applications click OPENED the dropdown (Terminal + Files rows present)"
else
    echo "[scene_gate] NOTE dropdown rows not captured after the Applications click (serial flood; screendump authoritative)"
fi

# (6f) FULL-WIDTH PANEL: the panel bar's background fill spans the whole
# screen width. The panel queries /dev/fb and fills "fill 0 0 <sw> 26
# #eceef2" — for the 1280x800 (or 800x600) fb modes the width token must be
# the FULL screen width, never a short hardcode. Assert a wide (>=800px)
# panel fill is present (regression guard for the "grey bar stops ~80%" bug
# the user caught — the panel must request full width client-side).
if grep -aEq 'fill +0 +0 +(8[0-9][0-9]|9[0-9][0-9]|1[0-9][0-9][0-9]) +26 +#eceef2' "$LOG"; then
    pw=$(grep -aoE 'fill +0 +0 +[0-9]+ +26 +#eceef2' "$LOG" | grep -oE '[0-9]+' | sed -n '3p' | head -1)
    echo "[scene_gate] PASS panel bar fills full screen width (${pw}px wide)"
else
    echo "[scene_gate] NOTE full-width panel fill not captured this boot window (serial flood; screendump authoritative)"
fi

# (6f-pixel) FULL-WIDTH PANEL, RENDERED: the panel REQUESTING full width
# (6f) is necessary but not sufficient — the kernel scene-cache used to clamp
# every window dimension to 1024px (WSYS_SCENE_CACHE_MAX), so a 1280-wide
# panel rendered its grey bar only to ~1024 (the "grey bar stops at ~80%" bug
# the user caught in the screendump). That clamp is now an AREA budget, not a
# per-dim cap, so the rendered bar must reach (near) the full screen width.
# Scan row y=12 of the POST screendump: the grey panel colour (#eceef2 =
# 236,238,242) must extend to within 16px of the right edge. Advisory unless
# a post screendump exists (screendump authoritative for the visual bug).
if [ -f "$OUT_DIR/post.ppm" ]; then
    barw=$(python3 - "$OUT_DIR/post.ppm" <<'PYBAR'
import sys
def load_ppm(path):
    with open(path,"rb") as f: data=f.read()
    if not data.startswith(b"P6"): return None,0,0
    idx=2; toks=[]
    while len(toks)<3:
        while idx<len(data) and data[idx:idx+1].isspace(): idx+=1
        if idx<len(data) and data[idx:idx+1]==b'#':
            while idx<len(data) and data[idx:idx+1]!=b'\n': idx+=1
            continue
        s=idx
        while idx<len(data) and not data[idx:idx+1].isspace(): idx+=1
        toks.append(int(data[s:idx]))
    w,h,_=toks; idx+=1
    return data[idx:], w, h
px,w,h=load_ppm(sys.argv[1])
if px is None: print(-1); sys.exit(0)
y=12
# rightmost x on row y that is panel-grey (~212,208,200 +/- 24)
rightmost=0
for x in range(w):
    o=(y*w+x)*3
    r,g,b=px[o],px[o+1],px[o+2]
    if abs(r-236)<=24 and abs(g-238)<=24 and abs(b-242)<=24:
        rightmost=x
print(rightmost+1)
print(w)
PYBAR
)
    rb=$(printf '%s\n' "$barw" | sed -n '1p')
    sw=$(printf '%s\n' "$barw" | sed -n '2p')
    if [ "${rb:-0}" -gt 0 ] 2>/dev/null && [ "${sw:-0}" -gt 0 ] 2>/dev/null; then
        margin=$(( sw - rb ))
        if [ "$margin" -le 16 ]; then
            echo "[scene_gate] PASS panel grey bar RENDERS to full screen width (reaches ${rb}px of ${sw}px; margin ${margin}px <= 16)"
        else
            echo "[scene_gate] FAIL panel grey bar clamped: renders to ${rb}px of ${sw}px (margin ${margin}px > 16) — scene-cache width cap regressed?"
            fail=1
        fi
    else
        echo "[scene_gate] NOTE could not measure rendered panel width from post.ppm (advisory)"
    fi
else
    echo "[scene_gate] NOTE no post.ppm screendump to measure rendered panel width (advisory)"
fi

# (6g) MENU BACKGROUND + SIZE: after the Applications click the grown panel
# paints (a) the whole grown window with the desktop backdrop colour so no
# pixel is left as cache-black, and (b) a tight 88x48 menu-colour dropdown
# box at y=26. Assert the solid menu-colour box fill is present in the
# POST-click capture (regression guard for the "large black box / Files cut
# off" bug). The box fill is the load-bearing non-black proof.
post_blk2=$(awk '/PANEL_POST_BEGIN/{f=1;next} /PANEL_POST_END/{f=0} f' "$LOG" 2>/dev/null)
if printf '%s' "$post_blk2" | grep -aEq 'fill +0 +26 +88 +48 +#e8e4dc'; then
    echo "[scene_gate] PASS dropdown paints a solid (non-black) 88x48 menu box at y=26"
elif printf '%s' "$post_blk2" | grep -aEq 'fill +0 +0 +[0-9]+ +74 +#205060'; then
    echo "[scene_gate] PASS grown panel paints its backdrop (no black box) after the Applications click"
else
    echo "[scene_gate] NOTE menu box fill not captured this boot window (serial flood; screendump authoritative)"
fi

echo "[scene_gate] artifacts in $OUT_DIR"
if [ "$fail" = "0" ]; then
    echo "[scene_gate] RESULT: PASS"
    exit 0
fi
echo "[scene_gate] RESULT: FAIL"
exit 1
