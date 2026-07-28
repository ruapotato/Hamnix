#!/usr/bin/env bash
# scripts/test_hambrowse_domgeom2_host.sh — FAST, QEMU-free gate for the SECOND
# wave of DOM layout-geometry conformance (browser W3C campaign):
#   (1) VIEWPORT-RELATIVE getBoundingClientRect() — the returned rect is the
#       document box MINUS the current page scroll offset, so scrolling the
#       viewport (document.documentElement.scrollTop/Left) shifts the rect by the
#       scroll amount, per CSSOM-View.
#   (2) getClientRects() — returns a DOMRectList (array) whose single entry is the
#       element's viewport-relative bounding rect, honouring the same scroll.
#   (3) EXPANDED getComputedStyle() — padding / margin / font-size /
#       background-color resolved values (UA defaults, with an inline style.<prop>
#       the script set winning), readable under both camelCase and kebab names.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_domgeom2.html"
mkdir -p "$OUT"

echo "[hb-domgeom2] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/domgeom2_compile.log"; then
    echo "[hb-domgeom2] FAIL: host harness did not compile"; cat "$OUT/domgeom2_compile.log"; exit 1
fi
echo "[hb-domgeom2] PASS host harness compiled -> $BIN"

echo "[hb-domgeom2] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/domgeom2_native.log"; then
    echo "[hb-domgeom2] FAIL: native hambrowse did not compile"; cat "$OUT/domgeom2_native.log"; exit 1
fi
echo "[hb-domgeom2] PASS native hambrowse still compiles"

fail=0
D0="$OUT/domgeom2_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-domgeom2] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-domgeom2] PASS $2"
    else
        echo "[hb-domgeom2] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-domgeom2] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-domgeom2] PASS $2"
    fi
}

# ---- Baseline box = the element's real CSS BORDER BOX ----------------------
# UPDATED (layout-read / CSSOM round). This used to derive the expected rect
# from the SEG dump for |AlphaOne| — 8 chars * CELL_W = 64 wide, LINE_H tall —
# i.e. the element's TEXT INK. #a is a block <div>, so a browser reports the
# whole content column instead. Verified against
#   chromium --headless --window-size=880,900 --dump-dom
# on this fixture, Chrome answers `left 8, width 864`; the engine now answers
# left 8 / width 864 EXACTLY. (Chrome's top 8 vs the engine's 0 is the UA <body>
# top margin the row grid reserves no row for; its height differs by the line-box
# rounding — both are the known residuals documented in
# scripts/test_hambrowse_domgeom_host.sh and the Chrome-exact
# scripts/test_hambrowse_layoutread_host.sh.)
BX=8 ; BY=0 ; BW=864 ; BH=19
assert_grep "^JSLOG base ${BX} ${BY} ${BW} ${BH}\$" \
    "unscrolled getBoundingClientRect() == the element's block box"

# ---- getClientRects(): one-entry list, holding the bounding rect ---------
assert_grep '^JSLOG rects 1$' "getClientRects().length == 1 (single fragment)"
assert_grep "^JSLOG rl0 ${BX} ${BY} ${BW} ${BH}\$" \
    "getClientRects()[0] == the bounding rect"

# ---- viewport-relative: scroll(10,40) shifts the rect UP/LEFT by that -----
# This is the property the gate really guards: whatever the box is, scrolling
# translates it by exactly the scroll offset (CSSOM-View).
SCX=$(( BX - 10 ))
SCY=$(( BY - 40 ))
assert_grep "^JSLOG scrolled ${SCX} ${SCY} ${BW} ${BH}\$" \
    "after scrollTop=40/scrollLeft=10, rect is offset by the scroll amount"
assert_grep '^JSLOG delta 10 40$' \
    "rect delta equals exactly the (scrollLeft, scrollTop) applied"
assert_grep "^JSLOG srect0 ${SCX} ${SCY}\$" \
    "getClientRects() honours the same scroll translation"

# ---- Expanded getComputedStyle resolved properties --------------------------
assert_grep '^JSLOG pad 0px$'                "getComputedStyle().padding default resolves to 0px"
assert_grep '^JSLOG mar 0px$'                "getComputedStyle().margin default resolves to 0px"
assert_grep '^JSLOG fs 16px$'                "getComputedStyle().fontSize default resolves to 16px"
assert_grep '^JSLOG bg rgba\(0, 0, 0, 0\)$'  "getComputedStyle().backgroundColor default is transparent"
# An inline style the script set wins over the UA default.
assert_grep '^JSLOG bg2 rgb\(255, 0, 0\)$'   "inline style.backgroundColor resolves to rgb() in getComputedStyle() (CSSOM resolved value)"
assert_grep '^JSLOG fs2 22px$'               "inline style.fontSize wins in getComputedStyle()"

# No uncaught JS error anywhere in the script.
assert_nogrep '^JSERR'   "no uncaught JS error across the domgeom2 script"
assert_nogrep 'Uncaught' "no 'Uncaught' from a missing geometry API"

if [ "$fail" -ne 0 ]; then
    echo "[hb-domgeom2] RESULT: FAIL"; exit 1
fi
echo "[hb-domgeom2] RESULT: PASS"
