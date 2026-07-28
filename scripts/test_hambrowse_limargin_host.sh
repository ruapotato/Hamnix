#!/usr/bin/env bash
# scripts/test_hambrowse_limargin_host.sh — FAST, QEMU-free gate pinning the
# LIST-ITEM author-margin fix in the layout engine (lib/web/dom/forms.ad).
#
# CSS rule: Chrome lays each <li> out as a block, so an author `margin-bottom`
# (or `margin-top`) on the list items SPACES them vertically. Before this fix the
# <li> open path emitted only a bare `_soft_newline()` and DROPPED the authored
# margin entirely — every list packed at the tight line pitch, HALVING the
# vertical rhythm of every list-driven page (link indexes, nav menus, article
# lists; measured on the danluu blog `li{display:flex;margin:0 0 .9em}`).
#
# The engine now emits the inter-item gap (collapse of the previous item's
# margin-bottom and this item's margin-top) between the 2nd+ siblings, quantised
# to whole rows like every other vertical margin. On the fixed 16px row grid:
#   * spaced  li{margin:0 0 32px}            -> 2 blank rows between items (32/16)
#   * flexrow li{display:flex;margin:0 0 32px}-> 2 blank rows (flex item honoured)
#   * tight   li{margin:0}                    -> 0 blank rows (control, stays flush)
# Each item is one line, so item-to-item row delta = 1 (line) + gap rows.
#
# Built with the frozen Python seed compiler (compiles 100% of the tree). PNG-free.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_li_margin.html"
DUMP="$OUT/limargin_dump.txt"
mkdir -p "$OUT"

echo "[hb-lim] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/limargin_compile.log"; then
    echo "[hb-lim] FAIL: host harness did not compile"; cat "$OUT/limargin_compile.log"; exit 1
fi
echo "[hb-lim] PASS host harness compiled"

echo "[hb-lim] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/limargin_native.log"; then
    echo "[hb-lim] FAIL: native hambrowse did not compile"; cat "$OUT/limargin_native.log"; exit 1
fi
echo "[hb-lim] PASS native hambrowse still compiles"

echo "[hb-lim] running host harness on $FIX ..."
if ! "$BIN" "$FIX" 800 >"$DUMP" 2>&1; then
    echo "[hb-lim] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E "SEG " "$DUMP" | grep -iE "Spaced|Tight|FlexItem"

fail=0

# Row (2nd field of the SEG line) of the FIRST segment whose text contains $1.
row_of() {
    grep -E "SEG " "$DUMP" | grep -m1 -- "$1" | awk '{print $2}'
}

assert_delta() {
    local a="$1" b="$2" want="$3" label="$4"
    local ra rb d
    ra="$(row_of "$a")"; rb="$(row_of "$b")"
    if [ -z "$ra" ] || [ -z "$rb" ]; then
        echo "[hb-lim] FAIL $label — missing segment(s) ('$a'=$ra '$b'=$rb)"; fail=1; return
    fi
    d=$((rb - ra))
    if [ "$d" -eq "$want" ]; then
        echo "[hb-lim] PASS $label — item delta ${d} rows (row ${ra} -> ${rb})"
    else
        echo "[hb-lim] FAIL $label — item delta ${d} rows, want ${want} (row ${ra} -> ${rb})"; fail=1
    fi
}

# spaced list: 32px bottom margin => 1 line + 2 gap rows = 3 rows between items.
assert_delta "SpacedOne" "SpacedTwo"   3 "block li margin-bottom:32px spaces items"
assert_delta "SpacedTwo" "SpacedThree" 3 "block li margin uniform down the list"
# control: margin:0 => items flush, 1 row apart. Proves the assertion measures
# the feature (had the margin been ignored, spaced would ALSO be 1).
assert_delta "TightOne" "TightTwo"     1 "li{margin:0} keeps items flush (control)"
# flex list item honours its block margin too (the danluu pattern).
assert_delta "FlexItemOne" "FlexItemTwo" 3 "display:flex li honours margin-bottom"

if [ "$fail" -ne 0 ]; then
    echo "[hb-lim] RESULT: FAIL"; exit 1
fi
echo "[hb-lim] RESULT: PASS"
