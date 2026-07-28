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
if [ "${INSIDE:-}" = "#ffffff" ]; then
    echo "[hb-border] PASS interior just inside the border is white padding ($INSIDE)"
else
    echo "[hb-border] FAIL interior inside the border is not clean padding (inside=$INSIDE)"; fail=1
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
# hard-coded black; `inside` stays white because the sample lands in the reserved
# top-rule gutter ABOVE where the table's background-color fill begins.
if [ "${NB2:-0}" -ge 1 ] && [ "${EDGE2:-}" = "#a2a9b1" ] && [ "${INSIDE2:-}" = "#ffffff" ]; then
    echo "[hb-border] PASS floated infobox strokes a real border in its declared colour (n=$NB2 edge=$EDGE2 inside=$INSIDE2)"
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
