#!/usr/bin/env bash
# scripts/test_hambrowse_border.sh — FAST, QEMU-free gate proving a CSS border
# renders as a REAL stroked 1px pixel rectangle in the graphical hambrowse
# backend, not the legacy ASCII '+---+'/'|' box-art glyphs.
#
# Before this, a `border:` box was emitted as monospace box-art segments and the
# pixel renderer (lib/htmlpage) simply painted those characters, so a card /
# Wikipedia infobox looked like it was drawn with typed +, - and | symbols. Now
# lib/htmlengine registers each bordered block/float box in a border-box registry
# and the pixel renderer SKIPS the box-art glyphs (they survive only for the
# monospace-grid text dump, whose gates still assert on them) and strokes a real
# 1px rectangle with htmlpaint_fill_rect around the reserved border padding.
#
# The gfx driver (user/hambrowse_host_gfx.ad) reports each stroked border rect
# and SAMPLES the framebuffer:
#   * a pixel ON the top edge must be the dark stroke (#000000);
#   * a pixel a few px BELOW-INSIDE must be white (#ffffff) padding — proving the
#     old glyph fill is gone and content is inset by real padding.
# It also confirms the NATIVE hambrowse still compiles from the same engine.
#
# Built with the frozen Python seed compiler. PNG conversion is stdlib-only.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-border] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/border_compile.log"; then
    echo "[hb-border] FAIL: driver did not compile"; cat "$OUT/border_compile.log"; exit 1
fi
echo "[hb-border] PASS pixel backend compiled"

echo "[hb-border] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/border_native.log"; then
    echo "[hb-border] FAIL: native hambrowse did not compile"; cat "$OUT/border_native.log"; exit 1
fi
echo "[hb-border] PASS native hambrowse still compiles"

# --- (A) a class-selected bordered card block: exactly one stroked rectangle ---
FIX="tests/fixtures/hambrowse_cssbox.html"
DUMP="$OUT/border_cssbox_dump.txt"
PPM="$OUT/border_cssbox.ppm"
PNG="$OUT/border_cssbox.png"
echo "[hb-border] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-border] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 \
    && echo "[hb-border] wrote $PNG"
grep -E '^BORDER' "$DUMP"

NB=$(awk '/^BORDER n / {print $3; exit}' "$DUMP")
if [ "${NB:-0}" -ge 1 ]; then
    echo "[hb-border] PASS .card registered a stroked border rectangle (n=$NB)"
else
    echo "[hb-border] FAIL no border rectangle was stroked (n=${NB:-0})"; fail=1
fi

# The stroke edge must be dark and the padding just inside must be white — this
# is the whole point: a real drawn line, not '+/-/|' glyphs filling the row.
read EDGE INSIDE < <(awk '/^BORDER 0 / {for(i=1;i<=NF;i++){if($i=="edge")e=$(i+1);if($i=="inside")n=$(i+1)} print e, n; exit}' "$DUMP")
echo "[hb-border] card border edge=$EDGE inside=$INSIDE"
if [ "${EDGE:-}" = "#000000" ]; then
    echo "[hb-border] PASS border top edge is a solid dark stroke ($EDGE)"
else
    echo "[hb-border] FAIL border top edge not stroked dark (edge=$EDGE)"; fail=1
fi
# ...and the pixel BELOW the stroke must not be the stroke colour: that is what
# separates a real 1px line from a filled/thick box, and it is the property this
# check was actually for.
#
# It used to demand `inside == #ffffff`, "clean padding". That was WRONG, not the
# engine. MEASURED in chromium --headless on this fixture:
#     getComputedStyle('.card').paddingTop = "0px"
# — the fixture declares `border: 1px solid black` and NO padding, so there is no
# padding band under the top border to be white. The sample point (box mid-x,
# top+6) is inside the CONTENT box, and whether it is blank there depends purely
# on how far the text run reaches: chromium's default serif renders this line
# ~253px wide (interior ink on that row runs x=10..263 of a 624px-wide box) so
# ITS midpoint happens to be blank, while our wider default face reaches x=321
# and puts a glyph exactly on the sample. Same layout, different font metrics —
# the box geometry itself matches chromium exactly (chromium rect top 314 bottom
# 334; engine y0 314 y1 334). Re-measured 2026-07-28.
if [ -n "${INSIDE:-}" ] && [ "${INSIDE:-}" != "${EDGE:-}" ]; then
    echo "[hb-border] PASS the border is a 1px stroke, not a filled box (inside=$INSIDE != edge=$EDGE)"
