#!/usr/bin/env bash
# scripts/test_hambrowse_fullwidth_host.sh — FAST, QEMU-free render-to-PNG gate
# for the READABLE-MEASURE SCOPING contract (lib/web/state.ad + lib/web/layout/flow.ad).
#
# CHROME PARITY: Chrome/Firefox do NOT cap body width — plain prose runs the FULL
# viewport content width, and only the page's OWN CSS (a max-width column) narrows
# it. The engine matches this: the readable-measure gutter is DISABLED by default
# and re-enabled ONLY when the page (a) establishes an author layout context
# (display:flex / display:grid / position:absolute|fixed) — which already drives
# its own full-width layout — OR (b) declares its own `max-width` (g_page_maxwidth),
# the signal that the author WANTS a narrow centred reading column. A plain-prose
# page with NO author max-width renders EDGE-TO-EDGE like Chrome.
#
# This gate pixel-asserts ALL THREE halves of that contract at a wide (1000px) window:
#   (A) FULL-WIDTH LAYOUT: a display:flex page's full-bleed nav bar background spans
#       the whole window (NOT a 584px centred strip), and its 3-card flex row fills
#       the width with the rightmost card near the right edge.
#   (B) FULL-WIDTH PROSE: a plain unstyled <p>-only page with NO author max-width now
#       spans the FULL window edge-to-edge (left margin ~8px, right edge near the
#       window edge) — Chrome parity, the readable-measure cap no longer engages.
#   (C) AUTHOR MAX-WIDTH: a prose page that DECLARES its own max-width KEEPS a narrow
#       centred reading column (a left gutter, right edge well short of the window
#       edge) — proving g_page_maxwidth honours the author's narrow column.
#
# Renders via the pixel backend (lib/htmlpaint + lib/htmlpage) — no QEMU boot.
# See docs/browser_w3c_conformance.md.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
SITE="tests/fixtures/hambrowse_fullwidth_site.html"
PROSE="tests/fixtures/hambrowse_fullwidth_prose.html"
W=1000
mkdir -p "$OUT"
fail=0

echo "[hb-fw] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/fw_gfx.log"; then
    echo "[hb-fw] FAIL: pixel backend did not compile"; cat "$OUT/fw_gfx.log"; exit 1
fi
echo "[hb-fw] PASS pixel backend compiled -> $GFX"

# The native browser shares the engine; keep it compiling.
echo "[hb-fw] confirming native hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/fw_native.elf" 2>"$OUT/fw_native.log"; then
    echo "[hb-fw] FAIL: native hambrowse did not compile"; cat "$OUT/fw_native.log"; exit 1
fi
echo "[hb-fw] PASS native hambrowse still compiles"

pass() { echo "[hb-fw] PASS $1"; }
bad()  { echo "[hb-fw] FAIL $1"; fail=1; }

# POSFILL rects whose paint colour == $2 in dump $1 -> lines "x0 x1".
boxes_for() {
    awk -v c="#$2" '$1=="POSFILL"{x0="";x1="";col="";
        for(i=1;i<=NF;i++){if($i=="x0")x0=$(i+1);else if($i=="x1")x1=$(i+1);
        else if($i=="col")col=$(i+1)} if(col==c)print x0, x1}' "$1"
}

# ============================================================================
# (A) FULL-WIDTH: a display:flex page spans the whole window.
# ============================================================================
SD="$OUT/fw_site.txt"
echo "[hb-fw] rendering $SITE at width $W ..."
if ! "$GFX" "$SITE" "$OUT/fw_site.ppm" "$W" >"$SD" 2>&1; then
    echo "[hb-fw] FAIL: site render exited non-zero"; cat "$SD"; exit 1
fi
python3 scripts/ppm_to_png.py "$OUT/fw_site.ppm" "$OUT/fw_site.png" >/dev/null 2>&1 \
    && echo "[hb-fw] wrote $OUT/fw_site.png"

# The full-bleed nav bar background (#16324f) must span nearly the whole 1000px
# window — a left edge near 0 and a right edge near 1000 — NOT the 208..792 strip
# the old 584px readable gutter would have produced.
read -r NX0 NX1 <<<"$(boxes_for "$SD" 16324f | head -1)"
if [ -n "$NX0" ] && [ -n "$NX1" ]; then
    NW=$((NX1 - NX0))
    if [ "$NX0" -le 40 ] && [ "$NX1" -ge 950 ] && [ "$NW" -ge 900 ]; then
        pass "full-bleed nav spans the window (x=${NX0}..${NX1}, w=${NW}px >= 900, not a 584 strip)"
    else
        bad "nav bar not full-bleed (x=${NX0}..${NX1}, w=${NW}px; expected ~0..1000)"
    fi
else
    bad "nav bar background (#16324f) not found in paint stream"
fi

