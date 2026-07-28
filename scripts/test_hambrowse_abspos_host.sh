#!/usr/bin/env bash
# scripts/test_hambrowse_abspos_host.sh — FAST, QEMU-free gate for CSS
# ABSOLUTE POSITIONING with RIGHT / BOTTOM offsets in the native browser engine
# (lib/web/layout/flow.ad resolver), driven by the pixel backend
# user/hambrowse_host_gfx.ad. Regression cover for the on-device QA bug where a
# `position:absolute; top:8px; right:8px` badge anchored to the wrong edge
# (rendered top-LEFT overlapping the heading) instead of the containing block's
# top-RIGHT corner.
#
# Asserts on STABLE background-fill pixel rects (POSFILL records) — not glyph
# ink — so a regression fails without a QEMU boot. A `position:relative` parent
# (.cont, known 400x160 rect) holds four absolute corner boxes:
#   TR  top:8  right:8   -> pinned to the parent's top-RIGHT
#   BR  bottom:8 right:8 -> pinned to the parent's bottom-RIGHT
#   BL  bottom:8 left:8  -> pinned to the parent's bottom-LEFT
#   TL  top:8  left:8    -> pinned to the parent's top-LEFT (unchanged path)
# The RIGHT boxes must have their right edge at cont_right-8 (NOT at cont_left);
# the BOTTOM boxes must sit at the parent's bottom (y below the TOP boxes); the
# LEFT/TOP boxes are byte-identical to the pre-fix behaviour. Vertical offsets
# are row-granular (an 8px inset < 1 text row rounds to 0 rows, same as top:8),
# so the assertions check anchoring to the correct EDGE, not the 8px sub-row gap.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_abspos.html"
DUMP="$OUT/abspos_dump.txt"
PPM="$OUT/abspos.ppm"
PNG="$OUT/abspos.png"
mkdir -p "$OUT"
fail=0

echo "[hb-abspos] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/abspos_compile.log"; then
    echo "[hb-abspos] FAIL: driver did not compile"; cat "$OUT/abspos_compile.log"; exit 1
fi
echo "[hb-abspos] PASS pixel backend compiled -> $BIN"

echo "[hb-abspos] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/abspos_native.log"; then
    echo "[hb-abspos] FAIL: native hambrowse did not compile"; cat "$OUT/abspos_native.log"; exit 1
fi
echo "[hb-abspos] PASS native hambrowse still compiles"

echo "[hb-abspos] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-abspos] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^POSFILL' "$DUMP" || true
python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>/dev/null && \
    echo "[hb-abspos] wrote $PNG for eyeballing" || true

# Field extractor: given a declared colour echo "<x0> <y0> <x1> <y1>" for the
# POSFILL line whose col matches (POSFILL i z Z x0 X y0 Y x1 X y1 Y col C pix P).
row_for() {
    awk -v c="$1" '$1=="POSFILL" && $14==c {print $6, $8, $10, $12; exit}' "$DUMP"
}

read -r TR_X0 TR_Y0 TR_X1 TR_Y1 < <(row_for '#ff0000')   # top-right badge
read -r BR_X0 BR_Y0 BR_X1 BR_Y1 < <(row_for '#00cc00')   # bottom-right
read -r BL_X0 BL_Y0 BL_X1 BL_Y1 < <(row_for '#ee00ee')   # bottom-left
read -r TL_X0 TL_Y0 TL_X1 TL_Y1 < <(row_for '#0000ee')   # top-left (unchanged)
read -r C_X0  C_Y0  C_X1  C_Y1  < <(row_for '#dddddd')   # containing block
read -r GR_X0 GR_Y0 GR_X1 GR_Y1 < <(row_for '#ff8800')   # badge in GRADIENT parent
read -r XR_X0 XR_Y0 XR_X1 XR_Y1 < <(row_for '#ffaa00')   # badge in TRANSPARENT parent
# The gradient parent paints a gradient rect whose declared colour field is
# #000000 (the fill records a placeholder colour; the pixel sampled inside is the
# gradient) — its rect gives the gradient parent's own top row + right edge.
read -r GP_X0 GP_Y0 GP_X1 GP_Y1 < <(row_for '#000000')

