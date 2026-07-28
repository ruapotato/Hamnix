#!/usr/bin/env bash
# scripts/test_hambrowse_gridpng_host.sh — FAST, QEMU-free CSS-Grid gate that
# verifies layout at the PIXEL level (render-to-PNG), not just SEG coordinates,
# in the native browser engine (lib/web/css/cascade.ad + lib/web/layout/box.ad).
#
# The fixture exercises the common real-web grid subset and one CORRECTNESS fix:
#   (a) 3 equal `1fr 1fr 1fr` columns + column-gap — items must land in three
#       ALIGNED tracks (equal inter-item step) on one row;
#   (b) mixed `200px 1fr` — a fixed rail beside a flexible column that fills the
#       rest (the fr box is much WIDER than the 200px rail);
#   (c) PERCENTAGE tracks `25% 75%` inside a NARROW 300px container — the tracks
#       must resolve against the CONTAINER inline size (col2 origin = col1 + 75px
#       == 25% of 300), NOT the 640px viewport (which would put it near +160).
#       This is the regression guard for the percentage-basis fix.
#
# scripts/hb_grid_probe.py renders the shared dump to a real PNG and LOCATES each
# item box by its background colour in the pixels; this gate asserts on those
# pixel origins/widths. Builds BOTH targets so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_gridpct.html"
PNG="$OUT/gridpct.png"
mkdir -p "$OUT"

echo "[hb-gpng] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/gpng_compile.log"; then
    echo "[hb-gpng] FAIL: host harness did not compile"; cat "$OUT/gpng_compile.log"; exit 1
fi
echo "[hb-gpng] PASS host harness compiled -> $BIN"

echo "[hb-gpng] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/gpng_native.log"; then
    echo "[hb-gpng] FAIL: native hambrowse did not compile"; cat "$OUT/gpng_native.log"; exit 1
fi
echo "[hb-gpng] PASS native hambrowse still compiles"

P="$OUT/gridpct.probe.txt"
if ! python3 scripts/hb_grid_probe.py "$BIN" "$FIX" 640 "$PNG" \
        ff0000,00cc00,0000ff,ffaa00,aa00ff,00cccc,cccc00 >"$P" 2>&1; then
    echo "[hb-gpng] FAIL: probe did not run"; cat "$P"; exit 1
fi
cat "$P"

# helper: field <hex> <key>  ->  integer value from "FOUND #hex ... key=NN ..."
field() { grep -E "FOUND #$1 " "$P" | sed -E "s/.* $2=([0-9]+).*/\1/"; }
present() { grep -qE "FOUND #$1 " "$P"; }

fail=0
for c in ff0000 00cc00 0000ff ffaa00 aa00ff 00cccc cccc00; do
    if ! present "$c"; then echo "[hb-gpng] FAIL: item #$c not painted"; fail=1; fi
done
if [ "$fail" -ne 0 ]; then echo "[hb-gpng] RESULT: FAIL"; exit 1; fi

# ---- (a) three equal fr tracks: equal step, same row --------------------------
rx=$(field ff0000 x); gx=$(field 00cc00 x); bx=$(field 0000ff x)
ry=$(field ff0000 y); gy=$(field 00cc00 y); by=$(field 0000ff y)
s1=$((gx - rx)); s2=$((bx - gx))
echo "[hb-gpng] fr row: red(x$rx y$ry) green(x$gx y$gy) blue(x$bx y$by) steps=$s1/$s2"
if [ "$ry" -ne "$gy" ] || [ "$gy" -ne "$by" ]; then
    echo "[hb-gpng] FAIL: fr items not on one row"; fail=1; fi
d=$((s1 - s2)); [ "$d" -lt 0 ] && d=$((-d))
if [ "$d" -gt 4 ]; then
    echo "[hb-gpng] FAIL: fr track steps unequal ($s1 vs $s2)"; fail=1
else
    echo "[hb-gpng] PASS repeat 1fr 1fr 1fr -> three equal aligned tracks"; fi

# ---- (b) mixed 200px + 1fr: flexible column much wider than the fixed rail -----
dw=$(field ffaa00 w); ew=$(field aa00ff w)
echo "[hb-gpng] mixed: rail w=$dw flex w=$ew"
if [ "$ew" -le "$dw" ]; then
    echo "[hb-gpng] FAIL: fr column not wider than 200px rail"; fail=1
else
    echo "[hb-gpng] PASS '200px 1fr' -> fixed rail + wider flexible column"; fi

# ---- (c) percentage tracks resolve against the 300px CONTAINER, not viewport ---
fx=$(field 00cccc x); ggx=$(field cccc00 x)
step=$((ggx - fx))
echo "[hb-gpng] pct nested: Fff(x$fx) Ggg(x$ggx) step=$step (25% of 300 == 75)"
if [ "$step" -lt 60 ] || [ "$step" -gt 90 ]; then
    echo "[hb-gpng] FAIL: 25% track != 25% of the 300px container (viewport-relative bug?)"; fail=1
else
    echo "[hb-gpng] PASS percentage tracks resolve against the grid container inline size"; fi

if [ "$fail" -ne 0 ]; then echo "[hb-gpng] RESULT: FAIL"; exit 1; fi
echo "[hb-gpng] wrote $PNG"
echo "[hb-gpng] RESULT: PASS"