# The 3-card flex row (#d7e2ee) fills the width: three cards, the leftmost near
# the left edge and the rightmost near the right edge.
CARD_L=$(boxes_for "$SD" d7e2ee | awk '{print $1}' | sort -n | head -1)
CARD_R=$(boxes_for "$SD" d7e2ee | awk '{print $2}' | sort -n | tail -1)
NCARD=$(boxes_for "$SD" d7e2ee | wc -l)
if [ -n "$CARD_L" ] && [ -n "$CARD_R" ] && [ "$NCARD" -ge 3 ]; then
    if [ "$CARD_L" -le 40 ] && [ "$CARD_R" -ge 940 ]; then
        pass "3-card flex row fills the width (cards=${NCARD}, left=${CARD_L}, right=${CARD_R})"
    else
        bad "card row does not fill the width (left=${CARD_L}, right=${CARD_R}; expected ~24..~976)"
    fi
else
    bad "expected >=3 flex cards (#d7e2ee); found ${NCARD} (left=${CARD_L:-?} right=${CARD_R:-?})"
fi

# ============================================================================
# (B) FULL-WIDTH PROSE: a plain unstyled page with NO author max-width spans the
#     FULL window edge-to-edge (Chrome parity — the readable cap no longer engages).
# ============================================================================
PD="$OUT/fw_prose.txt"
echo "[hb-fw] rendering $PROSE at width $W ..."
if ! "$GFX" "$PROSE" "$OUT/fw_prose.ppm" "$W" >"$PD" 2>&1; then
    echo "[hb-fw] FAIL: prose render exited non-zero"; cat "$PD"; exit 1
fi
python3 scripts/ppm_to_png.py "$OUT/fw_prose.ppm" "$OUT/fw_prose.png" >/dev/null 2>&1 \
    && echo "[hb-fw] wrote $OUT/fw_prose.png"

# No author max-width -> no gutter: the left content margin (UAELEM ddx) is the
# bare ~8px CONTENT_X and the rightmost text x (REFLOW maxx) runs near the 1000px
# window edge, exactly like Chrome renders unstyled body prose.
DDX=$(grep -oE "ddx [0-9]+" "$PD" | head -1 | awk '{print $2}')
MAXX=$(grep -E "^REFLOW " "$PD" | awk '{for(i=1;i<=NF;i++) if($i=="maxx") print $(i+1)}' | head -1)
echo "[hb-fw] prose column: left-margin ddx=${DDX:-?} right-edge maxx=${MAXX:-?} (window ${W}px)"
if [ -n "$DDX" ] && [ "$DDX" -le 24 ]; then
    pass "no-max-width prose spans full width (left margin ddx=${DDX}px ~= 8px CONTENT_X, no gutter)"
else
    bad "prose left margin not edge-to-edge (ddx=${DDX:-?}; expected ~8px, no readable gutter)"
fi
if [ -n "$MAXX" ] && [ "$MAXX" -ge 900 ]; then
    pass "no-max-width prose runs to the window edge (right edge maxx=${MAXX}px ~ ${W}px, not a 584 strip)"
else
    bad "prose not full-width (maxx=${MAXX:-?}; expected near the ${W}px edge, Chrome parity)"
fi

# ============================================================================
# (C) AUTHOR MAX-WIDTH: a prose page that declares its OWN max-width keeps a
#     narrow centred reading column (g_page_maxwidth honours the author intent).
# ============================================================================
PMW="tests/fixtures/hambrowse_fullwidth_prose_maxw.html"
PMD="$OUT/fw_prose_maxw.txt"
echo "[hb-fw] rendering $PMW at width $W ..."
if ! "$GFX" "$PMW" "$OUT/fw_prose_maxw.ppm" "$W" >"$PMD" 2>&1; then
    echo "[hb-fw] FAIL: max-width prose render exited non-zero"; cat "$PMD"; exit 1
fi
python3 scripts/ppm_to_png.py "$OUT/fw_prose_maxw.ppm" "$OUT/fw_prose_maxw.png" >/dev/null 2>&1 \
    && echo "[hb-fw] wrote $OUT/fw_prose_maxw.png"

# The author max-width re-engages the readable measure: a centring left gutter
# (>> the bare 8px CONTENT_X) and a right edge well short of the 1000px window.
MDDX=$(grep -oE "ddx [0-9]+" "$PMD" | head -1 | awk '{print $2}')
MMAXX=$(grep -E "^REFLOW " "$PMD" | awk '{for(i=1;i<=NF;i++) if($i=="maxx") print $(i+1)}' | head -1)
echo "[hb-fw] max-width prose column: left-gutter ddx=${MDDX:-?} right-edge maxx=${MMAXX:-?} (window ${W}px)"
if [ -n "$MDDX" ] && [ "$MDDX" -ge 150 ] && [ "$MDDX" -le 260 ]; then
    pass "author-max-width prose keeps a centring left gutter (ddx=${MDDX}px, not 8px edge-to-edge)"
else
    bad "max-width prose gutter wrong (ddx=${MDDX:-?}; expected ~208 = 8 + (984-584)/2)"
fi
if [ -n "$MMAXX" ] && [ "$MMAXX" -le 810 ] && [ "$MMAXX" -ge 560 ]; then
    pass "author-max-width prose keeps the ~584px readable measure (right edge maxx=${MMAXX}px << 1000)"
else
    bad "max-width prose measure not capped (maxx=${MMAXX:-?}; expected ~584..792, NOT the ${W}px edge)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-fw] RESULT: FAIL"; exit 1
fi
echo "[hb-fw] RESULT: PASS"
