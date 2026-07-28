#!/usr/bin/env bash
# scripts/test_hambrowse_borderside_host.sh — FAST, QEMU-free gate proving TRUE
# PER-SIDE CSS borders (W3C css-backgrounds §4) in the graphical hambrowse
# backend: distinct per-side WIDTHS (border-top/-right/-bottom/-left with
# different px) and per-side STYLES (solid / dashed / dotted / double / none),
# plus the `border-width`/`border-style` TRBL shorthands and a uniform
# `border:Npx dashed` that must render DASHES (not a solid line).
#
# Before this round a CSS border was a single UNIFORM 1px stroke — one width,
# one style — so a `border-bottom:2px solid` tab underline, a thick accent side,
# or a dashed frame all collapsed to the same thin solid rectangle. Now the
# cascade parses per-side widths/styles into two packed ints that ride the
# layout record set (bbox_ps/bbox_ss) and lib/htmlpage paints FOUR independent
# edges (each its own thickness + dash/dot/double pattern).
#
# The gfx driver (user/hambrowse_host_gfx.ad) reports every stroked border box's
# outer rect (BORDER i x0 .. y1) and can SAMPLE arbitrary framebuffer pixels
# (trailing "x y x y ..." argv pairs -> "PIX x y #rgb"). We render the fixture,
# read each box's geometry, then sample:
#   * box .distinct — a pixel deep in the 12px LEFT edge is ink; a pixel past the
#     2px TOP edge is white  -> the left border is provably THICKER than the top;
#   * box .mixed    — the 6px DASHED bottom alternates ink/paper along its length
#     while the solid top stays continuous ink -> dashed != solid;
#   * box .udash    — a uniform `border:3px dashed` shows an ink dash AND a paper
#     gap on the top edge -> a shorthand dashed border really dashes;
#   * box .shorthand — `border-width:2px 10px 2px 10px` makes the LEFT edge 10px
#     (ink deep in) while the TOP stays 2px (white just past it).
# It also confirms the NATIVE hambrowse still compiles from the same engine.
#
# Built with the frozen Python seed compiler. PNG conversion is stdlib-only.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-borderside] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/borderside_compile.log"; then
    echo "[hb-borderside] FAIL: driver did not compile"; cat "$OUT/borderside_compile.log"; exit 1
fi
echo "[hb-borderside] PASS pixel backend compiled"

echo "[hb-borderside] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/borderside_native.log"; then
    echo "[hb-borderside] FAIL: native hambrowse did not compile"; cat "$OUT/borderside_native.log"; exit 1
fi
echo "[hb-borderside] PASS native hambrowse still compiles"

FIX="tests/fixtures/hambrowse_borderside.html"
PPM="$OUT/borderside.ppm"
PNG="$OUT/borderside.png"
DUMP="$OUT/borderside_dump.txt"
W=700

echo "[hb-borderside] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" "$W" >"$DUMP" 2>&1; then
    echo "[hb-borderside] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 && echo "[hb-borderside] wrote $PNG"
grep -E '^BORDER' "$DUMP"

NB=$(awk '/^BORDER n / {print $3; exit}' "$DUMP")
if [ "${NB:-0}" -lt 4 ]; then
    echo "[hb-borderside] FAIL: expected 4 bordered boxes, got ${NB:-0}"; exit 1
fi
echo "[hb-borderside] PASS registered $NB bordered boxes"

# Pull box i's geometry into shell vars X0_i Y0_i X1_i Y1_i.
for i in 0 1 2 3; do
    line=$(grep -E "^BORDER $i " "$DUMP")
    eval "X0_$i=$(echo "$line" | awk '{for(k=1;k<=NF;k++)if($k=="x0")print $(k+1)}')"
    eval "Y0_$i=$(echo "$line" | awk '{for(k=1;k<=NF;k++)if($k=="y0")print $(k+1)}')"
    eval "X1_$i=$(echo "$line" | awk '{for(k=1;k<=NF;k++)if($k=="x1")print $(k+1)}')"
    eval "Y1_$i=$(echo "$line" | awk '{for(k=1;k<=NF;k++)if($k=="y1")print $(k+1)}')"
done

# Build the sample coordinate list (relative to each box's reported geometry).
mid() { echo $((($1 + $2) / 2)); }

