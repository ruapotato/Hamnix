#!/usr/bin/env bash
# scripts/test_hambrowse_bordercolor_host.sh — FAST, QEMU-free gate proving TRUE
# PER-SIDE CSS border COLOURS (W3C css-backgrounds §4) in the graphical hambrowse
# backend: border-top/-right/-bottom/-left-color paint each edge in its OWN
# colour, the `border-color` TRBL shorthand (1..4 colours) expands per side, and
# a single coloured ACCENT side falls back to the uniform colour on the others.
#
# Round-4 landed true per-side WIDTHS + STYLES but carried ONE uniform border
# colour (the last border-*-color token won for all four sides). This round adds
# four cascade colour slots (r_bctop/rt/bot/lft -> m_bc* -> box_bordc*_stack ->
# bbox_rgb_{r,b,l}) so a red-top / green-right / blue-bottom / yellow-left box
# paints each edge distinctly. The per-side painter (lib/htmlpage _hpg_paint_
# border_sides) now takes four colours and strokes each edge with its own.
#
# The gfx driver (user/hambrowse_host_gfx.ad) reports every stroked border box's
# outer rect (BORDER i x0 .. y1) and SAMPLES arbitrary framebuffer pixels
# (trailing "x y ..." argv pairs -> "PIX x y #rrggbb"). We render the fixture,
# read each box's geometry, then sample a pixel DEEP in each 8px edge band and
# assert its EXACT colour:
#   * box .fourcol  — top=#cc0000 right=#00aa00 bottom=#0000cc left=#ccaa00
#                     (four border-<side>-color longhands, all distinct);
#   * box .shortcol — the `border-color: #dd1111 #11bb22 #1133dd #ddbb22` TRBL
#                     shorthand expands T/R/B/L;
#   * box .accent   — a uniform grey (#999999) base with ONE overriding
#                     border-bottom-color:#e91e63; the three unset sides stay grey.
# It also confirms the NATIVE hambrowse still compiles from the same engine.
#
# Built with the frozen Python seed compiler. PNG conversion is stdlib-only.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-bordercolor] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/bordercolor_compile.log"; then
    echo "[hb-bordercolor] FAIL: driver did not compile"; cat "$OUT/bordercolor_compile.log"; exit 1
fi
echo "[hb-bordercolor] PASS pixel backend compiled"

echo "[hb-bordercolor] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/bordercolor_native.log"; then
    echo "[hb-bordercolor] FAIL: native hambrowse did not compile"; cat "$OUT/bordercolor_native.log"; exit 1
fi
echo "[hb-bordercolor] PASS native hambrowse still compiles"

FIX="tests/fixtures/hambrowse_bordercolor.html"
PPM="$OUT/bordercolor.ppm"
PNG="$OUT/bordercolor.png"
DUMP="$OUT/bordercolor_dump.txt"
W=700

echo "[hb-bordercolor] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" "$W" >"$DUMP" 2>&1; then
    echo "[hb-bordercolor] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 && echo "[hb-bordercolor] wrote $PNG"
grep -E '^BORDER' "$DUMP"

NB=$(awk '/^BORDER n / {print $3; exit}' "$DUMP")
if [ "${NB:-0}" -lt 3 ]; then
    echo "[hb-bordercolor] FAIL: expected 3 bordered boxes, got ${NB:-0}"; exit 1
fi
echo "[hb-bordercolor] PASS registered $NB bordered boxes"

for i in 0 1 2; do
    line=$(grep -E "^BORDER $i " "$DUMP")
    eval "X0_$i=$(echo "$line" | awk '{for(k=1;k<=NF;k++)if($k=="x0")print $(k+1)}')"
    eval "Y0_$i=$(echo "$line" | awk '{for(k=1;k<=NF;k++)if($k=="y0")print $(k+1)}')"
    eval "X1_$i=$(echo "$line" | awk '{for(k=1;k<=NF;k++)if($k=="x1")print $(k+1)}')"
    eval "Y1_$i=$(echo "$line" | awk '{for(k=1;k<=NF;k++)if($k=="y1")print $(k+1)}')"
done

mid() { echo $((($1 + $2) / 2)); }

# For each box, sample a pixel deep in the top / right / bottom / left edge band.
S=""
for i in 0 1 2; do
    XM=$(mid $(eval echo \$X0_$i) $(eval echo \$X1_$i))
    YM=$(mid $(eval echo \$Y0_$i) $(eval echo \$Y1_$i))
    S="$S $XM $(($(eval echo \$Y0_$i)+3))"                 # top
    S="$S $(($(eval echo \$X1_$i)-3)) $YM"                 # right
    S="$S $XM $(($(eval echo \$Y1_$i)-3))"                 # bottom
    S="$S $(($(eval echo \$X0_$i)+3)) $YM"                 # left
done

SDUMP="$OUT/bordercolor_pix.txt"
"$BIN" "$FIX" "$PPM" "$W" $S >"$SDUMP" 2>&1
grep -E '^PIX' "$SDUMP"

pix() { awk -v x="$1" -v y="$2" '$1=="PIX" && $2==x && $3==y {print $4; exit}' "$SDUMP"; }

check() { # desc  got  want
    if [ "$2" = "$3" ]; then
        echo "[hb-bordercolor] PASS $1 = $3"
    else
        echo "[hb-bordercolor] FAIL $1 expected $3, got '$2'"; fail=1
    fi
}

sample_side() { # box  side(t|r|b|l)  -> echoes the sampled colour
    XM=$(mid $(eval echo \$X0_$1) $(eval echo \$X1_$1))
    YM=$(mid $(eval echo \$Y0_$1) $(eval echo \$Y1_$1))
    case "$2" in
        t) pix "$XM" "$(($(eval echo \$Y0_$1)+3))" ;;
        r) pix "$(($(eval echo \$X1_$1)-3))" "$YM" ;;
        b) pix "$XM" "$(($(eval echo \$Y1_$1)-3))" ;;
        l) pix "$(($(eval echo \$X0_$1)+3))" "$YM" ;;
    esac
}

# box0 .fourcol — four distinct border-<side>-color longhands
check "box0 top-color"    "$(sample_side 0 t)" "#cc0000"
check "box0 right-color"  "$(sample_side 0 r)" "#00aa00"
check "box0 bottom-color" "$(sample_side 0 b)" "#0000cc"
check "box0 left-color"   "$(sample_side 0 l)" "#ccaa00"

# box1 .shortcol — border-color TRBL shorthand expands per side
check "box1 top (shorthand)"    "$(sample_side 1 t)" "#dd1111"
check "box1 right (shorthand)"  "$(sample_side 1 r)" "#11bb22"
check "box1 bottom (shorthand)" "$(sample_side 1 b)" "#1133dd"
check "box1 left (shorthand)"   "$(sample_side 1 l)" "#ddbb22"

# box2 .accent — one overriding border-bottom-color; other sides fall back to grey
check "box2 top (fallback grey)"   "$(sample_side 2 t)" "#999999"
check "box2 right (fallback grey)" "$(sample_side 2 r)" "#999999"
check "box2 bottom (accent)"       "$(sample_side 2 b)" "#e91e63"
check "box2 left (fallback grey)"  "$(sample_side 2 l)" "#999999"

if [ "$fail" -eq 0 ]; then
    echo "[hb-bordercolor] RESULT: PASS"
else
    echo "[hb-bordercolor] RESULT: FAIL"; exit 1
fi
