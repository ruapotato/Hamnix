#!/usr/bin/env bash
# scripts/test_hambrowse_flexpadtop_host.sh — FAST, QEMU-free regression gate
# pinning a FLEX ITEM's padding-top.
#
# BUG (fixed): a flex item's content was pinned to the container's cross-start
# (cur_row rewound to flex_top_row) with topg==0 passed to _block_box_open, so
# the item's OWN padding-top (folded into ftop by the cascade's _box_add_t) was
# DROPPED. Chrome insets a `.main{padding:20px..}` docs column 20px below the
# container top; hambrowse put it flush at the top (~1 row too high).
#
# This fixture puts two flex items side by side in one `display:flex` row: a
# control column with NO top padding ("Baseline") and a column with
# padding-top:64px ("Inset", = 4 rows at LINE_H 16). Both share the flex
# cross-start, so a correct engine renders "Inset" SEVERAL rows BELOW "Baseline".
# The pre-fix engine rendered them on the SAME row.
#
# Builds BOTH targets so a break in either the host harness or native hambrowse
# is caught.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_flexpadtop.html"
mkdir -p "$OUT"

echo "[hb-flexpadtop] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexpadtop] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexpadtop] PASS host harness compiled -> $BIN"

echo "[hb-flexpadtop] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexpadtop] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexpadtop] PASS native hambrowse still compiles"

fail=0
D0="$OUT/flexpadtop.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-flexpadtop] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

seg_row() {   # text -> the row of the SEG carrying it
    grep -E "SEG [0-9]+ [0-9]+ .*\|$1" "$D0" | awk '{print $2}' | head -1
}

br=$(seg_row "Baseline")
ir=$(seg_row "Inset")
echo "[hb-flexpadtop] rows: Baseline=$br Inset(padding-top:64px)=$ir"

if [ -z "$br" ] || [ -z "$ir" ]; then
    echo "[hb-flexpadtop] FAIL missing SEG (Baseline=$br Inset=$ir)"; fail=1
elif [ "$ir" -ge "$((br + 3))" ]; then
    # 64px / LINE_H(16) = 4 rows; require >= 3 to tolerate vgap rounding.
    echo "[hb-flexpadtop] PASS flex item honours padding-top (Inset $ir is >= 3 rows below Baseline $br)"
else
    echo "[hb-flexpadtop] FAIL flex item DROPPED padding-top (Inset=$ir not below Baseline=$br)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-flexpadtop] RESULT: FAIL"; exit 1
fi
echo "[hb-flexpadtop] RESULT: PASS"