# --- box 0 (.distinct): 12px left vs 2px top ---
YM0=$(mid "$Y0_0" "$Y1_0")
S="$((X0_0+3)) $YM0 $((X0_0+9)) $YM0 $((X0_0+14)) $YM0"      # left: ink,ink,white
XM0=$(mid "$X0_0" "$X1_0")
S="$S $XM0 $((Y0_0+1)) $XM0 $((Y0_0+4))"                     # top: ink,white
# --- box 1 (.mixed): dashed bottom vs solid top ---
YB1=$((Y1_1-3))                                             # inside the 6px bottom band
S="$S $((X0_1+3)) $YB1 $((X0_1+15)) $YB1 $((X0_1+27)) $YB1"  # bottom: dash,gap,dash
S="$S $((X0_1+3)) $((Y0_1+2)) $((X0_1+15)) $((Y0_1+2))"      # top solid: ink,ink
# --- box 2 (.udash): uniform dashed shows a dash AND a gap ---
S="$S $((X0_2+1)) $((Y0_2+1)) $((X0_2+8)) $((Y0_2+1))"       # top: dash,gap
# --- box 3 (.shorthand): 10px left vs 2px top ---
YM3=$(mid "$Y0_3" "$Y1_3")
S="$S $((X0_3+3)) $YM3 $((X0_3+14)) $YM3"                    # left: ink(10px),white
XM3=$(mid "$X0_3" "$X1_3")
S="$S $XM3 $((Y0_3+1)) $XM3 $((Y0_3+4))"                     # top: ink(2px),white

SDUMP="$OUT/borderside_pix.txt"
"$BIN" "$FIX" "$PPM" "$W" $S >"$SDUMP" 2>&1
grep -E '^PIX' "$SDUMP"

pix() { awk -v x="$1" -v y="$2" '$1=="PIX" && $2==x && $3==y {print $4; exit}' "$SDUMP"; }
is_ink()  { [ "$1" != "#ffffff" ] && [ -n "$1" ]; }
is_paper(){ [ "$1" = "#ffffff" ]; }

check() { # desc  color  want(ink|paper)
    if [ "$3" = "ink" ]; then
        if is_ink "$2"; then echo "[hb-borderside] PASS $1 = ink ($2)"; else echo "[hb-borderside] FAIL $1 expected ink, got '$2'"; fail=1; fi
    else
        if is_paper "$2"; then echo "[hb-borderside] PASS $1 = paper ($2)"; else echo "[hb-borderside] FAIL $1 expected paper, got '$2'"; fail=1; fi
    fi
}

# box0: left border is 12px thick (ink 9px deep), top border only 2px (white 4px down)
check "box0 left edge +3px"  "$(pix $((X0_0+3))  $YM0)" ink
check "box0 left edge +9px"  "$(pix $((X0_0+9))  $YM0)" ink
check "box0 past 12px left"  "$(pix $((X0_0+14)) $YM0)" paper
check "box0 top edge (2px)"  "$(pix $XM0 $((Y0_0+1)))"  ink
check "box0 past 2px top"    "$(pix $XM0 $((Y0_0+4)))"  paper

# box1: dashed bottom alternates ink/paper; solid top is continuous ink
D1=$(pix $((X0_1+3))  $YB1); G1=$(pix $((X0_1+15)) $YB1); D2=$(pix $((X0_1+27)) $YB1)
check "box1 bottom dash #1"  "$D1" ink
check "box1 bottom gap"      "$G1" paper
check "box1 bottom dash #2"  "$D2" ink
check "box1 top solid #1"    "$(pix $((X0_1+3))  $((Y0_1+2)))" ink
check "box1 top solid #2"    "$(pix $((X0_1+15)) $((Y0_1+2)))" ink

# box2: uniform `border:3px dashed` shows a dash AND a gap on one edge
check "box2 uniform-dash ink" "$(pix $((X0_2+1)) $((Y0_2+1)))" ink
check "box2 uniform-dash gap" "$(pix $((X0_2+8)) $((Y0_2+1)))" paper

# box3: border-width TRBL shorthand -> 10px left, 2px top
check "box3 left edge +3px"  "$(pix $((X0_3+3))  $YM3)" ink
check "box3 past 10px left"  "$(pix $((X0_3+14)) $YM3)" paper
check "box3 top edge (2px)"  "$(pix $XM3 $((Y0_3+1)))"  ink
check "box3 past 2px top"    "$(pix $XM3 $((Y0_3+4)))"  paper

if [ "$fail" -eq 0 ]; then
    echo "[hb-borderside] RESULT: PASS"
else
    echo "[hb-borderside] RESULT: FAIL"; exit 1
fi
