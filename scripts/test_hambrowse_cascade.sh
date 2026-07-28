#!/usr/bin/env bash
# scripts/test_hambrowse_cascade.sh — FAST, QEMU-free gate for the CSS cascade
# tiebreak + specificity rules in lib/htmlengine.ad, rendered through the SAME
# parse+layout engine compiled for x86_64-linux (user/hambrowse_host.ad).
#
# It pins down four cascade invariants against tests/fixtures/hambrowse_cascade.html:
#   (1) SOURCE ORDER — two equal-specificity class rules that set the SAME
#       conflicting property resolve by source order, LATER wins, PER property:
#       `.base{color:blue;font-weight:normal}` then `.hot{color:red;bold}` on
#       class="base hot" -> the element is RED + BOLD (not blue).
#   (2) #id BEATS .class regardless of source order: `#idwin{green}` before
#       `.cwin{red}` on id=idwin class=cwin -> GREEN.
#   (3) INLINE beats stylesheet: style="color:purple" over `.cwin{red}` -> PURPLE.
#   (4) MULTI-CLASS compound `.a.b` requires BOTH classes (and carries spec 20):
#       class="b" alone must NOT match `.a.b` (falls through to `.b{blue}` -> BLUE,
#       NOT the `.a.b{red}`); class="a b" matches `.a.b` and its spec 20 beats the
#       later `.b{blue}` spec 10 -> RED. Before the fix `.a.b` stored only the last
#       class, so class="b" wrongly matched `.a.b` (over-match) and painted red.
#
# The seg dump line format is:  SEG <row> <x> #rrggbb b<0|1> ... |text|
# so #rrggbb is the painted colour and b1 marks bold.
#
# Built with the frozen Python seed compiler; no QEMU, no boot.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_cascade.html"
mkdir -p "$OUT"
fail=0

echo "[hb-cascade] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/cascade_compile.log"; then
    echo "[hb-cascade] FAIL: host harness did not compile"
    cat "$OUT/cascade_compile.log"; exit 1
fi
echo "[hb-cascade] PASS host harness compiled -> $BIN"

echo "[hb-cascade] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/cascade_native.elf" 2>"$OUT/cascade_native.log"; then
    echo "[hb-cascade] FAIL: native hambrowse did not compile"
    cat "$OUT/cascade_native.log"; exit 1
fi
echo "[hb-cascade] PASS native hambrowse still compiles"

SEG="$OUT/cascade_seg.txt"
"$BIN" "$FIX" 600 >"$SEG" 2>&1 || { echo "[hb-cascade] FAIL: render"; cat "$SEG"; exit 1; }
echo "---- painted segments ----"; grep -E '^SEG' "$SEG" | grep -iE 'conflict|idbeats|inlinebeats|onlyB|bothAB'

assert_grep() { # <regex> <label>
    if grep -Eiq -- "$1" "$SEG"; then echo "[hb-cascade] PASS $2"
    else echo "[hb-cascade] FAIL $2  (/$1/ expected)"; fail=1; fi
}
refute_grep() { # <regex> <label>
    if grep -Eiq -- "$1" "$SEG"; then echo "[hb-cascade] FAIL $2  (/$1/ unexpected)"; fail=1
    else echo "[hb-cascade] PASS $2"; fi
}

# (1) later equal-specificity class wins the conflicting property (RED + BOLD)
assert_grep 'SEG .*#ff0000 b1 .*\|conflict\|' \
    "later .hot wins color+weight -> RED + BOLD (source-order tiebreak)"
refute_grep 'SEG .*#0000ff .*\|conflict\|' \
    "control: .base blue did NOT survive the conflict"

# (2) #id beats .class regardless of source order (GREEN)
assert_grep 'SEG .*#008000 .*\|idbeatsclass\|' \
    "#id (green) beats .class (red) -> specificity over source order"

# (3) inline style beats stylesheet (PURPLE)
assert_grep 'SEG .*#800080 .*\|inlinebeats\|' \
    "inline style=color:purple beats .class red"

# (4) multi-class compound requires BOTH classes
refute_grep 'SEG .*#ff0000 .*\|onlyB\|' \
    "control: class=\"b\" alone does NOT match .a.b (no over-match)"
assert_grep 'SEG .*#0000ff .*\|onlyB\|' \
    "class=\"b\" falls through to .b -> BLUE"
assert_grep 'SEG .*#ff0000 .*\|bothAB\|' \
    "class=\"a b\" matches .a.b, spec 20 beats later .b spec 10 -> RED"

if [ "$fail" -eq 0 ]; then
    echo "[hb-cascade] PASS"
else
    echo "[hb-cascade] FAIL"; exit 1
fi
