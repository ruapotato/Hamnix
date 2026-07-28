#!/usr/bin/env bash
# scripts/test_hambrowse_website_host.sh — FAST, QEMU-free render-to-PNG gate for
# a REALISTIC modern SEARCH-RESULTS web page (header logo+nav+search, breadcrumb,
# a 220px filter SIDEBAR beside a flex:1 RESULTS column, product CARDS with image
# thumb + title + description + a badge/pill/price META row, and PAGINATION).
#
# WHY: driving the browser at a real 1000px window exposed two high-visual-impact
# flexbox divergences from Firefox/Chrome that hand-written 600px fixtures missed:
#
#   1. TWO-COLUMN COLLAPSE. `.filters{width:220px}` beside `.results{flex:1}` in a
#      `display:flex` row: the sidebar was sized by its (wide) CONTENT instead of
#      its declared width, overflowing the row so the flex:1 results column
#      collapsed to a right-edge SLIVER and every product card became a thin
#      vertical bar. Per CSS Flexbox §7.2.3 a flex item's `flex-basis:auto`
#      resolves to its used `width` — box.ad now seeds the basis from the item's
#      cascade width, so the sidebar holds 220px and results fills the rest.
#
#   2. FLEX ITEMS TOUCH / `gap` VANISHES. A flex item's main size was measured as
#      its bare GLYPH width, excluding padding+border, then PAINTED wider (padding
#      drawn outward) — so a padded badge/pill/nav-link/pager control overran into
#      the `gap` and its neighbour. box.ad now folds each item's horizontal
#      padding+border into its measured (border-box) main size, so neighbours are
#      spaced by their real width PLUS the author gap.
#
# It renders the fixture to a PPM/PNG via the pixel backend (lib/htmlpaint +
# lib/htmlpage) and PIXEL-asserts the region geometry straight from the paint
# stream — no QEMU boot. See docs/browser_w3c_conformance.md.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_website.html"
mkdir -p "$OUT"
fail=0

echo "[hb-web] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/web_gfx.log"; then
    echo "[hb-web] FAIL: pixel backend did not compile"; cat "$OUT/web_gfx.log"; exit 1
fi
echo "[hb-web] PASS pixel backend compiled -> $GFX"

# The native browser shares the engine; keep it compiling.
echo "[hb-web] confirming native hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/web_native.elf" 2>"$OUT/web_native.log"; then
    echo "[hb-web] FAIL: native hambrowse did not compile"; cat "$OUT/web_native.log"; exit 1
fi
echo "[hb-web] PASS native hambrowse still compiles"

DUMP="$OUT/web_dump.txt"
echo "[hb-web] rendering $FIX at width 1000 ..."
if ! "$GFX" "$FIX" "$OUT/web.ppm" 1000 >"$DUMP" 2>&1; then
    echo "[hb-web] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
python3 scripts/ppm_to_png.py "$OUT/web.ppm" "$OUT/web.png" >/dev/null 2>&1 \
    && echo "[hb-web] wrote $OUT/web.png"

pass() { echo "[hb-web] PASS $1"; }
bad()  { echo "[hb-web] FAIL $1"; fail=1; }

# First POSFILL fill rectangle whose paint colour == $1 -> "x0 x1" (empty if none).
# POSFILL n z Z x0 X0 y0 Y0 x1 X1 y1 Y1 col #c pix #p
box_for() {
    awk -v c="#$1" '
        $1=="POSFILL" {
            x0=""; x1=""; col="";
            for (i=1;i<=NF;i++){
                if($i=="x0") x0=$(i+1);
                else if($i=="x1") x1=$(i+1);
                else if($i=="col") col=$(i+1);
            }
            if(col==c){ print x0, x1; exit }
        }' "$DUMP"
}

