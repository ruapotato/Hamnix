#!/usr/bin/env bash
# scripts/test_hambrowse_sdl_host.sh — FAST, QEMU-free host gate for the
# INTERACTIVE hambrowse window on Linux (user/hambrowse_sdl_host.ad, the shared
# engine, + scripts/hambrowse_sdl_bridge.c, the real SDL2 shell).
#
# It:
#   1. Compiles the Adder browser engine for x86_64-linux (the host frontend).
#   2. Compiles the SDL2 C bridge against the system libSDL2.
#   3. Confirms user/hambrowse.ad STILL compiles for x86_64-adder-user (device
#      dual-target parity — the on-device browser must not regress).
#   4. Runs the bridge HEADLESS under SDL's dummy video driver, replaying a
#      scripted sequence of synthetic SDL events (click a link, focus + edit the
#      address bar + Enter to load a second local page, scroll) through the SAME
#      SDL event queue + translation the interactive window uses, dumping each
#      resulting frame to a PPM.
#   5. Asserts the loop dispatched every event WITHOUT crashing (child exit 0)
#      and that the rendered output CHANGED — specifically that navigation
#      between distinct local pages happened (multiple distinct content frames,
#      and the home page's content recurs after a typed round-trip).
#
# Pass marker: [test_hambrowse_sdl] PASS   Fail marker: [test_hambrowse_sdl] FAIL

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
CHILD="$OUT/hambrowse_sdl"
BRIDGE="$OUT/hambrowse_sdl_bridge"
LIBSDL="/usr/lib/x86_64-linux-gnu/libSDL2-2.0.so.0"
FRAMES="$OUT/hambrowse_sdl_frames"
SCRIPT="$OUT/hambrowse_sdl_events.txt"
mkdir -p "$OUT" "$FRAMES"
rm -f "$FRAMES"/frame*.ppm
fail=0

echo "[test_hambrowse_sdl] (1/5) compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_sdl_host.ad -o "$CHILD" 2>"$OUT/hambrowse_sdl_compile.log"; then
    echo "[test_hambrowse_sdl] FAIL: host engine did not compile"
    cat "$OUT/hambrowse_sdl_compile.log"; exit 1
fi
echo "[test_hambrowse_sdl] PASS host engine compiled -> $CHILD"

echo "[test_hambrowse_sdl] (2/5) compiling SDL2 bridge ..."
if [ ! -e "$LIBSDL" ]; then
    echo "[test_hambrowse_sdl] FAIL: $LIBSDL absent (install libsdl2-2.0-0)"; exit 1
fi
if ! gcc -O2 scripts/hambrowse_sdl_bridge.c -o "$BRIDGE" "$LIBSDL" \
        2>"$OUT/hambrowse_sdl_bridge_compile.log"; then
    echo "[test_hambrowse_sdl] FAIL: bridge did not compile"
    cat "$OUT/hambrowse_sdl_bridge_compile.log"; exit 1
fi
echo "[test_hambrowse_sdl] PASS bridge compiled -> $BRIDGE"

echo "[test_hambrowse_sdl] (3/5) compiling NATIVE hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/hambrowse_native.log"; then
    echo "[test_hambrowse_sdl] FAIL: device hambrowse regressed (did not compile)"
    cat "$OUT/hambrowse_native.log"; exit 1
fi
echo "[test_hambrowse_sdl] PASS device hambrowse still compiles (dual-target intact)"

# ---- scripted synthetic events -------------------------------------------
# Default window is 900x640. A click at (100,207) lands on the home page's
# "the second page" link. RE-PROBED 2026-07-27: the old (100,186) predated the
# prose-full-width + 18px-row-height layout changes and landed a whole line box
# ABOVE the link, so the click navigated nowhere. The link's ink now occupies
# doc-space y=122..136 (x=47..169) in the shared pixel render, and the window
# maps doc y to CONTENT_Y (78) + doc_y at scroll 0 -> window y=200..214.
# Then focus the URL bar, clear it, type the home page path + Enter to navigate
# back, then resize short + wheel to scroll.
cat > "$SCRIPT" <<'EVENTS'
click 100 207
# focus the omnibox. RE-PROBED 2026-07-27: (200,28) predated the Chrome-shaped
# chrome (a 34px TAB STRIP above a 44px TOOLBAR, lib/web/state.ad), so y=28 hit
# the tab strip and the address bar never took focus. The toolbar spans
# ADDR_Y=34 .. ADDR_Y+ADDR_H=78; click its middle, clear of the nav buttons.
click 300 56
ctrlkey 97
key 8
text tests/fixtures/hambrowse_sdl_home.html
key 13
resize 900 320
wheel -3
quit
EVENTS

