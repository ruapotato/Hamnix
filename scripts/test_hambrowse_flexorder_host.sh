#!/usr/bin/env bash
# scripts/test_hambrowse_flexorder_host.sh — FAST, QEMU-free gate for CSS `order`
# on flex items + the padded space-between bar, in the native browser engine
# (lib/web/css/cascade.ad + lib/web/layout/box.ad):
#
#   (A) CSS `order` reorders flex items VISUALLY without touching source order.
#       A row whose source is Aaa/Bbb/Ccc with order:3/1/2 paints Bbb, Ccc, Aaa
#       left-to-right (stable sort by order, ties keep DOM order). This drives the
#       responsive-footer / toolbar pattern where `order` repositions items.
#
#   (B) A `justify-content:space-between` bar of two PADDED link groups keeps the
#       left group flush-left and the right group flush-right on the SAME row —
#       the 15px link padding is folded into each item's measured width so the
#       groups hold their distance instead of packing tight / stacking.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_flexorder.html"
mkdir -p "$OUT"

echo "[hb-flexorder] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexorder] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexorder] PASS host harness compiled -> $BIN"

echo "[hb-flexorder] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexorder] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexorder] PASS native hambrowse still compiles"

fail=0
D="$OUT/flexorder.txt"
"$BIN" "$FIX" 800 >"$D" 2>&1 || { echo "[hb-flexorder] FAIL: render exited non-zero"; cat "$D"; exit 1; }

seg_x() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $3}' | head -1; }

# ---- (A) order permutation --------------------------------------------------
ax=$(seg_x Aaa); bx=$(seg_x Bbb); cx=$(seg_x Ccc)
echo "[hb-flexorder] order row x: Aaa(o3)=$ax Bbb(o1)=$bx Ccc(o2)=$cx"
if [ -n "$ax" ] && [ -n "$bx" ] && [ -n "$cx" ] && \
   [ "$bx" -lt "$cx" ] && [ "$cx" -lt "$ax" ]; then
    echo "[hb-flexorder] PASS order paints Bbb<Ccc<Aaa (source Aaa/Bbb/Ccc reordered by CSS order)"
else
    echo "[hb-flexorder] FAIL order did not permute items (Bbb=$bx Ccc=$cx Aaa=$ax)"; fail=1
fi

# ---- (B) padded space-between bar -------------------------------------------
lx=$(seg_x Advertising); rx=$(seg_x Privacy); sx=$(seg_x Settings)
echo "[hb-flexorder] bar x: left(Advertising)=$lx right(Privacy)=$rx right(Settings)=$sx"
if [ -n "$lx" ] && [ -n "$rx" ] && [ "$lx" -lt 150 ] && [ "$rx" -gt 500 ]; then
    echo "[hb-flexorder] PASS space-between keeps left group flush-left, right group flush-right (no stacking)"
else
    echo "[hb-flexorder] FAIL space-between padded groups collapsed (left=$lx right=$rx)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-flexorder] RESULT: FAIL"; exit 1
fi
echo "[hb-flexorder] RESULT: PASS"
