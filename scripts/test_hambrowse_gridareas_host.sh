#!/usr/bin/env bash
# scripts/test_hambrowse_gridareas_host.sh — FAST, QEMU-free gate for CSS
# grid-template-areas / grid-area NAMED placement in the native browser engine
# (lib/web/css/cascade.ad + lib/web/layout/box.ad + lib/web/dom/forms.ad).
#
# W3C css-grid §7.3 / §8.5: a `display:grid` container declares a visual map of
# named areas via `grid-template-areas: "head head" "side main" "foot foot"`,
# and each item places itself into a named rectangle with `grid-area: NAME`.
# The named rectangle drives the item's start row/col + row/col spans, so
# `head`/`foot` span the full width while `side`/`main` sit side by side.
#
# The fixture lays out (1) a classic header/sidebar/main/footer page shell
# (grid-template-columns: 150px 1fr; grid-template-rows: 60px 200px 40px) and
# (2) a second grid that declares NO grid-template-columns — its column count is
# derived from the areas template (three equal 1fr tracks). The gate asserts on
# ACTUAL engine layout coordinates (SEG row/x) AND on the rendered PNG pixels
# (each named box paints at its rectangle: full-width band vs the split rail).
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse) so a break
# in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_gridareas.html"
mkdir -p "$OUT"

echo "[hb-gridareas] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-gridareas] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-gridareas] PASS host harness compiled"

echo "[hb-gridareas] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-gridareas] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-gridareas] PASS native hambrowse still compiles"

fail=0
D="$OUT/gridareas.txt"
"$BIN" "$FIX" 640 >"$D" 2>&1 || { echo "[hb-gridareas] FAIL: render exited non-zero"; cat "$D"; exit 1; }

seg_row() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }
seg_x()   { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $3}' | head -1; }

hr=$(seg_row HeaderZ);  hx=$(seg_x HeaderZ)
sr=$(seg_row SidebarZ); sx=$(seg_x SidebarZ)
mr=$(seg_row MainZ);    mx=$(seg_x MainZ)
fr=$(seg_row FooterZ);  fx=$(seg_x FooterZ)
echo "[hb-gridareas] page: head(r$hr x$hx) side(r$sr x$sx) main(r$mr x$mx) foot(r$fr x$fx)"

# (1) header sits on the TOP row, above the side/main band
if [ -n "$hr" ] && [ -n "$sr" ] && [ "$hr" -lt "$sr" ]; then
    echo "[hb-gridareas] PASS 'head' area is on the top row (r$hr < r$sr)"
else
    echo "[hb-gridareas] FAIL head not above side (r$hr vs r$sr)"; fail=1
fi

# (2) side and main share the SAME row (side by side), and main is to the RIGHT
if [ -n "$sr" ] && [ "$sr" = "$mr" ] && [ -n "$mx" ] && [ "$mx" -gt "$sx" ]; then
    echo "[hb-gridareas] PASS 'side'/'main' share a row; main right of side (x$sx | x$mx)"
else
    echo "[hb-gridareas] FAIL side/main not side-by-side (r$sr=$mr x$sx/$mx)"; fail=1
fi

# (3) head, side and foot all start at column 0 (same left x)
if [ "$hx" = "$sx" ] && [ "$sx" = "$fx" ]; then
    echo "[hb-gridareas] PASS head/side/foot share column 0 (x$hx)"
else
    echo "[hb-gridareas] FAIL col-0 items misaligned (h$hx s$sx f$fx)"; fail=1
fi

# (4) footer is BELOW the side/main band
if [ -n "$fr" ] && [ "$fr" -gt "$mr" ]; then
    echo "[hb-gridareas] PASS 'foot' area is below the main band (r$fr > r$mr)"
else
    echo "[hb-gridareas] FAIL foot not below main (r$fr vs r$mr)"; fail=1
fi

# ---- second grid: columns DERIVED from the areas template --------------------
xr=$(seg_row Xarea); xx=$(seg_x Xarea)
yr=$(seg_row Yarea); yx=$(seg_x Yarea)
zr=$(seg_row Zarea); zx=$(seg_x Zarea)
echo "[hb-gridareas] auto: x(r$xr x$xx) y(r$yr x$yx) z(r$zr x$zx)"

# (5) area 'bb' (Yarea) lands in the RIGHT (third) derived column; 'aa'/'cc' left
if [ -n "$yx" ] && [ -n "$xx" ] && [ "$yx" -gt "$xx" ] && [ "$xx" = "$zx" ]; then
    echo "[hb-gridareas] PASS derived 3-col grid: 'bb' at right col, 'aa'/'cc' at left (x$xx | y$yx)"
else
    echo "[hb-gridareas] FAIL derived columns wrong (x$xx y$yx z$zx)"; fail=1
fi

# (6) 'cc' (Zarea) is on the row BELOW 'aa' (Xarea)
if [ -n "$zr" ] && [ -n "$xr" ] && [ "$zr" -gt "$xr" ]; then
    echo "[hb-gridareas] PASS 'cc' area is a row below 'aa' (r$zr > r$xr)"
else
    echo "[hb-gridareas] FAIL cc not below aa (r$zr vs r$xr)"; fail=1
fi

# ---- PIXEL truth: each named box paints at its rectangle ---------------------
PNG="$OUT/gridareas.png"
probe=$(python3 scripts/hb_grid_probe.py "$BIN" "$FIX" 640 "$PNG" \
        112233,227722,aa3344,445566 2>/dev/null)
echo "$probe" | sed 's/^/[hb-gridareas]   /'
# header full-width band; sidebar a narrow rail at x0; main to the right of it
hw=$(echo "$probe" | awk '/#112233/{print $5}' | sed 's/w=//')
sw=$(echo "$probe" | awk '/#227722/{print $5}' | sed 's/w=//')
mxp=$(echo "$probe" | awk '/#aa3344/{print $3}' | sed 's/x=//')
if [ -n "$hw" ] && [ "$hw" -ge 480 ] && [ -n "$sw" ] && [ "$sw" -ge 100 ] && \
   [ "$sw" -le 200 ] && [ -n "$mxp" ] && [ "$mxp" -ge 140 ]; then
    echo "[hb-gridareas] PASS pixels: header spans full width ($hw), side is a rail ($sw), main starts right ($mxp)"
else
    echo "[hb-gridareas] FAIL pixel rectangles (headW=$hw sideW=$sw mainX=$mxp)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-gridareas] ALL PASS — grid-template-areas / grid-area named placement"
    exit 0
fi
echo "[hb-gridareas] FAILURES above"; exit 1