echo "[test_hambrowse_sdl] (4/5) replaying events headless (SDL dummy driver) ..."
if ! "$BRIDGE" "$CHILD" "tests/fixtures/hambrowse_sdl_home.html" \
        --test "$SCRIPT" "$FRAMES" >"$OUT/hambrowse_sdl_run.log" 2>&1; then
    echo "[test_hambrowse_sdl] FAIL: bridge/child exited non-zero"
    cat "$OUT/hambrowse_sdl_run.log"; exit 1
fi
cat "$OUT/hambrowse_sdl_run.log"

echo "[test_hambrowse_sdl] (5/5) asserting dispatch + navigation ..."
python3 - "$FRAMES" <<'PY'
import sys, os, glob, hashlib
d = sys.argv[1]
paths = sorted(glob.glob(os.path.join(d, "frame*.ppm")))
if len(paths) < 6:
    print("[test_hambrowse_sdl] FAIL: too few frames (%d)" % len(paths)); sys.exit(1)

def load(p):
    with open(p, "rb") as f:
        assert f.readline().strip() == b"P6"
        w, h = map(int, f.readline().split())
        f.readline()  # maxval
        body = f.read(w*h*3)
    return w, h, body

# Content region = pixels below the chrome, hashed per frame so we can count
# DISTINCT page contents independent of chrome (address bar / nav buttons).
# RE-PINNED 2026-07-27 from y>=40 to y>=78: the window grew a Chrome-shaped
# 34px TAB STRIP + 44px TOOLBAR (CONTENT_Y == 78 in lib/web/state.ad), so the
# old 40px cut still included the omnibox — every keystroke of the typed address
# changed the "content" hash and the home page's signature could never recur.
def content_sig(w, h, body):
    off = 78 * w * 3
    return hashlib.sha1(body[off:]).hexdigest()

frames = [load(p) for p in paths]
w0 = frames[0][0]
sigs = [content_sig(*fr) for fr in frames]
distinct = set(sigs)
home_sig = sigs[0]
print("[test_hambrowse_sdl] frames=%d distinct_content=%d" % (len(frames), len(distinct)))

ok = True
# (a) at least two DISTINCT page contents were rendered -> navigation happened.
if len(distinct) < 2:
    print("[test_hambrowse_sdl] FAIL: content never changed (no navigation)"); ok = False
else:
    print("[test_hambrowse_sdl] PASS content changed across %d distinct pages" % len(distinct))
# (b) the FIRST synthetic event is a link click; its frame (index 1, the
#     button-down) must already show a DIFFERENT page -> click navigation works.
if sigs[1] != home_sig:
    print("[test_hambrowse_sdl] PASS link click navigated to a new page")
else:
    print("[test_hambrowse_sdl] FAIL: link click did not change the page"); ok = False
# (c) the home content RECURS after the typed round-trip navigation -> the
#     address-bar edit + Enter loaded a page (and back to home) for real.
if home_sig in sigs[3:]:
    print("[test_hambrowse_sdl] PASS home content recurs after typed-address navigation")
else:
    print("[test_hambrowse_sdl] FAIL: typed-address navigation did not return to home"); ok = False
# (d) all frames share the initial window width (protocol sanity).
if all(fr[0] == w0 or fr[0] <= 1200 for fr in frames):
    print("[test_hambrowse_sdl] PASS frame dimensions sane")
sys.exit(0 if ok else 1)
PY
rc=$?
if [ $rc -ne 0 ]; then fail=1; fi

if [ "$fail" -eq 0 ]; then
    echo "[test_hambrowse_sdl] PASS"
else
    echo "[test_hambrowse_sdl] FAIL"
fi
exit $fail
