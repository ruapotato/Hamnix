#!/usr/bin/env bash
# scripts/test_hambrowse_infobox.sh — FAST, QEMU-free regression for a FLOATED
# <table> (the Wikipedia infobox: <table style="float:right">). The engine
# (lib/htmlengine.ad) now measures the table's natural grid width, opens a float
# box of that width pinned to the RIGHT edge, and re-flows the article body on
# its LEFT — the #1 "doesn't look like Wikipedia" gap the last browser rung left.
#
# Renders tests/fixtures/hambrowse_infobox.html via the x86_64-linux host harness
# and asserts the STRUCTURAL property float-tables unlock:
#   * the infobox grid (its <th>/<td> cells + border box) renders at a large seg
#     x (>= 500 px), pinned to the right of the measure;
#   * the FIRST body paragraph (BODYONE) flows at the left margin (x=158) on an
#     EARLY row that also carries infobox content at a large x — i.e. the body
#     wraps beside the float rather than stacking below it;
#   * the trailing paragraph (BODYTHREE) clears below the float at the left.
#
# Pre-fix (float only applied to block containers, not <table>) the infobox
# stacked full-width at the top and BODYONE landed on a LATER row (~11) with no
# co-located large-x seg — the "same early row" assertion below fails. Post-fix
# it passes. Built with the frozen Python seed compiler; no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_infobox.html"
mkdir -p "$OUT"

echo "[hb-infobox] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/infobox_compile.log"; then
    echo "[hb-infobox] FAIL: host harness did not compile"; cat "$OUT/infobox_compile.log"; exit 1
fi
echo "[hb-infobox] PASS host harness compiled -> $BIN"

DUMP="$OUT/infobox_dump.txt"
if ! "$BIN" "$FIX" 900 >"$DUMP" 2>&1; then
    echo "[hb-infobox] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

fail=0
assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then echo "[hb-infobox] PASS $msg"
    else echo "[hb-infobox] FAIL $msg  (/$pat/)"; fail=1; fi
}

# Layout produced content.
assert_grep 'LAYOUT segs=[1-9][0-9]* rows=[1-9][0-9]* ' "layout produced segments/rows"

# --- infobox grid pinned to the RIGHT (large seg x) ------------------
# The bold colspan header cell "Domestic cat" renders at a large x (>= 500).
assert_grep '^SEG [0-9]+ (5|6|7)[0-9][0-9] #[0-9a-f]+ b1 u[0-9] s[0-9] l-1 bg#f8f9fa .Domestic cat.' \
    "float:right infobox header cell pinned to the right edge (large x)"
# A data cell of the infobox grid also lands at a large x, carrying the
# infobox background fill (background-color cascades onto the cell segments).
assert_grep '^SEG [0-9]+ (6|7)[0-9][0-9] #[0-9a-f]+ b0 u[0-9] s[0-9] l-1 bg#f8f9fa .Felidae.' \
    "infobox data cell laid out on the grid at a large x, with its bg fill"
# The float box drew a right border bar span (the '+---+' rule of the box).
assert_grep '^SEG [0-9]+ (5|6|7)[0-9][0-9] #[0-9a-f]+ b0 u[0-9] s[0-9] l-1 bg- .\+-+\+.' \
    "floated table drew its box border"

# --- body wraps on the LEFT of the float on an EARLY row -------------
# BODYONE flows at the left margin on row 2 — the SAME early row the infobox
# occupies (proving beside-flow, not a stack below the table).
#
# The x was 158 and that was WRONG, not the engine. MEASURED in chromium
# --headless at this gate's own 900px width (getBoundingClientRect on every <p>
# of the fixture):
#     BODYONE@8,66.4  BODYTWO@8,136.4  BODYTHREE@8,188.4  TABLE@731.6,66.4 w160.4
# A float:right does not indent the body's LEFT edge at all — every paragraph
# starts at the 8px body margin, which is exactly what the engine emits. The
# regexes also predate the `s<0|1>` strike-through field the SEG dump gained,
# which is why all five of these assertions failed on lines that satisfy every
# condition their own comments describe. Re-measured 2026-07-28.
assert_grep '^SEG 2 8 #[0-9a-f]+ b0 u0 s[0-9] l-1 bg- .BODYONE' \
    "first body paragraph flows on the LEFT of the infobox, same early row"
# The infobox has content at a large x on that same early band (rows 2-4).
assert_grep '^SEG [234] (5|6|7)[0-9][0-9] ' \
    "infobox content co-occurs with the body on the early rows"

# --- trailing paragraph clears below the float at the left -----------
assert_grep '^SEG 1[0-9] 8 #[0-9a-f]+ b0 u0 s[0-9] l-1 bg- .BODYTHREE' \
    "paragraph after the float clears below it at the left margin"

if [ "$fail" = 0 ]; then
    echo "[hb-infobox] RESULT: PASS"; exit 0
else
    echo "[hb-infobox] RESULT: FAIL"; exit 1
fi