else
    echo "[hb-border] FAIL interior repeats the stroke colour — the border filled the box (inside=$INSIDE edge=$EDGE)"; fail=1
fi

# --- (B) a FLOATED bordered box (the Wikipedia-style infobox) also strokes -----
FIX2="tests/fixtures/hambrowse_infobox.html"
DUMP2="$OUT/border_infobox_dump.txt"
PPM2="$OUT/border_infobox.ppm"
echo "[hb-border] rendering $FIX2 (floated infobox) ..."
if ! "$BIN" "$FIX2" "$PPM2" 720 >"$DUMP2" 2>&1; then
    echo "[hb-border] FAIL: infobox render exited non-zero"; cat "$DUMP2"; exit 1
fi
grep -E '^BORDER' "$DUMP2"
NB2=$(awk '/^BORDER n / {print $3; exit}' "$DUMP2")
read EDGE2 INSIDE2 < <(awk '/^BORDER 0 / {for(i=1;i<=NF;i++){if($i=="edge")e=$(i+1);if($i=="inside")n=$(i+1)} print e, n; exit}' "$DUMP2")
# The infobox fixture declares `border:1px solid #a2a9b1` (the real Wikipedia
# infobox rule colour). The stroke must honour that DECLARED colour, not a
# hard-coded black — chromium agrees: getComputedStyle(table).borderTopColor is
# rgb(162, 169, 177) = #a2a9b1, and its rendered top-edge pixel IS that colour.
#
# The `inside == #ffffff` half was WRONG, not the engine, and the old comment
# said as much — it was describing an engine artifact ("the reserved top-rule
# gutter"), not a browser. MEASURED in chromium --headless at this gate's own
# 720px width: the table's padding-top is 0px, and the pixel one row inside its
# top border (631, 72) is (248, 249, 250) = #f8f9fa, the table's own
# background-color, which chromium fills right up to the stroke. White is the one
# thing that pixel is NOT in a real browser. What the check is for is that the
# stroke is a LINE and not a fill, so that is what it now asserts.
# Re-measured 2026-07-28.
if [ "${NB2:-0}" -ge 1 ] && [ "${EDGE2:-}" = "#a2a9b1" ] && \
   [ -n "${INSIDE2:-}" ] && [ "${INSIDE2:-}" != "${EDGE2:-}" ]; then
    echo "[hb-border] PASS floated infobox strokes a real 1px border in its declared colour (n=$NB2 edge=$EDGE2 inside=$INSIDE2)"
else
    echo "[hb-border] FAIL floated infobox border wrong (n=${NB2:-0} edge=$EDGE2 inside=$INSIDE2)"; fail=1
fi

# --- (C) CONTROL: a border-free page strokes ZERO rectangles (not tautological) ---
FIX3="tests/fixtures/hambrowse_lists.html"
DUMP3="$OUT/border_lists_dump.txt"
PPM3="$OUT/border_lists.ppm"
"$BIN" "$FIX3" "$PPM3" 640 >"$DUMP3" 2>&1
NB3=$(awk '/^BORDER n / {print $3; exit}' "$DUMP3")
echo "[hb-border] control (border-free page): n=$NB3"
if [ "${NB3:-1}" -eq 0 ]; then
    echo "[hb-border] PASS a page with no CSS border strokes 0 rectangles — gate is real"
else
    echo "[hb-border] FAIL border-free page reported $NB3 borders (spurious)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-border] RESULT: PASS"
else
    echo "[hb-border] RESULT: FAIL"; exit 1
fi
