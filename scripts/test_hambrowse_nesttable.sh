#!/usr/bin/env bash
# scripts/test_hambrowse_nesttable.sh — FAST, QEMU-free gate proving hambrowse
# lays out and strokes NESTED tables: a <table> inside another table's <td> is
# laid out as its own table box within the parent cell, recursing to arbitrary
# depth, and EACH table's border strokes as a real 1px pixel rectangle (via the
# same border-box registry the CSS-border work introduced) — not just the outer.
#
# Before this, the engine had a single flat table context: a nested <table>
# clobbered the outer table's column model and the inner </table> reset
# table_active, so the remaining outer cells collapsed to plain flow and only
# the outer (if any) border was ever considered. Now lib/htmlengine pushes/pops
# a per-table context stack and registers a bbox per bordered table.
#
# The gfx driver (user/hambrowse_host_gfx.ad) reports each stroked border rect
# and SAMPLES the framebuffer (edge dark #000000, padding just inside white).
# This gate asserts:
#   * the nested fixture strokes >= 2 border rectangles (inner + outer);
#   * the inner rect is INSET strictly inside the outer rect (real containment);
#   * every sampled border edge is a solid dark stroke;
#   * CONTROL: the same table WITHOUT the inner <table> strokes exactly ONE
#     border — so the extra rectangle is proof of real nesting, not a tautology
#     (depth matters).
#
# Built with the frozen Python seed compiler; PNG conversion is stdlib-only.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-nest] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/nest_compile.log"; then
    echo "[hb-nest] FAIL: driver did not compile"; cat "$OUT/nest_compile.log"; exit 1
fi
echo "[hb-nest] PASS pixel backend compiled"

echo "[hb-nest] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/nest_native.log"; then
    echo "[hb-nest] FAIL: native hambrowse did not compile"; cat "$OUT/nest_native.log"; exit 1
fi
echo "[hb-nest] PASS native hambrowse still compiles"

# --- (A) NESTED table: >= 2 borders, inner strictly inside outer -------------
FIX="tests/fixtures/hambrowse_nesttable.html"
DUMP="$OUT/nest_dump.txt"
PPM="$OUT/nest.ppm"
PNG="$OUT/nest.png"
echo "[hb-nest] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-nest] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 \
    && echo "[hb-nest] wrote $PNG"
grep -E '^BORDER' "$DUMP"

NB=$(awk '/^BORDER n / {print $3; exit}' "$DUMP")
if [ "${NB:-0}" -ge 2 ]; then
    echo "[hb-nest] PASS nested table strokes >= 2 border rectangles (n=$NB)"
else
    echo "[hb-nest] FAIL expected >= 2 borders (inner + outer), got n=${NB:-0}"; fail=1
fi

# A bordered table now paints TWO kinds of border box: the black table FRAME
# (edge #000000, one per <table>) and the grey per-cell grid lines (edge
# #808080, one per <td>/<th> — the classic gridded look real browsers draw).
# The nested fixture must therefore stroke exactly TWO black frames (inner +
# outer) plus one grey box per cell; every black frame edge is a solid dark
# stroke and every cell edge is the medium-grey grid colour.
NFRAME=$(awk '/^BORDER [0-9]/ {for(i=1;i<=NF;i++) if($i=="edge" && $(i+1)=="#000000") c++} END{print c+0}' "$DUMP")
if [ "${NFRAME:-0}" -eq 2 ]; then
    echo "[hb-nest] PASS nested fixture strokes exactly 2 black table FRAMES (inner + outer)"
else
    echo "[hb-nest] FAIL expected 2 black table frames, got ${NFRAME:-0}"; fail=1
fi
# Every cell border edge is the grey grid colour (no stray colours).
BADCELL=$(awk '/^BORDER [0-9]/ {for(i=1;i<=NF;i++) if($i=="edge" && $(i+1)!="#000000" && $(i+1)!="#808080") c++} END{print c+0}' "$DUMP")
if [ "${BADCELL:-1}" -eq 0 ]; then
    echo "[hb-nest] PASS every border edge is a solid frame (#000000) or grid (#808080) stroke"
