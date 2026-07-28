#!/usr/bin/env bash
# scripts/test_hambrowse_gridflow_host.sh — FAST, QEMU-free gate for CSS
# `grid-auto-flow` (dense packing + column-major flow) in the native browser
# engine (lib/web/css/cascade.ad + lib/web/dom/forms.ad + lib/web/layout/box.ad).
#
# grid-auto-flow: dense  — an auto-placed item BACKFILLS an earlier hole a wider
#   sibling left, instead of only advancing forward from the flow cursor.
# grid-auto-flow: column — items fill DOWN a column (rows 0..N) before moving to
#   the next column (the transpose of the default row-major flow).
#
# The fixture (tests/fixtures/hambrowse_gridflow.html) lays out FOUR 3/2-column
# grids that differ ONLY by grid-auto-flow, and the gate asserts on ACTUAL engine
# layout coordinates (item row/x), NOT on echo:
#   * Sparse grid  Asp(span2) Bsp(span2) Csing : Bsp can't fit the 1 free cell on
#     row0, so it wraps to row1 and the trailing single follows the cursor onto
#     row1 -> Csing.row == Bsp.row  (a hole is LEFT at row0,col2).
#   * Dense grid   Adn(span2) Bdn(span2) Cdn   : identical BUT grid-auto-flow:dense
#     -> Cdn BACKFILLS the hole -> Cdn.row == Adn.row (row0), NOT Bdn's row.
#   * Rowflow grid R1..R4 : row-major -> R1,R2 share a row (R2.x > R1.x),
#     R3,R4 the next row.
#   * Colflow grid K1..K4 : grid-auto-flow:column -> K1,K2 share a COLUMN
#     (K2.x == K1.x, K2.row > K1.row); K3,K4 the next column.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_gridflow.html"
mkdir -p "$OUT"

echo "[hb-gridflow] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-gridflow] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-gridflow] PASS host harness compiled -> $BIN"

echo "[hb-gridflow] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-gridflow] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-gridflow] PASS native hambrowse still compiles"

fail=0
D="$OUT/gridflow.txt"
"$BIN" "$FIX" 640 >"$D" 2>&1 || { echo "[hb-gridflow] FAIL: render exited non-zero"; cat "$D"; exit 1; }

seg_row() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }
seg_x()   { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $3}' | head -1; }

check() { # desc actual op expected
    local desc="$1" a="$2" op="$3" e="$4"
    if [ -z "$a" ]; then echo "[hb-gridflow] FAIL: $desc — no value"; fail=1; return; fi
    if [ "$op" = "eq" ] && [ "$a" -ne "$e" ]; then echo "[hb-gridflow] FAIL: $desc — got $a want $e"; fail=1; return; fi
    if [ "$op" = "gt" ] && [ "$a" -le "$e" ]; then echo "[hb-gridflow] FAIL: $desc — got $a not > $e"; fail=1; return; fi
    echo "[hb-gridflow] PASS: $desc ($a $op $e)"
}

# ---- sparse vs dense ---------------------------------------------------------
asp=$(seg_row Asp); bsp=$(seg_row Bsp); csp=$(seg_row Csing)
adn=$(seg_row Adn); bdn=$(seg_row Bdn); cdn=$(seg_row Cdn)
echo "[hb-gridflow] sparse: Asp(r$asp) Bsp(r$bsp) Csing(r$csp)"
echo "[hb-gridflow] dense : Adn(r$adn) Bdn(r$bdn) Cdn(r$cdn)"
# Sparse: the single trailing item follows the cursor onto Bsp's row (a hole is
# left on row0). Dense: it backfills row0 with the first grid item.
check "sparse Bsp wraps below Asp"   "$bsp" gt "$asp"
check "sparse single follows cursor" "$csp" eq "$bsp"
check "dense single BACKFILLS row0"  "$cdn" eq "$adn"
check "dense single ABOVE Bdn"       "$bdn" gt "$cdn"

# ---- row-major vs column-major ----------------------------------------------
r1r=$(seg_row R1); r1x=$(seg_x R1); r2r=$(seg_row R2); r2x=$(seg_x R2)
k1r=$(seg_row K1); k1x=$(seg_x K1); k2r=$(seg_row K2); k2x=$(seg_x K2)
echo "[hb-gridflow] rowflow: R1(r$r1r x$r1x) R2(r$r2r x$r2x)"
echo "[hb-gridflow] colflow: K1(r$k1r x$k1x) K2(r$k2r x$k2x)"
# Row flow: 2nd item is to the RIGHT on the SAME row.
check "rowflow R2 same row as R1" "$r2r" eq "$r1r"
check "rowflow R2 right of R1"    "$r2x" gt "$r1x"
# Column flow: 2nd item is BELOW in the SAME column.
check "colflow K2 same x as K1"   "$k2x" eq "$k1x"
check "colflow K2 below K1"       "$k2r" gt "$k1r"

if [ "$fail" -ne 0 ]; then echo "[hb-gridflow] RESULT: FAIL"; exit 1; fi
echo "[hb-gridflow] RESULT: PASS — grid-auto-flow dense + column verified"
