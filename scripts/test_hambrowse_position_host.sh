#!/usr/bin/env bash
# scripts/test_hambrowse_position_host.sh — FAST, QEMU-free gate for CSS
# POSITIONING in the native browser engine (lib/htmlengine.ad + lib/htmlpage.ad),
# driven by the pixel backend user/hambrowse_host_gfx.ad. Asserts on STABLE
# background-fill pixels (POSFILL records: each block box's painted pixel rect,
# stacking z, declared colour, and the colour actually sampled inside its
# top-left corner) — not glyph ink — so a regression fails without a QEMU boot.
#
# Coverage proved here:
#   (1) position:relative + top/left — the box's background rect is offset by the
#       given amounts while its in-flow SIBLINGS do not move.
#   (2) position:absolute — placed at the nearest positioned ancestor's origin +
#       top/left; the following in-flow sibling occupies the vacated flow slot
#       (sits at the container origin, ABOVE the out-of-flow absolute boxes).
#   (3) z-index — where two overlapping absolute boxes stack, the higher-z box's
#       colour wins the shared pixel (stable z-sort at paint time).
#
# Builds BOTH the host pixel driver (x86_64-linux) and the native hambrowse
# (x86_64-adder-user) so a break in the shared engine is caught either way.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_position.html"
DUMP="$OUT/pos_dump.txt"
PPM="$OUT/pos.ppm"
PNG="$OUT/pos.png"
mkdir -p "$OUT"
fail=0

echo "[hb-pos] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/pos_compile.log"; then
    echo "[hb-pos] FAIL: driver did not compile"; cat "$OUT/pos_compile.log"; exit 1
fi
echo "[hb-pos] PASS pixel backend compiled -> $BIN"

echo "[hb-pos] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/pos_native.log"; then
    echo "[hb-pos] FAIL: native hambrowse did not compile"; cat "$OUT/pos_native.log"; exit 1
fi
echo "[hb-pos] PASS native hambrowse still compiles"

echo "[hb-pos] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-pos] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^POSFILL|^CANVAS' "$DUMP" || true
python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>/dev/null && \
    echo "[hb-pos] wrote $PNG for eyeballing" || true

# Field extractor: given a declared colour, echo "<x0> <y0> <z> <pix>" for the
# POSFILL line whose `col` matches (POSFILL i z Z x0 X y0 Y x1 X y1 Y col C pix P).
row_for() {
    awk -v c="$1" '$1=="POSFILL" && $14==c {print $6, $8, $4, $16; exit}' "$DUMP"
}

read -r SIB1_X SIB1_Y _ _   < <(row_for '#00aa00')
read -r REL_X  REL_Y  _ _    < <(row_for '#0000ee')
read -r SIB2_X SIB2_Y _ _    < <(row_for '#aa0000')
read -r CONT_X CONT_Y _ _    < <(row_for '#dddddd')
read -r ABS1_X ABS1_Y ABS1_Z ABS1_PIX < <(row_for '#ff8800')
read -r ABS2_X ABS2_Y ABS2_Z ABS2_PIX < <(row_for '#8800ff')
read -r AFT_X  AFT_Y  _ _    < <(row_for '#00cccc')

echo "[hb-pos] sib1=($SIB1_X,$SIB1_Y) rel=($REL_X,$REL_Y) sib2=($SIB2_X,$SIB2_Y)"
echo "[hb-pos] cont=($CONT_X,$CONT_Y) abs1=($ABS1_X,$ABS1_Y,z$ABS1_Z,pix$ABS1_PIX) abs2=($ABS2_X,$ABS2_Y,z$ABS2_Z,pix$ABS2_PIX) after=($AFT_X,$AFT_Y)"

need() { [ -n "$1" ] || { echo "[hb-pos] FAIL: missing box ($2)"; fail=1; return 1; }; return 0; }
for v in "$SIB1_X:sib1" "$REL_X:rel" "$SIB2_X:sib2" "$CONT_X:cont" \
         "$ABS1_X:abs1" "$ABS2_X:abs2" "$AFT_X:after"; do
    need "${v%%:*}" "${v##*:}" || true
done

# (1) RELATIVE: box shifted right by ~left:30px and down (top:20px), siblings not.
if [ "$fail" -eq 0 ] && [ "$REL_X" -eq "$((SIB1_X + 30))" ]; then
    echo "[hb-pos] PASS relative left:30 offsets the box (x $SIB1_X -> $REL_X)"
else
    echo "[hb-pos] FAIL relative box not offset by 30px (sib=$SIB1_X rel=$REL_X)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$REL_Y" -gt "$SIB1_Y" ]; then
    echo "[hb-pos] PASS relative top:20 offsets the box downward (y $SIB1_Y -> $REL_Y)"
else
    echo "[hb-pos] FAIL relative box not offset downward (sib=$SIB1_Y rel=$REL_Y)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$SIB1_X" -eq "$SIB2_X" ]; then
    echo "[hb-pos] PASS in-flow siblings did NOT move (sib1.x=$SIB1_X == sib2.x=$SIB2_X)"
else
    echo "[hb-pos] FAIL a sibling moved with the relative box (sib1=$SIB1_X sib2=$SIB2_X)"; fail=1
fi

# (2) ABSOLUTE: placed at containing block (position:relative .cont) origin +
# left:10; its following in-flow sibling occupies the vacated slot (container top).
if [ "$fail" -eq 0 ] && [ "$ABS1_X" -eq "$((CONT_X + 10))" ]; then
    echo "[hb-pos] PASS absolute box at containing-block origin + left:10 (cont.x=$CONT_X abs.x=$ABS1_X)"
else
    echo "[hb-pos] FAIL absolute box not at cont origin+10 (cont=$CONT_X abs=$ABS1_X)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$ABS1_Y" -gt "$AFT_Y" ] && [ "$AFT_Y" -eq "$CONT_Y" ]; then
    echo "[hb-pos] PASS following sibling took the vacated flow slot (after.y=$AFT_Y == cont.y=$CONT_Y, above abs.y=$ABS1_Y)"
else
    echo "[hb-pos] FAIL flow not vacated by absolute box (after=$AFT_Y cont=$CONT_Y abs=$ABS1_Y)"; fail=1
fi

# (3) Z-INDEX: the two absolute boxes overlap exactly; the higher-z (purple,
# #8800ff, z5) wins the shared pixel over the lower-z (orange, #ff8800, z1).
if [ "$fail" -eq 0 ] && [ "$ABS1_X" -eq "$ABS2_X" ] && [ "$ABS1_Y" -eq "$ABS2_Y" ]; then
    echo "[hb-pos] PASS the two absolute boxes overlap (same painted rect)"
else
    echo "[hb-pos] FAIL absolute boxes are not overlapping (abs1=$ABS1_X,$ABS1_Y abs2=$ABS2_X,$ABS2_Y)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$ABS2_Z" -gt "$ABS1_Z" ] && \
   [ "$ABS1_PIX" = "#8800ff" ] && [ "$ABS2_PIX" = "#8800ff" ]; then
    echo "[hb-pos] PASS higher z-index colour wins the overlap (#8800ff over #ff8800; z$ABS2_Z > z$ABS1_Z)"
else
    echo "[hb-pos] FAIL z-index stacking wrong (abs1 pix=$ABS1_PIX abs2 pix=$ABS2_PIX z1=$ABS1_Z z2=$ABS2_Z)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-pos] RESULT: PASS"
else
    echo "[hb-pos] RESULT: FAIL"; exit 1
fi
