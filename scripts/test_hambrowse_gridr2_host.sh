#!/usr/bin/env bash
# scripts/test_hambrowse_gridr2_host.sh — FAST, QEMU-free gate for the CSS GRID
# ROUND-2 track functions in the native browser engine cascade
# (lib/web/css/cascade.ad):
#
#   (A) minmax(MIN, MAX) tracks — `grid-template-columns: minmax(150px,1fr) 1fr
#       1fr` pins the first rail to its 150px MIN floor (fixed, narrower) beside
#       two flexible fr tracks (wider), so the first column step is smaller than
#       the fr step.
#   (B) repeat(auto-fill, minmax(120px,1fr)) — the responsive column count is
#       derived from the container inline size / the 120px min track, laying the
#       8 items out 4-per-row across two rows (at a viewport of 640).
#
# Asserts on ACTUAL engine layout coordinates (item column x-positions + row
# wrapping), NOT on echo. Builds BOTH targets so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_gridr2.html"
mkdir -p "$OUT"

echo "[hb-gridr2] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-gridr2] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-gridr2] PASS host harness compiled -> $BIN"

echo "[hb-gridr2] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-gridr2] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-gridr2] PASS native hambrowse still compiles"

fail=0
D="$OUT/gridr2.txt"
"$BIN" "$FIX" 640 >"$D" 2>&1 || { echo "[hb-gridr2] FAIL: render exited non-zero"; cat "$D"; exit 1; }

seg_row() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }
seg_x()   { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $3}' | head -1; }

# ---- (A) minmax(150px,1fr) fixed floor beside two fr tracks -------------------
ur=$(seg_row Uno);  ux=$(seg_x Uno)
dr=$(seg_row Dos);  dx=$(seg_x Dos)
tr=$(seg_row Tres); tx=$(seg_x Tres)
echo "[hb-gridr2] minmax row: Uno(r$ur x$ux) Dos(r$dr x$dx) Tres(r$tr x$tx)"
mmstep=$((dx - ux))     # fixed 150px rail step
frstep=$((tx - dx))     # fr track step
echo "[hb-gridr2] minmax steps: rail=$mmstep fr=$frstep (expect rail < fr)"
if [ -n "$ur" ] && [ "$ur" = "$dr" ] && [ "$dr" = "$tr" ] && \
   [ "$ux" -lt "$dx" ] && [ "$dx" -lt "$tx" ] && \
   [ "$mmstep" -ge 150 ] && [ "$mmstep" -lt "$frstep" ]; then
    echo "[hb-gridr2] PASS minmax(150px,1fr) pins a fixed 150px rail narrower than the fr tracks"
else
    echo "[hb-gridr2] FAIL minmax track geometry (rail=$mmstep fr=$frstep rows u$ur d$dr t$tr)"; fail=1
fi

# ---- (B) repeat(auto-fill, minmax(120px,1fr)) -> 5 columns / row --------------
# RE-PINNED 2026-07-27 from 4 columns to 5. auto-fill's track count is
# floor(container / min-track), and the container is now the FULL body content
# width (624px at this gate's 640px viewport) rather than the old ~584px centred
# "readable measure" strip — 624/120 = 5, where 584/120 = 4. `chromium
# --headless` at window width 640 reports five .afc boxes of w=124.8 at
# x = 8 / 132.8 / 257.6 / 382.4 / 507.2 on the first row, with Item6..Item8
# wrapping to x = 8 / 132.8 / 257.6 on the second. The engine lays out
# 8 / 136 / 264 / 392 / 520 then wraps Item6..Item8 to 8 / 136 / 264 — the same
# 5-column grid.
i1r=$(seg_row Item1); i1x=$(seg_x Item1)
i2r=$(seg_row Item2); i2x=$(seg_x Item2)
i4r=$(seg_row Item4); i4x=$(seg_x Item4)
i5r=$(seg_row Item5); i5x=$(seg_x Item5)
i6r=$(seg_row Item6); i6x=$(seg_x Item6)
i7r=$(seg_row Item7); i7x=$(seg_x Item7)
echo "[hb-gridr2] autofill row0: I1(r$i1r x$i1x) I2(r$i2r x$i2x) I4(r$i4r x$i4x) I5(r$i5r x$i5x)"
echo "[hb-gridr2] autofill row1: I6(r$i6r x$i6x) I7(r$i7r x$i7x)"
# (B1) five items share the first row, the sixth wraps to a new row.
if [ -n "$i1r" ] && [ "$i1r" = "$i2r" ] && [ "$i2r" = "$i4r" ] && \
   [ "$i4r" = "$i5r" ] && [ -n "$i6r" ] && [ "$i6r" -gt "$i1r" ]; then
    echo "[hb-gridr2] PASS auto-fill computed 5 columns (Item6 wraps to row 2)"
else
    echo "[hb-gridr2] FAIL auto-fill column count (rows i1$i1r i2$i2r i4$i4r i5$i5r i6$i6r)"; fail=1
fi
# (B2) the column x-positions repeat down rows (Item1 over Item6, Item2 over Item7).
if [ "$i1x" = "$i6x" ] && [ "$i2x" = "$i7x" ] && [ "$i1x" -lt "$i4x" ]; then
    echo "[hb-gridr2] PASS auto-fill track columns reused across rows (col0=$i1x col1=$i2x)"
else
    echo "[hb-gridr2] FAIL auto-fill columns not reused (i1$i1x i2$i2x i6$i6x i7$i7x)"; fail=1
fi
# (B3) equal auto-fill tracks -> uniform column spacing.
afsp=$((i2x - i1x))
echo "[hb-gridr2] autofill col spacing=$afsp (expect >=120)"
if [ "$afsp" -ge 120 ]; then
    echo "[hb-gridr2] PASS auto-fill tracks sized from the 120px min ($afsp px steps)"
else
    echo "[hb-gridr2] FAIL auto-fill track width ($afsp)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-gridr2] RESULT: FAIL"; exit 1
fi
echo "[hb-gridr2] RESULT: PASS"