else
    echo "[hb-nest] FAIL $BADCELL border edge(s) were neither frame nor grid strokes"; fail=1
fi
# There must be at least one grey cell grid line (proves cells stroke borders).
NGRID=$(awk '/^BORDER [0-9]/ {for(i=1;i<=NF;i++) if($i=="edge" && $(i+1)=="#808080") c++} END{print c+0}' "$DUMP")
if [ "${NGRID:-0}" -ge 1 ]; then
    echo "[hb-nest] PASS bordered cells stroke grey grid lines (n=$NGRID)"
else
    echo "[hb-nest] FAIL expected >= 1 grey cell grid line, got ${NGRID:-0}"; fail=1
fi

# Of the two black table FRAMES, the inner (smaller-area) rectangle must be
# strictly INSET within the outer (larger-area) one. Pick the frames by their
# #000000 edge, then order by area.
read IX0 IY0 IX1 IY1 < <(awk '/^BORDER [0-9]/ { x0=y0=x1=y1=e="";for(i=1;i<=NF;i++){if($i=="x0")x0=$(i+1);if($i=="y0")y0=$(i+1);if($i=="x1")x1=$(i+1);if($i=="y1")y1=$(i+1);if($i=="edge")e=$(i+1)} if(e=="#000000"){ar=(x1-x0)*(y1-y0); if(best==""||ar<best){best=ar;R=x0" "y0" "x1" "y1}}} END{print R}' "$DUMP")
read OX0 OY0 OX1 OY1 < <(awk '/^BORDER [0-9]/ {x0=y0=x1=y1=e="";for(i=1;i<=NF;i++){if($i=="x0")x0=$(i+1);if($i=="y0")y0=$(i+1);if($i=="x1")x1=$(i+1);if($i=="y1")y1=$(i+1);if($i=="edge")e=$(i+1)} if(e=="#000000"){ar=(x1-x0)*(y1-y0); if(best==""||ar>best){best=ar;R=x0" "y0" "x1" "y1}}} END{print R}' "$DUMP")
echo "[hb-nest] inner rect=($IX0,$IY0)-($IX1,$IY1)  outer rect=($OX0,$OY0)-($OX1,$OY1)"
if [ -n "${IX0:-}" ] && [ -n "${OX0:-}" ] \
   && [ "$IX0" -ge "$OX0" ] && [ "$IX1" -le "$OX1" ] \
   && [ "$IY0" -gt "$OY0" ] && [ "$IY1" -lt "$OY1" ]; then
    echo "[hb-nest] PASS inner table border is inset strictly inside the outer cell"
else
    echo "[hb-nest] FAIL inner border not contained within the outer border"; fail=1
fi

# --- (B) CONTROL: the same table WITHOUT the inner <table> => exactly 1 border -
FIX2="tests/fixtures/hambrowse_nesttable_flat.html"
DUMP2="$OUT/nest_flat_dump.txt"
PPM2="$OUT/nest_flat.ppm"
echo "[hb-nest] rendering control $FIX2 (no nested table) ..."
"$BIN" "$FIX2" "$PPM2" 640 >"$DUMP2" 2>&1
grep -E '^BORDER n' "$DUMP2"
# The control has no nested <table>, so it must stroke exactly ONE black table
# FRAME (its cells still stroke grey grid lines — that is orthogonal to depth).
NF2=$(awk '/^BORDER [0-9]/ {for(i=1;i<=NF;i++) if($i=="edge" && $(i+1)=="#000000") c++} END{print c+0}' "$DUMP2")
if [ "${NF2:-0}" -eq 1 ]; then
    echo "[hb-nest] PASS un-nested control strokes exactly 1 black table frame — depth matters"
else
    echo "[hb-nest] FAIL control expected exactly 1 black frame, got n=${NF2:-0}"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-nest] RESULT: PASS"
else
    echo "[hb-nest] RESULT: FAIL"; exit 1
fi