echo "[hb-abspos] cont=($C_X0,$C_Y0)-($C_X1,$C_Y1)"
echo "[hb-abspos] TR=($TR_X0,$TR_Y0)-($TR_X1,$TR_Y1) BR=($BR_X0,$BR_Y0)-($BR_X1,$BR_Y1)"
echo "[hb-abspos] BL=($BL_X0,$BL_Y0)-($BL_X1,$BL_Y1) TL=($TL_X0,$TL_Y0)-($TL_X1,$TL_Y1)"
echo "[hb-abspos] GR=($GR_X0,$GR_Y0)-($GR_X1,$GR_Y1) XR=($XR_X0,$XR_Y0)-($XR_X1,$XR_Y1)"

need() { [ -n "$1" ] || { echo "[hb-abspos] FAIL: missing box ($2)"; fail=1; return 1; }; return 0; }
for v in "$C_X0:cont" "$TR_X0:TR" "$BR_X0:BR" "$BL_X0:BL" "$TL_X0:TL" \
         "$GR_X0:GR" "$XR_X0:XR"; do
    need "${v%%:*}" "${v##*:}" || true
done

# The 8px inset (right:8 / left:8) lands on the pixel grid exactly (x is
# pixel-granular). Right edge target = cont_right - 8; left edge target = cont_left + 8.
RIGHT_TGT=$((C_X1 - 8))
LEFT_TGT=$((C_X0 + 8))

# (1) TOP-RIGHT badge: right edge pinned to cont_right-8, top row = container top,
#     and it is NOT flush against the container's LEFT edge (the regressed bug).
if [ "$fail" -eq 0 ] && [ "$TR_X1" -eq "$RIGHT_TGT" ]; then
    echo "[hb-abspos] PASS TR right edge at cont_right-8 (x1=$TR_X1 == $RIGHT_TGT)"
else
    echo "[hb-abspos] FAIL TR not right-anchored (x1=$TR_X1 want $RIGHT_TGT)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$TR_X0" -gt "$((C_X0 + 40))" ]; then
    echo "[hb-abspos] PASS TR is NOT at the container left edge (x0=$TR_X0 >> cont_left=$C_X0)"
else
    echo "[hb-abspos] FAIL TR wrongly near container left (x0=$TR_X0 cont_left=$C_X0)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$TR_Y0" -eq "$C_Y0" ]; then
    echo "[hb-abspos] PASS TR pinned to container top (y0=$TR_Y0 == cont_top=$C_Y0)"
else
    echo "[hb-abspos] FAIL TR not at container top (y0=$TR_Y0 cont_top=$C_Y0)"; fail=1
fi

# (2) BOTTOM-RIGHT: right edge at cont_right-8 AND anchored to the bottom (its
#     top row sits well BELOW the top badge, its bottom edge = container bottom).
if [ "$fail" -eq 0 ] && [ "$BR_X1" -eq "$RIGHT_TGT" ]; then
    echo "[hb-abspos] PASS BR right edge at cont_right-8 (x1=$BR_X1 == $RIGHT_TGT)"
else
    echo "[hb-abspos] FAIL BR not right-anchored (x1=$BR_X1 want $RIGHT_TGT)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$BR_Y0" -gt "$TR_Y1" ]; then
    echo "[hb-abspos] PASS BR anchored to bottom, below the top badge (BR.y0=$BR_Y0 > TR.y1=$TR_Y1)"
else
    echo "[hb-abspos] FAIL BR not moved to the bottom (BR.y0=$BR_Y0 TR.y1=$TR_Y1)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$BR_Y1" -eq "$C_Y1" ]; then
    echo "[hb-abspos] PASS BR bottom edge at container bottom (y1=$BR_Y1 == cont_bot=$C_Y1)"
else
    echo "[hb-abspos] FAIL BR bottom edge not at container bottom (y1=$BR_Y1 cont_bot=$C_Y1)"; fail=1
fi

# (3) BOTTOM-LEFT: left:8 unchanged (x0 = cont_left+8) and anchored to the bottom.
if [ "$fail" -eq 0 ] && [ "$BL_X0" -eq "$LEFT_TGT" ]; then
    echo "[hb-abspos] PASS BL left edge at cont_left+8 (x0=$BL_X0 == $LEFT_TGT)"
else
    echo "[hb-abspos] FAIL BL left offset wrong (x0=$BL_X0 want $LEFT_TGT)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$BL_Y1" -eq "$C_Y1" ]; then
    echo "[hb-abspos] PASS BL anchored to container bottom (y1=$BL_Y1 == cont_bot=$C_Y1)"
else
    echo "[hb-abspos] FAIL BL not at bottom (y1=$BL_Y1 cont_bot=$C_Y1)"; fail=1
