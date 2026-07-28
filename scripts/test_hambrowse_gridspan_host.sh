#!/usr/bin/env bash
# scripts/test_hambrowse_gridspan_host.sh — FAST, QEMU-free gate for the round-2
# CSS GRID features in the native browser engine (lib/htmlengine.ad):
#
#   * grid-column line placement: `grid-column: span N` (a hero cell occupying
#     multiple TRACKS) and the `<start> / <end>` shorthand (`grid-column: 1 / 4`
#     => a 3-track banner), the item's box width covering N tracks + inner gaps.
#   * grid-template-rows: explicit FIXED px row heights, so grid rows are NOT
#     purely content-sized (uniform, taller-than-content dashboard rows).
#
# The fixture lays out (1) a `repeat(3,1fr)` dashboard with `grid-template-rows:
# 96px 96px 96px`, whose first cell is `grid-column: span 2` (a hero spanning two
# tracks) and whose remaining cells auto-flow around it across three FIXED-height
# rows, and (2) a 4-column banner shell whose first item is `grid-column: 1 / 4`
# (spanning three tracks) with the auto-flow items placing around it. The gate
# asserts on ACTUAL engine layout coordinates (FILL box extents + SEG rows) — the
# spanning item's x-extent covering N tracks, the uniform fixed row pitch, and the
# auto-flow wrap — NOT on echo.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_grid_span.html"
mkdir -p "$OUT"

echo "[hb-gridspan] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-gridspan] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-gridspan] PASS host harness compiled -> $BIN"

echo "[hb-gridspan] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-gridspan] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-gridspan] PASS native hambrowse still compiles"

fail=0
D="$OUT/gridspan.txt"
"$BIN" "$FIX" 640 >"$D" 2>&1 || { echo "[hb-gridspan] FAIL: render exited non-zero"; cat "$D"; exit 1; }

seg_row() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }
seg_x()   { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $3}' | head -1; }
# A uniquely-coloured FILL box "FILL top bot lx rx #color <radius>" -> "$1"=field
# index. Match the colour at field $6 (NOT end-of-line: round-10 border-radius
# appends a trailing radius field, so the colour is no longer the last token).
fill_uniq() { awk -v f="$1" -v c="$2" '$1=="FILL" && $6==c{print $f; exit}' "$D"; }

# ---- (A) grid-column: span 2 hero over a repeat(3,1fr) dashboard --------------
HLX=$(fill_uniq 4 "#ffeeaa"); HRX=$(fill_uniq 5 "#ffeeaa")   # hero box left/right
# dashboard row1 (three cells across all three tracks) FILL extents, sorted L->R.
# Row index 9 (was 10 before the border-model change: a bordered grid item no
# longer reserves a whole top-rule grid row, so its fill starts one row higher —
# the same Chrome-matching shift this change makes everywhere. The span/pitch
# assertions below are all RELATIVE, so only this absolute snapshot moved.)
readarray -t R1 < <(awk '$1=="FILL" && $2==9 && $6=="#e8eefc"{print $4" "$5}' "$D" | sort -n)
c0lx=$(echo "${R1[0]}" | awk '{print $1}')            # track0 left
c1rx=$(echo "${R1[1]}" | awk '{print $2}')            # track1 right
c2w=$(( $(echo "${R1[2]}" | awk '{print $2}') - $(echo "${R1[2]}" | awk '{print $1}') ))  # a single track width
herow=$(( HRX - HLX ))
echo "[hb-gridspan] hero box: lx=$HLX rx=$HRX width=$herow ; track0lx=$c0lx track1rx=$c1rx singletrack=$c2w"
# hero left == track0 left, hero right == track1 right => exactly two tracks wide.
if [ -n "$HLX" ] && [ "$HLX" = "$c0lx" ] && [ "$HRX" = "$c1rx" ] && [ "$herow" -gt "$c2w" ]; then
    echo "[hb-gridspan] PASS 'grid-column: span 2' hero spans tracks 0-1 ($herow px > single $c2w px)"
else
    echo "[hb-gridspan] FAIL hero span geometry (hero $HLX..$HRX vs track0lx $c0lx track1rx $c1rx)"; fail=1
fi

