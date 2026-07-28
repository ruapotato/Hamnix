#!/usr/bin/env bash
# scripts/test_hambrowse_grid_host.sh — FAST, QEMU-free gate for CSS GRID in the
# native browser engine (lib/htmlengine.ad):
#
#   `display:grid` + `grid-template-columns` with the common track types —
#   `repeat(N, 1fr)` equal fr columns, explicit lists mixing a fixed px rail with
#   fr tracks (`200px 1fr 1fr`) — plus `gap`/`column-gap` between tracks and
#   auto-placement (items flow left-to-right, wrapping to a new row every N items).
#
# The fixture lays out (1) a 3-column `repeat(3,1fr)` card grid of SEVEN cards
# (so auto-placement must wrap 3/3/1 across THREE rows) and (2) a page shell
# `grid-template-columns: 200px 1fr 1fr; column-gap:20px` (a fixed rail beside two
# equal fr columns). The gate asserts on ACTUAL engine layout coordinates — the
# item column x-positions, the row wrapping at the track count, the equal-fr
# spacing, the fixed-vs-fr track widths and the 20px inter-track gap — NOT on echo.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_grid.html"
mkdir -p "$OUT"

echo "[hb-grid] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-grid] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-grid] PASS host harness compiled -> $BIN"

echo "[hb-grid] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-grid] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-grid] PASS native hambrowse still compiles"

fail=0
D="$OUT/grid.txt"
"$BIN" "$FIX" 640 >"$D" 2>&1 || { echo "[hb-grid] FAIL: render exited non-zero"; cat "$D"; exit 1; }

seg_row() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }
seg_x()   { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $3}' | head -1; }

# ---- card grid: repeat(3, 1fr) + 7 items -------------------------------------
ar=$(seg_row Alpha);   ax=$(seg_x Alpha)
br=$(seg_row Bravo);   bx=$(seg_x Bravo)
cr=$(seg_row Charlie); cx=$(seg_x Charlie)
dr=$(seg_row Delta);   dx=$(seg_x Delta)
er=$(seg_row Echo);    ex=$(seg_x Echo)
fr=$(seg_row Foxtrot); fx=$(seg_x Foxtrot)
gr=$(seg_row Golf);    gx=$(seg_x Golf)
echo "[hb-grid] cards row0: Alpha(r$ar x$ax) Bravo(r$br x$bx) Charlie(r$cr x$cx)"
echo "[hb-grid] cards row1: Delta(r$dr x$dx) Echo(r$er x$ex) Foxtrot(r$fr x$fx)"
echo "[hb-grid] cards row2: Golf(r$gr x$gx)"

# (1) auto-placement WRAPS every 3 items -> three rows (3 / 3 / 1)
if [ -n "$ar" ] && [ "$ar" = "$br" ] && [ "$br" = "$cr" ] && \
   [ -n "$dr" ] && [ "$dr" = "$er" ] && [ "$er" = "$fr" ] && \
   [ "$dr" -gt "$ar" ] && [ -n "$gr" ] && [ "$gr" -gt "$dr" ]; then
    echo "[hb-grid] PASS 7 cards auto-place 3/3/1 across three grid rows"
else
    echo "[hb-grid] FAIL card auto-placement/wrapping (rows a$ar b$br c$cr / d$dr e$er f$fr / g$gr)"; fail=1
fi

# (2) three distinct track columns, REUSED on every row (col x repeats down rows)
if [ "$ax" = "$dx" ] && [ "$dx" = "$gx" ] && \
   [ "$bx" = "$ex" ] && [ "$cx" = "$fx" ] && \
   [ "$ax" -lt "$bx" ] && [ "$bx" -lt "$cx" ]; then
    echo "[hb-grid] PASS 3 track columns reused across rows (col0=$ax col1=$bx col2=$cx)"
else
    echo "[hb-grid] FAIL track columns not reused/ordered (a$ax b$bx c$cx d$dx e$ex f$fx g$gx)"; fail=1
fi

# (3) equal fr tracks -> uniform column-to-column spacing
sp01=$((bx - ax))
sp12=$((cx - bx))
echo "[hb-grid] card fr spacing: col0->1=$sp01 col1->2=$sp12 (expect equal)"
if [ "$sp01" -eq "$sp12" ] && [ "$sp01" -gt 0 ]; then
    echo "[hb-grid] PASS repeat(3,1fr) yields three equal-width fr tracks"
else
    echo "[hb-grid] FAIL fr tracks not equal ($sp01 vs $sp12)"; fail=1
fi

# ---- page shell: 200px 1fr 1fr; column-gap:20px ------------------------------
sx=$(seg_x Sidebar); mx=$(seg_x Mainarea); px=$(seg_x Extra)
echo "[hb-grid] shell x: Sidebar=$sx Mainarea=$mx Extra=$px"
railstep=$((mx - sx))     # fixed 200px track + 20px gap == 220
frstep=$((px - mx))       # fr track (192px) + 20px gap == 212
# FULL-WIDTH SCOPING: this page uses display:grid, so the readable-measure gutter
# is disabled and the grid resolves its fr tracks against the FULL viewport
# content width (624px at bw=640), like Firefox — not the old 584px readable
# strip. The fixed 200px rail is unchanged (rail step stays 220); each 1fr track
# grew 172->192px so the fr step is 192+20gap = 212 (was 172+20 = 192). The
# grid now fills the window edge-to-edge as a real browser does.
echo "[hb-grid] shell steps: rail->main=$railstep main->extra=$frstep (expect 220 / 212)"

# (4) explicit list: the FIXED 200px rail step differs from the fr step, and the
#     rail step isolates the 20px column-gap on top of the known 200px track.
if [ "$railstep" -eq 220 ] && [ "$frstep" -eq 212 ]; then
    echo "[hb-grid] PASS explicit '200px 1fr 1fr' + 20px column-gap (fixed rail 200+20, fr 192+20)"
else
    echo "[hb-grid] FAIL shell track/gap geometry (rail=$railstep fr=$frstep)"; fail=1
fi

# (5) the two fr panels are EQUAL width and the fixed rail is WIDER (FILL boxes).
#     FILL top bot lx rx #f7f7f7 -> width = rx-lx, sorted left-to-right.
readarray -t PW < <(grep -E "FILL .* #f7f7f7" "$D" | sort -k4 -n | awk '{print $5-$4}')
echo "[hb-grid] shell panel widths (px): ${PW[*]}"
if [ "${#PW[@]}" -eq 3 ] && [ "${PW[1]}" -eq "${PW[2]}" ] && [ "${PW[0]}" -gt "${PW[1]}" ]; then
    echo "[hb-grid] PASS fixed rail wider than the two equal fr panels (${PW[0]} > ${PW[1]}=${PW[2]})"
else
    echo "[hb-grid] FAIL shell panel widths (${PW[*]:-none})"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-grid] RESULT: FAIL"; exit 1
fi
echo "[hb-grid] RESULT: PASS"
