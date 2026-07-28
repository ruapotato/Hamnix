#!/usr/bin/env bash
# scripts/test_hambrowse_float.sh — FAST, QEMU-free regression for CSS `float`
# (left/right) block layout in the hambrowse engine (lib/htmlengine.ad), plus
# the page-<title> entity decode / no-script title scan.
#
# Renders tests/fixtures/hambrowse_float.html via the x86_64-linux host harness
# and asserts the STRUCTURAL properties float unlocks:
#   * a `float:right` infobox is pinned to the RIGHT of the measure (large seg x)
#     with its border + background, while the body paragraph flows on its LEFT
#     (small seg x) on the SAME rows — i.e. text wraps beside the float rather
#     than stacking below it;
#   * a `float:left` figure pushes the following paragraph's left edge to the
#     RIGHT (indented seg x) beside it;
#   * the <title> "&mdash;" entity decodes to an em dash and is exposed even
#     though the page has no <script>.
#
# Pre-fix (no float support) every block stacked full-width at the left margin,
# so the infobox text sat at the left on a row ABOVE the body — the right-side
# and indented-x assertions below fail. Post-fix they pass.
#
# Built with the frozen Python seed compiler (compiles 100% of the tree), so
# this gate is dependency-light and needs no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_float.html"
mkdir -p "$OUT"

echo "[hb-float] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/float_compile.log"; then
    echo "[hb-float] FAIL: host harness did not compile"; cat "$OUT/float_compile.log"; exit 1
fi
echo "[hb-float] PASS host harness compiled -> $BIN"

echo "[hb-float] running host harness on $FIX ..."
DUMP="$OUT/float_dump.txt"
if ! "$BIN" "$FIX" 900 >"$DUMP" 2>&1; then
    echo "[hb-float] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

fail=0
assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-float] PASS $msg"
    else
        echo "[hb-float] FAIL $msg  (/$pat/)"; fail=1
    fi
}
refute_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-float] FAIL $msg  (/$pat/ unexpectedly present)"; fail=1
    else
        echo "[hb-float] PASS $msg"
    fi
}

# Layout produced content.
assert_grep 'LAYOUT segs=[1-9][0-9]* rows=[1-9][0-9]* ' "layout produced segments/rows"

# --- <title> entity decode + no-script title -------------------------
assert_grep '^TITLE Float layout .* hambrowse'  "no-script page title is exposed"
refute_grep '^TITLE .*&mdash;'                   "title &mdash; entity decoded (no raw entity)"

# --- float:right infobox pinned to the RIGHT of the measure ----------
# INFOBOXTOP renders at a large seg x (>= 500 px) with the infobox background.
assert_grep '^SEG [0-9]+ (5|6|7)[0-9][0-9] #[0-9a-f]+ b1 u[0-9] s[0-9] l-1 bg#ebebd2 .INFOBOXTOP.' \
    "float:right infobox pinned to the right edge (large x) with its bg"

# --- body text wraps to the LEFT of the right float ------------------
# BODYONE flows at the UA left content edge (x=8) on the SAME early row (2) the
# infobox occupies — proving beside-flow, not a stack below it. This matches
# Chrome: for a `float:right`, the following paragraph's left edge stays at the
# left margin (measured Chrome for this fixture at 900px: P.left = 8) and only
# its line-box RIGHT is shortened by the float. (The prior expectation of x=158
# predated the float:right left-edge fix; Chrome puts it at 8.)
assert_grep '^SEG 2 8 #[0-9a-f]+ b0 u0 s[0-9] l-1 bg- .BODYONE' \
    "body paragraph flows on the LEFT of the right float, same top row (x=8, Chrome=8)"

# --- float:left figure indents the following paragraph ---------------
# FIGBOX (float:left width:160) box on the left; BODYTHREE's left edge is pushed
# RIGHT to x=176 (fig 160 + 8 gap + 8 margin) beside it, on the float's top row.
# Measured Chrome for this fixture at 900px: the fig box is x=8..170, so the
# beside text begins at ~170; the engine's 176 matches within a gutter cell.
# (The prior 3xx expectation over-indented; Chrome sits the text at ~170.)
assert_grep '.FIGBOX a tabby cat.'  "float:left figure box rendered"
assert_grep '^SEG [0-9]+ 176 #[0-9a-f]+ b0 u0 s[0-9] l-1 bg- .BODYTHREE' \
    "paragraph after a float:left is indented to its RIGHT (beside it) (x=176, Chrome~170)"

# --- NARROW float:left (< old 48px floor) still floats ----------------
# A 40px `float:left` score box (the lobste.rs voter-score / slim icon-gutter
# pattern) must be taken out of flow so the following headline wraps BESIDE it,
# not stack below. Pre-fix the engine rejected any float narrower than 6 cells
# (48px) and it fell back to a full-width in-flow block, dropping SCORELINE to
# the left margin on a LATER row. Post-fix SCORELINE flows beside at x >= 48.
assert_grep '^SEG [0-9]+ (4[89]|[5-9][0-9]|1[0-9][0-9]) #[0-9a-f]+ b0 u0 s[0-9] l-1 bg- .SCORELINE' \
    "headline flows BESIDE a narrow 40px float:left (not stacked below)"

echo "[hb-float] compiling native hambrowse for x86_64-adder-user (no regress) ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/float_native.log"; then
    echo "[hb-float] FAIL: native hambrowse did not compile"; cat "$OUT/float_native.log"; exit 1
fi
echo "[hb-float] PASS native hambrowse still compiles"

if [ "$fail" = 0 ]; then
    echo "[hb-float] RESULT: PASS"; exit 0
else
    echo "[hb-float] RESULT: FAIL"; exit 1
fi
