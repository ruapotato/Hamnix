#!/usr/bin/env bash
# scripts/test_hambrowse_flexcolstack_host.sh — FAST, QEMU-free gate for
# flex-direction:column BLOCKIFICATION of INLINE-level flex items.
#
# CSS Flexbox §4: every direct child of a flex container is a flex item whose
# `display` is blockified. In a `flex-direction:column` container the items
# therefore STACK vertically (main axis = block axis) and, with the default
# align-items:stretch, span the container's cross (width) extent.
#
# The regression this guards: inline children (a column <nav> of <a> links, a
# vertical <span> tag list) used to flow HORIZONTALLY on ONE row
# ("HomeLinkAboutLinkContactLink") because the column branch fell straight back
# to inline flow and never blockified them. The fix (lib/web/layout/box.ad
# _flex_column_open + the flex_iscol item-open/close branches, lib/web/dom/
# forms.ad) marks the children as flex items so each becomes a full-width block
# on its OWN row. This gate asserts inline column-flex items land on DISTINCT,
# increasing rows at the SAME left x — i.e. they stack, not columnise.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either engine path is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_flexcolstack.html"
mkdir -p "$OUT"

echo "[hb-flexcolstack] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexcolstack] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexcolstack] PASS host harness compiled -> $BIN"

echo "[hb-flexcolstack] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexcolstack] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexcolstack] PASS native hambrowse still compiles"

fail=0
D0="$OUT/flexcolstack.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-flexcolstack] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

seg_row() {   # text -> the row of the SEG carrying it
    grep -E "SEG [0-9]+ [0-9]+ .*\|$1" "$D0" | awk '{print $2}' | head -1
}
seg_x() {     # text -> the x of the SEG carrying it
    grep -E "SEG [0-9]+ [0-9]+ .*\|$1" "$D0" | awk '{print $3}' | head -1
}

# assert three items stack: distinct, strictly-increasing rows at the same x.
check_stack() {   # label a b c
    local lbl="$1" a="$2" b="$3" c="$4"
    local ra rb rc xa xb xc
    ra=$(seg_row "$a"); rb=$(seg_row "$b"); rc=$(seg_row "$c")
    xa=$(seg_x "$a");  xb=$(seg_x "$b");  xc=$(seg_x "$c")
    echo "[hb-flexcolstack] $lbl rows: $a=$ra $b=$rb $c=$rc  x: $xa/$xb/$xc"
    if [ -z "$ra" ] || [ -z "$rb" ] || [ -z "$rc" ]; then
        echo "[hb-flexcolstack] FAIL $lbl: an item did not render"; fail=1; return
    fi
    if [ "$rb" -gt "$ra" ] && [ "$rc" -gt "$rb" ]; then
        echo "[hb-flexcolstack] PASS $lbl items stack on increasing rows"
    else
        echo "[hb-flexcolstack] FAIL $lbl items did NOT stack (rows $ra,$rb,$rc)"; fail=1
    fi
    if [ "$xa" = "$xb" ] && [ "$xb" = "$xc" ]; then
        echo "[hb-flexcolstack] PASS $lbl items share the same left x ($xa)"
    else
        echo "[hb-flexcolstack] FAIL $lbl items x mismatch ($xa,$xb,$xc)"; fail=1
    fi
}

# (1) a column <nav> of inline <a> links stacks vertically.
check_stack "menu" "HomeLink" "AboutLink" "ContactLink"
# (2) a column list of inline <span> tags stacks vertically.
check_stack "tags" "TagAlpha" "TagBeta" "TagGamma"

if [ "$fail" -ne 0 ]; then
    echo "[hb-flexcolstack] RESULT: FAIL"; exit 1
fi
echo "[hb-flexcolstack] RESULT: PASS"