# auto-flow places the single-track sibling into track2 on the SAME row, then
# wraps a full 3-across row below the hero.
hr=$(seg_row Hero); bvr=$(seg_row Bravo); bvx=$(seg_x Bravo)
cr=$(seg_row Charlie); dr=$(seg_row Delta); er=$(seg_row Echo)
echo "[hb-gridspan] dash rows: Hero=$hr Bravo=$bvr(x$bvx) | Charlie=$cr Delta=$dr Echo=$er"
if [ -n "$hr" ] && [ -n "$bvx" ] && [ -n "$HRX" ] && [ "$bvr" = "$hr" ] && \
   [ "$bvx" -gt "$HRX" ] && \
   [ "$cr" = "$dr" ] && [ "$dr" = "$er" ] && [ "$cr" -gt "$hr" ]; then
    echo "[hb-gridspan] PASS auto-flow: sibling fills track2 beside the hero, next 3 wrap below"
else
    echo "[hb-gridspan] FAIL auto-flow around the span (Hero r$hr Bravo r$bvr / row1 $cr $dr $er)"; fail=1
fi

# ---- (B) grid-template-rows: three FIXED, uniform, taller-than-content rows ---
fr=$(seg_row Foxtrot)
step1=$(( cr - hr )); step2=$(( fr - cr ))
echo "[hb-gridspan] fixed-row pitch: Hero r$hr -> Charlie r$cr -> Foxtrot r$fr (step1=$step1 step2=$step2)"
# 96px == 6 rows + a 10px (==1 row) gap => a 7-row pitch, uniform, and STRICTLY
# larger than the ~4-row content-height pitch a template-rows-less grid produces.
if [ "$step1" = "$step2" ] && [ "$step1" -eq 7 ] && [ "$step1" -gt 4 ]; then
    echo "[hb-gridspan] PASS grid-template-rows 96px => uniform fixed 7-row pitch (content pitch is 4)"
else
    echo "[hb-gridspan] FAIL fixed row pitch (step1=$step1 step2=$step2, expect 7==7)"; fail=1
fi

# ---- (C) grid-column: 1 / 4 banner spanning three of four tracks -------------
BLX=$(fill_uniq 4 "#ddffdd"); BRX=$(fill_uniq 5 "#ddffdd")
banw=$(( BRX - BLX ))
# banner-shell row1 (Body/Note/Tail across tracks 0-2) FILL extents, sorted L->R.
readarray -t S1 < <(awk '$1=="FILL" && $2==27 && $6=="#e8eefc"{print $4" "$5}' "$D" | sort -n)
b0lx=$(echo "${S1[0]}" | awk '{print $1}')            # track0 left
b2rx=$(echo "${S1[2]}" | awk '{print $2}')            # track2 right
b0w=$(( $(echo "${S1[0]}" | awk '{print $2}') - b0lx ))
banr=$(seg_row Banner); sidr=$(seg_row Side); sidx=$(seg_x Side); bodr=$(seg_row Body)
echo "[hb-gridspan] banner box: lx=$BLX rx=$BRX width=$banw ; track0lx=$b0lx track2rx=$b2rx single=$b0w"
echo "[hb-gridspan] banner rows: Banner=$banr Side=$sidr(x$sidx) Body=$bodr"
# banner left == track0 left, banner right == track2 right => exactly three tracks.
if [ -n "$BLX" ] && [ "$BLX" = "$b0lx" ] && [ "$BRX" = "$b2rx" ] && [ "$banw" -gt "$b0w" ]; then
    echo "[hb-gridspan] PASS 'grid-column: 1 / 4' banner spans tracks 0-2 ($banw px > single $b0w px)"
else
    echo "[hb-gridspan] FAIL banner span geometry (banner $BLX..$BRX vs track0lx $b0lx track2rx $b2rx)"; fail=1
fi
# auto-flow after an explicit span: Side keeps the SAME row at the 4th track, and
# the remaining items wrap to the next row.
if [ -n "$banr" ] && [ -n "$sidx" ] && [ -n "$BRX" ] && [ "$sidr" = "$banr" ] && \
   [ "$sidx" -ge "$BRX" ] && [ "$bodr" -gt "$banr" ]; then
    echo "[hb-gridspan] PASS auto-flow resumes after the banner (Side at track3 same row, Body wraps)"
else
    echo "[hb-gridspan] FAIL auto-flow after explicit span (Banner r$banr Side r$sidr Body r$bodr)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-gridspan] RESULT: FAIL"; exit 1
fi
echo "[hb-gridspan] RESULT: PASS"
