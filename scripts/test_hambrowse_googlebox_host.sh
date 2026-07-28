#!/usr/bin/env bash
# scripts/test_hambrowse_googlebox_host.sh — FAST, QEMU-free gate pinning the
# GOOGLE SEARCH BOX's width and position against the values real Chromium
# computes for the same box tree.
#
# USER-REPORTED BUG this pins: "the Google homepage is broken and I can't select
# the search bar." The field was not un-clickable — hit-testing, focus and typing
# all worked at the time. It was LAID OUT 1008px wide inside a 1024px viewport
# and ran ~260px off the RIGHT EDGE, so the box a user aims at was not on screen.
#
# ROOT CAUSE: horizontal CSS percentages resolved against the PAGE CONTENT
# COLUMN, never against the element's CONTAINING BLOCK (CSS 2.1 §10.2). A
# stylesheet is parsed once, before any box exists, so `width:100%` was baked to
# the page width at PARSE time and stayed that way. google.com's field is
# `.gLFyf{width:100%}` nested four levels inside `.A8SBwf{max-width:584px;
# margin:0 auto}` — so 100% of the wrong thing is the whole viewport.
# FIX: lib/web/css/cascade.ad resolves a horizontal % against the live block
# stack (_pct_cb_w), and a stylesheet `width:N%` is kept as a raw percentage
# (r_wpm) and RE-RESOLVED at cascade-match time, when the containing block is
# known.
#
# ORACLE — chromium 147.0.7727.137, 1024px viewport, on the SAME fixture
# (tests/fixtures/hambrowse_googlebox.html, a byte-stable distillation of the
# live homepage's box tree; the live page is 1.5 MB and changes daily):
#
#     .gLFyf  (the search field)   w=447  left=221  right=668
#     .A8SBwf (centred container)  w=584  left=220  right=804
#     .half   (50% of a 400px parent)  content w=200
#
# BEFORE this fix hambrowse laid the field out at 1008px starting at x=228, i.e.
# right=1236 — 212px PAST the 1024px viewport edge. The `.half` control, a plain
# `width:50%` inside `width:400px`, came out 504px (50% of the page) instead of
# 200px.
#
# Also renders the REAL captured google.com homepage (tests/fixtures/realsites/
# google_home.html) so a regression on the actual served bytes fails here too.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_googlebox.html"
REAL="tests/fixtures/realsites/google_home.html"
mkdir -p "$OUT"
fail=0

echo "[hb-gbox] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/gbox_compile.log"; then
    echo "[hb-gbox] FAIL: host harness did not compile"; cat "$OUT/gbox_compile.log"; exit 1
fi

echo "[hb-gbox] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/gbox_native.log"; then
    echo "[hb-gbox] FAIL: native hambrowse did not compile"; cat "$OUT/gbox_native.log"; exit 1
fi
echo "[hb-gbox] PASS both targets compile"

# Extract the Nth field run ("[____]" / "[value___]") from a layout dump as
# "x width right" in PIXELS. A field segment's glyph run is monospace, so its
# pixel width is len * CELL_W (8).
field_geom() {   # dump nth  -> "x w right"
    python3 - "$1" "$2" <<'PY'
import re, sys
want = int(sys.argv[2]); n = 0
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r'SEG (\d+) (-?\d+) .*?\|(.*)\|\s*$', line.rstrip("\n"))
    if not m:
        continue
    x, t = int(m.group(2)), m.group(3)
    if "___" not in t:
        continue
    if n == want:
        w = len(t) * 8
        print(x, w, x + w)
        sys.exit(0)
    n += 1
print("-1 -1 -1")
PY
}

VW=1024
D="$OUT/gbox_dump.txt"
"$BIN" "$FIX" "$VW" >"$D" 2>&1 || { echo "[hb-gbox] FAIL: render exited non-zero"; cat "$D"; exit 1; }

read -r QX QW QR <<<"$(field_geom "$D" 0)"
read -r HX HW HR <<<"$(field_geom "$D" 1)"
echo "[hb-gbox] search field : x=$QX w=$QW right=$QR   (chromium: x=221 w=447 right=668)"
echo "[hb-gbox] 50%-of-400px : x=$HX w=$HW right=$HR   (chromium content w=200)"

ck() {  # actual lo hi message
    if [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; then
        echo "[hb-gbox] PASS $4 ($1 in [$2,$3])"
    else
        echo "[hb-gbox] FAIL $4 (got $1, want [$2,$3])"; fail=1
    fi
}

# ---- THE BUG: the box must be ON SCREEN --------------------------------
ck "$QR" 0 "$VW" "the search box's right edge is INSIDE the ${VW}px viewport"
ck "$QX" 0 "$VW" "its left edge is inside the viewport"

# ---- WIDTH pinned to Chrome's computed value ---------------------------
# Chrome: 447px. The engine lays text on an 8px monospace grid, so the field
# quantises to a whole number of cells; +-12% brackets the grid error without
# admitting the 1008px bug (which is +125%) or a collapse to nothing.
ck "$QW" 393 501 "the search box is ~447px wide, like Chrome"

# ---- CENTRED, like `margin:0 auto` -------------------------------------
# Chrome leaves 221px to the left and 1024-668 = 356px to the right (the mic /
# lens cluster sits inside the container to the right of the field), so the
# CONTAINER is what is centred. Assert the container's own centring: the field
# starts well right of the page margin instead of hugging it.
ck "$QX" 150 300 "the box is centred, not flush against the left margin"

# ---- the plain case: 50% of a 400px containing block = 200px -----------
ck "$HW" 190 216 "width:50% inside a width:400px parent computes ~200px"

# ---- REGRESSION GUARD: the exact shape of the original bug -------------
if [ "$QW" -ge 900 ]; then
    echo "[hb-gbox] FAIL percentage width regressed to the PAGE column ($QW px)"; fail=1
else
    echo "[hb-gbox] PASS percentage width is not the page column"
fi

# ---- the REAL captured homepage still lays its field out on screen -----
DR="$OUT/gbox_real.txt"
"$BIN" "$REAL" "$VW" >"$DR" 2>&1 || { echo "[hb-gbox] FAIL: real google render exited non-zero"; fail=1; }
read -r RX RW RR <<<"$(field_geom "$DR" 0)"
echo "[hb-gbox] realsites/google_home.html field : x=$RX w=$RW right=$RR (chromium: x=246 w=514 right=760)"
ck "$RR" 0 "$VW" "the real google.com search field is inside the viewport"
ck "$RW" 440 590 "the real google.com search field is ~514px wide, like Chrome"

if [ "$fail" -ne 0 ]; then echo "[hb-gbox] RESULT: FAIL"; exit 1; fi
echo "[hb-gbox] RESULT: PASS"
exit 0