# ---- (1) two-column layout does NOT collapse -------------------------------
# The filter sidebar (#ffffff card) is pinned to its declared ~220px width, and
# the results column's card thumb (#d7e2ee) sits to its RIGHT at a full,
# card-sized width (NOT a collapsed sliver).
read -r FX0 FX1 <<<"$(box_for ffffff)"
read -r TX0 TX1 <<<"$(box_for d7e2ee)"
if [ -n "$FX0" ] && [ -n "$FX1" ]; then
    FW=$((FX1 - FX0))
    if [ "$FW" -ge 180 ] && [ "$FW" -le 320 ]; then
        pass "filter sidebar holds its ~220px width (w=${FW}px, x=${FX0}..${FX1})"
    else
        bad "filter sidebar mis-sized (w=${FW}px; expected ~220-260, collapse/overflow)"
    fi
else
    bad "filter sidebar (#ffffff) not found in paint stream"
fi

if [ -n "$TX0" ] && [ -n "$TX1" ] && [ -n "$FX1" ]; then
    TW=$((TX1 - TX0))
    if [ "$TX0" -ge "$FX1" ] && [ "$TW" -ge 250 ]; then
        pass "results column fills the row beside the sidebar (thumb x0=${TX0} >= sidebar x1=${FX1}, w=${TW}px)"
    else
        bad "results column collapsed/mis-placed (thumb x0=${TX0} sidebar x1=${FX1} w=${TW}px)"
    fi
else
    bad "results card thumb (#d7e2ee) not found in paint stream"
fi

# ---- (2) flex items are spaced by border-box width + author gap -------------
# Controlled probe: two padded pills (padding:3px 9px == 18px horizontal) in a
# `display:flex; gap:8px` row. Firefox places the 2nd pill at
#   pill_x = badge_x + (glyphs + 18px padding) + 8px gap.
# Before the fix items were spaced by GLYPHS ONLY, so the 2nd pill started ~18px
# early and OVERLAPPED the 1st. Assert the 2nd pill clears the 1st's full padded
# box plus the gap.
cat > "$OUT/web_gap.html" <<'HTML'
<!doctype html><html><head><style>
body{margin:0;}
.meta{display:flex;gap:8px;}
.badge{background:#e3f0ff;padding:3px 9px;}
.pill{background:#e8f7ee;padding:3px 9px;}
</style></head><body>
<div class="meta"><span class="badge">Top rated</span><span class="pill">In stock</span></div>
</body></html>
HTML
"$GFX" "$OUT/web_gap.html" "$OUT/web_gap.ppm" 600 >"$OUT/web_gap.txt" 2>&1
GDUMP="$OUT/web_gap.txt"
gbox_for() { awk -v c="#$1" '$1=="POSFILL"{x0="";col="";for(i=1;i<=NF;i++){if($i=="x0")x0=$(i+1);else if($i=="col")col=$(i+1)} if(col==c){print x0;exit}}' "$GDUMP"; }
BADGE_X="$(gbox_for e3f0ff)"
PILL_X="$(gbox_for e8f7ee)"
if [ -n "$BADGE_X" ] && [ -n "$PILL_X" ]; then
    DELTA=$((PILL_X - BADGE_X))
    # CHROME-DERIVED WINDOW (re-pinned 2026-07-27). The old 92..104 window came
    # from MONOSPACE arithmetic ("Top rated" == 9 glyphs * 8px == 72 + 18 padding
    # + 8 gap == 98), but this assertion reads the POSFILL geometry of the PIXEL
    # backend, which lays the chip out with real PROPORTIONAL advances — the
    # mono estimate over-measures the label by ~13px and the window could never
    # be met. `chromium --headless` on this exact markup reports
    #   .badge x=0.0 w=78.6   .pill x=86.6
    # i.e. a second-item offset of 86.6px (= 60.6 proportional glyphs + 18px
    # padding + 8px gap). The engine lays it out at 85px, within 2px of Chrome.
    if [ "$DELTA" -ge 78 ] && [ "$DELTA" -le 95 ]; then
        pass "padded flex items are spaced by border-box width + gap (2nd pill +${DELTA}px, no overlap)"
    else
        bad "flex item spacing wrong (2nd pill +${DELTA}px; expected ~87 = Chrome 60.6 glyph + 18 pad + 8 gap)"
    fi
else
    bad "flex gap probe pills not found (badge_x=${BADGE_X:-?} pill_x=${PILL_X:-?})"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-web] RESULT: FAIL"; exit 1
fi
echo "[hb-web] RESULT: PASS"
