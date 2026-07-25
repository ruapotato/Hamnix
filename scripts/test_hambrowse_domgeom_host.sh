#!/usr/bin/env bash
# scripts/test_hambrowse_domgeom_host.sh — FAST, QEMU-free INTEGRATION gate that
# ties the DOM geometry + traversal surface together in one fixture (browser W3C
# campaign). Prior rounds landed the pieces separately (gates `matches`, `qsa`,
# `domcore`, `geom`, `domgeom2`); this gate proves they cooperate on one page:
#   (1) Element.matches(selector)  — class / compound / id / negative.
#   (2) Element.closest(selector)  — walks self-or-ancestor to a #id / .class,
#       the ubiquitous event-delegation helper (e.target.closest('.item')).
#   (3) document.body / documentElement / head resolve to the real <body>/<html>/
#       <head> element nodes (spec-uppercase tagName).
#   (4) getBoundingClientRect()/offsetWidth/Height/clientWidth/Height read the
#       element's real CSS BORDER BOX.
#
#       UPDATED (layout-read / CSSOM round): these used to be pinned to the
#       element's TEXT INK — a 9-char word "Rectangle" gave width 72 (9*CELL_W)
#       x height 16 (LINE_H), cross-checked against the SEG display dump. That
#       was the bug, not the contract: #box is a BLOCK <div>, so a browser
#       reports the full content column, and every measure-then-position script
#       reading it got a number ~12x too small. Verified with
#           chromium --headless --window-size=880,900 --dump-dom
#       on this same fixture, Chrome answers `864 x 18 @ (8, 8)`. The engine now
#       answers `864 x 19 @ (8, 0)`:
#         * width 864 and left 8 are EXACT;
#         * height 19 vs 18 is one px of line-box rounding (the engine models
#           `line-height: normal` as 19px at 16px);
#         * top 0 vs 8 is the UA <body> top margin, which the engine's row grid
#           does not reserve a row for (a known residual — the horizontal body
#           margin IS honoured, which is why left matches).
#       See scripts/test_hambrowse_layoutread_host.sh for the full Chrome-exact
#       layout-read gate.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot. Exact-output oracle on console.log lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_domgeom.html"
mkdir -p "$OUT"

echo "[hb-domgeom] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/domgeom_compile.log"; then
    echo "[hb-domgeom] FAIL: host harness did not compile"; cat "$OUT/domgeom_compile.log"; exit 1
fi
echo "[hb-domgeom] PASS host harness compiled -> $BIN"

echo "[hb-domgeom] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/domgeom_native.log"; then
    echo "[hb-domgeom] FAIL: native hambrowse did not compile"; cat "$OUT/domgeom_native.log"; exit 1
fi
echo "[hb-domgeom] PASS native hambrowse still compiles"

fail=0
D0="$OUT/domgeom_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-domgeom] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-domgeom] PASS $2"
    else
        echo "[hb-domgeom] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-domgeom] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-domgeom] PASS $2"
    fi
}

# ---- document roots ------------------------------------------------------
assert_grep '^JSLOG roots HTML BODY HEAD$' \
    "document.documentElement/body/head resolve to <html>/<body>/<head>"

# ---- Element.matches() ---------------------------------------------------
assert_grep '^JSLOG m1 true$'  "matches('.widget') class -> true"
assert_grep '^JSLOG m2 true$'  "matches('div.widget') compound -> true"
assert_grep '^JSLOG m3 true$'  "matches('#box') id -> true"
assert_grep '^JSLOG m4 false$' "matches('.item') negative -> false"
assert_grep '^JSLOG m5 true$'  "matches('.item.selected') compound class -> true"

# ---- Element.closest() ---------------------------------------------------
assert_grep '^JSLOG c1 app$'   "closest('#app') finds far ancestor by id"
assert_grep '^JSLOG c2 panel$' "closest('.panel') finds ancestor by class"
assert_grep '^JSLOG c3 true$'  "closest('.nope') returns null on no match"
assert_grep '^JSLOG c4 first$' "alink.closest('.item') walks up to the enclosing li"

# ---- getBoundingClientRect()/offset*/client* == the real BORDER BOX --------
# #box is a block <div>, so its box is the full content column (Chrome: 864),
# NOT the 72px ink of the word "Rectangle" it happens to contain.
assert_grep '^JSLOG wh 864 19$'  "getBoundingClientRect() is the block box (Chrome: 864x18)"
assert_grep '^JSLOG off 864 19$' "offsetWidth/Height agree with the rect"
assert_grep '^JSLOG cli 864 19$' "clientWidth/Height agree with the rect"
assert_grep '^JSLOG edge true true true true$' \
    "left/top mirror x/y; right/bottom == x+w / y+h"

# ---- x/y ----------------------------------------------------------------
# The block box starts at the body's left margin (8, matching Chrome exactly)
# on the page's first row. This is NO LONGER cross-checked against the SEG dump:
# a SEG is where the element's TEXT was drawn, which for a block element is not
# where its BOX starts (the old check only agreed because the box used to BE the
# ink). offsetLeft/Top mirror the rect.
assert_grep '^JSLOG xy 8 0 8 0$' \
    "getBoundingClientRect() x/y (and offsetLeft/Top) are the block box origin"

# ---- no uncaught error ---------------------------------------------------
assert_nogrep '^JSERR'   "no uncaught JS error across the domgeom script"
assert_nogrep 'Uncaught' "no 'Uncaught' from a missing geometry/traversal API"

if [ "$fail" -ne 0 ]; then
    echo "[hb-domgeom] RESULT: FAIL"; exit 1
fi
echo "[hb-domgeom] RESULT: PASS"