fi

# (4) TOP-LEFT (regression guard): left:8/top:8 path unchanged — x0=cont_left+8,
#     y0=container top, byte-identical to the pre-fix left/top behaviour.
if [ "$fail" -eq 0 ] && [ "$TL_X0" -eq "$LEFT_TGT" ] && [ "$TL_Y0" -eq "$C_Y0" ]; then
    echo "[hb-abspos] PASS TL left/top unchanged (x0=$TL_X0==$LEFT_TGT, y0=$TL_Y0==cont_top=$C_Y0)"
else
    echo "[hb-abspos] FAIL TL left/top path regressed (x0=$TL_X0 want $LEFT_TGT, y0=$TL_Y0 cont_top=$C_Y0)"; fail=1
fi

# The gradient/transparent parents are the same 400px-wide, top-level geometry as
# .cont, so their padding-box right edge is the same pixel: right-anchor target =
# cont_right-8. (The old paint-scan fix read cont_right from the ancestor's SOLID
# fill; with no solid fill it dropped the badge at content-left — the regression.)
need "$GP_X0" "gcont" || true

# (5) GRADIENT-backed containing block: the parent paints a linear-gradient (NO
#     solid background-fill record), so the old paint-scan heuristic found no
#     ancestor fill and dropped the badge at content-LEFT. Geometry-based CB edges
#     must anchor it top-RIGHT: right edge at gcont_right-8, pinned to the gradient
#     parent's OWN top row, and NOT flush against the container left edge.
if [ "$fail" -eq 0 ] && [ "$GR_X1" -eq "$((GP_X1 - 8))" ]; then
    echo "[hb-abspos] PASS GRADIENT badge right edge at parent_right-8 (x1=$GR_X1 == $((GP_X1 - 8)))"
else
    echo "[hb-abspos] FAIL GRADIENT badge not right-anchored (x1=$GR_X1 want $((GP_X1 - 8)))"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$GR_X0" -gt "$((GP_X0 + 40))" ]; then
    echo "[hb-abspos] PASS GRADIENT badge is NOT at content-left (x0=$GR_X0 >> left=$GP_X0)"
else
    echo "[hb-abspos] FAIL GRADIENT badge wrongly near content-left (x0=$GR_X0 left=$GP_X0)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$GR_Y0" -eq "$GP_Y0" ]; then
    echo "[hb-abspos] PASS GRADIENT badge pinned to gradient parent top (y0=$GR_Y0 == $GP_Y0)"
else
    echo "[hb-abspos] FAIL GRADIENT badge not at parent top (y0=$GR_Y0 want $GP_Y0)"; fail=1
fi

# (6) TRANSPARENT containing block: no background at all — the case the old
#     paint-scan fix EXPLICITLY could not anchor (it fell back to content-left).
#     Geometry-based CB edges anchor it top-RIGHT exactly like the gradient case.
#     Same-width top-level parent as .cont, so its right edge = RIGHT_TGT.
if [ "$fail" -eq 0 ] && [ "$XR_X1" -eq "$RIGHT_TGT" ]; then
    echo "[hb-abspos] PASS TRANSPARENT badge right edge at parent_right-8 (x1=$XR_X1 == $RIGHT_TGT)"
else
    echo "[hb-abspos] FAIL TRANSPARENT badge not right-anchored (x1=$XR_X1 want $RIGHT_TGT)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$XR_X0" -gt "$((C_X0 + 40))" ]; then
    echo "[hb-abspos] PASS TRANSPARENT badge is NOT at content-left (x0=$XR_X0 >> left=$C_X0)"
else
    echo "[hb-abspos] FAIL TRANSPARENT badge wrongly near content-left (x0=$XR_X0 left=$C_X0)"; fail=1
fi
# Its top row sits BELOW the gradient card (blocks stack) — anchored to a top
# edge, not floating at the solid card's origin.
if [ "$fail" -eq 0 ] && [ "$XR_Y0" -gt "$GR_Y0" ]; then
    echo "[hb-abspos] PASS TRANSPARENT badge anchored below the gradient card (y0=$XR_Y0 > $GR_Y0)"
else
    echo "[hb-abspos] FAIL TRANSPARENT badge vertical anchor wrong (y0=$XR_Y0 GR.y0=$GR_Y0)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-abspos] RESULT: PASS"
else
    echo "[hb-abspos] RESULT: FAIL"; exit 1
fi
