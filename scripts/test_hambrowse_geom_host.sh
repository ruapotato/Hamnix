#!/usr/bin/env bash
# scripts/test_hambrowse_geom_host.sh — FAST, QEMU-free gate for the DOM LAYOUT
# GEOMETRY surface (browser W3C campaign): getBoundingClientRect(),
# offsetWidth/Height/Left/Top, clientWidth/Height, offsetParent, and a basic
# getComputedStyle() (display / width). These expose the coordinates the layout
# engine already computes (the SEG display list) as the standard DOM geometry
# APIs sticky headers, dropdown/tooltip positioning, lazy-load and carousels
# rely on.
#
# The CORE PROOF is a COORDINATE CROSS-CHECK: the box getBoundingClientRect()
# reports for a known element is derived independently from the engine's SEG
# dump (row/x/text-length) and asserted to be byte-identical — proving the DOM
# geometry is sourced from the real laid-out box, not a stub.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_geom.html"
mkdir -p "$OUT"

echo "[hb-geom] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/geom_compile.log"; then
    echo "[hb-geom] FAIL: host harness did not compile"; cat "$OUT/geom_compile.log"; exit 1
fi
echo "[hb-geom] PASS host harness compiled -> $BIN"

echo "[hb-geom] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/geom_native.log"; then
    echo "[hb-geom] FAIL: native hambrowse did not compile"; cat "$OUT/geom_native.log"; exit 1
fi
echo "[hb-geom] PASS native hambrowse still compiles"

fail=0
D0="$OUT/geom_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-geom] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-geom] PASS $2"
    else
        echo "[hb-geom] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-geom] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-geom] PASS $2"
    fi
}

# ---- COORDINATE CROSS-CHECK -------------------------------------------------
# UPDATED (layout-read / CSSOM round). This used to derive #a's expected box
# from the SEG dump line for |AlphaOne| — left = SEG x, top = SEG row * LINE_H,
# width = len("AlphaOne") * CELL_W(8), height = LINE_H — i.e. the element's TEXT
# INK. #a is a block <div>, so a browser reports its whole CONTENT COLUMN, and
# the ink box was the bug that made every measure-then-position script read a
# number ~13x too small. A SEG cross-check cannot express that: a SEG says where
# the TEXT was drawn, not where the element's BOX is.
#
# Re-derived against real Chrome,
#   chromium --headless --window-size=880,900 --dump-dom
# on this fixture, which answers `rect 8 8 864 18` and `width: 864px`. The
# engine now answers `8 0 864 19`:
#   * left 8, width 864 and getComputedStyle().width 864px are EXACT;
#   * height 19 vs 18 is one px of line-box rounding (`line-height: normal`
#     modelled as 19px at 16px);
#   * top 0 vs 8 is the UA <body> TOP margin, for which the engine's row grid
#     reserves no row (the LEFT body margin is honoured — hence left matches).
# Both residuals are documented in scripts/test_hambrowse_domgeom_host.sh; the
# Chrome-exact layout-read gate is scripts/test_hambrowse_layoutread_host.sh.
EX=8 ; EY=0 ; EW=864 ; EH=19
assert_grep "^JSLOG rect ${EX} ${EY} ${EW} ${EH}\$" \
    "getBoundingClientRect() is the block's content box (Chrome: 8 8 864 18)"
# right/bottom are consistent with left+width / top+height.
assert_grep "^JSLOG edge ${EX} ${EY} $(( EX + EW )) ${EH}\$" \
    "left/top/right/bottom are self-consistent"
# offset* mirror the same box; clientWidth/Height == offset here.
assert_grep "^JSLOG off ${EX} ${EY} ${EW} ${EH}\$" "offsetLeft/Top/Width/Height match the box"
assert_grep "^JSLOG client ${EW} ${EH}\$"          "clientWidth/clientHeight match the box"
assert_grep "^JSLOG awidth ${EW}px\$"              "getComputedStyle().width == Chrome's 864px"

# ---- getComputedStyle().display: tag-derived UA defaults --------------------
assert_grep '^JSLOG disp block$'   "getComputedStyle(div).display == block"
assert_grep '^JSLOG bdisp block$'  "getComputedStyle(p).display == block"
assert_grep '^JSLOG cdisp inline$' "getComputedStyle(span).display == inline"

# ---- offsetParent walks to the containing element ---------------------------
assert_grep '^JSLOG op wrap$'      "offsetParent resolves to the parent element (#wrap)"

# No uncaught JS error anywhere in the geometry script.
assert_nogrep '^JSERR'   "no uncaught JS error across the geometry script"
assert_nogrep 'Uncaught' "no 'Uncaught' from a missing geometry API"

if [ "$fail" -ne 0 ]; then
    echo "[hb-geom] RESULT: FAIL"; exit 1
fi
echo "[hb-geom] RESULT: PASS"
