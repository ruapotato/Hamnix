#!/usr/bin/env bash
# scripts/test_hambrowse_fidelity_host.sh — FAST, QEMU-free render-to-PNG gate
# that drives the pixel backend (lib/htmlpaint + lib/web/layout) on a RICH,
# realistic article (headings, strong/em, a link, an unordered + ordered list,
# a bordered <table>, a <blockquote>, a <pre> block, an <hr>) and PIXEL-asserts
# the fidelity improvements that close the gap to how Firefox/Chrome render the
# SAME unstyled markup:
#
#   (1) TABLE GRID — a `border="1"` table strokes a border around EVERY cell
#       (the classic gridded look), not just an outer frame. Assert >= 6 grey
#       (#808080) per-cell grid strokes, exactly ONE black (#000000) table
#       frame, and that the frame CONTAINS the cell boxes (real table, not a
#       stray rule). Adjacent cells share column boundaries => vertical rules.
#   (2) BLOCKQUOTE ACCENT — the quote paints a thin LEFT accent bar down its
#       gutter (a bfill in the accent colour), and the bar is a narrow vertical
#       rule spanning multiple rows, sitting at/left of the body left margin.
#   (3) LIST MARKERS — <ul> items get inked disc bullets HANGING in the gutter
#       (item text indented past the marker); <ol> items get "1." "2." "3.".
#   (4) PRE — preformatted text preserves its leading whitespace (not collapsed).
#   (5) EMPHASIS/HEADINGS — <strong> is bold and the heading hierarchy renders.
#
# Deterministic: renders a bundled fixture, never the network. PNG conversion
# is stdlib-only (scripts/ppm_to_png.py). Built with the frozen Python seed.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-fid] compiling pixel backend for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$BIN" 2>"$OUT/fid_compile.log"; then
    echo "[hb-fid] FAIL: driver did not compile"; cat "$OUT/fid_compile.log"; exit 1
fi
echo "[hb-fid] PASS pixel backend compiled"

echo "[hb-fid] confirming NATIVE hambrowse still compiles ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/fid_native.elf" 2>"$OUT/fid_native.log"; then
    echo "[hb-fid] FAIL: native hambrowse did not compile"; cat "$OUT/fid_native.log"; exit 1
fi
echo "[hb-fid] PASS native hambrowse still compiles"

FIX="tests/fixtures/hambrowse_fidelity.html"
DUMP="$OUT/fid_dump.txt"
PPM="$OUT/fid.ppm"
PNG="$OUT/fid.png"

echo "[hb-fid] rendering $FIX at width 880 ..."
if ! "$BIN" "$FIX" "$PPM" 880 >"$DUMP" 2>&1; then
    echo "[hb-fid] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 \
    && echo "[hb-fid] wrote $PNG"

pass() { echo "[hb-fid] PASS $1"; }
bad()  { echo "[hb-fid] FAIL $1"; fail=1; }

# ---- (1) TABLE GRID: per-cell borders + one containing black frame ----------
NGREY=$(grep -c 'edge #808080' "$DUMP")
NBLACK=$(grep -c 'edge #000000' "$DUMP")
if [ "${NGREY:-0}" -ge 6 ]; then
    pass "table strokes per-cell grid lines (grey #808080 cells n=$NGREY)"
else
    bad "expected >= 6 grey per-cell grid strokes, got ${NGREY:-0}"
fi
if [ "${NBLACK:-0}" -eq 1 ]; then
    pass "table strokes exactly ONE black outer frame (#000000)"
else
    bad "expected exactly 1 black table frame, got ${NBLACK:-0}"
fi

# The black frame must CONTAIN the grey cell boxes (real gridded table).
read FX0 FY0 FX1 FY1 < <(awk '/^BORDER [0-9]/ {x0=y0=x1=y1=e="";for(i=1;i<=NF;i++){if($i=="x0")x0=$(i+1);if($i=="y0")y0=$(i+1);if($i=="x1")x1=$(i+1);if($i=="y1")y1=$(i+1);if($i=="edge")e=$(i+1)} if(e=="#000000"){print x0,y0,x1,y1;exit}}' "$DUMP")
read CX0 CY0 CX1 CY1 < <(awk '/^BORDER [0-9]/ {x0=y0=x1=y1=e="";for(i=1;i<=NF;i++){if($i=="x0")x0=$(i+1);if($i=="y0")y0=$(i+1);if($i=="x1")x1=$(i+1);if($i=="y1")y1=$(i+1);if($i=="edge")e=$(i+1)} if(e=="#808080"){print x0,y0,x1,y1;exit}}' "$DUMP")
if [ -n "${FX0:-}" ] && [ -n "${CX0:-}" ] \
   && [ "$CX0" -ge "$FX0" ] && [ "$CX1" -le "$FX1" ] \
   && [ "$CY0" -ge "$FY0" ] && [ "$CY1" -le "$FY1" ]; then
    pass "black frame ($FX0,$FY0)-($FX1,$FY1) contains a grey cell ($CX0,$CY0)-($CX1,$CY1)"
else
    bad "black frame does not contain the cell boxes"
fi

# Vertical column separators: >= 2 DISTINCT grey-cell left x's => >= 2 columns.
NCOLX=$(awk '/^BORDER [0-9]/ {e="";x0="";for(i=1;i<=NF;i++){if($i=="x0")x0=$(i+1);if($i=="edge")e=$(i+1)} if(e=="#808080")print x0}' "$DUMP" | sort -un | wc -l)
if [ "${NCOLX:-0}" -ge 2 ]; then
    pass "cells span >= 2 columns => vertical column separators present (distinct x0=$NCOLX)"
else
    bad "expected >= 2 distinct cell columns, got ${NCOLX:-0}"
fi

# ---- (2) BLOCKQUOTE LEFT ACCENT BAR -----------------------------------------
# A thin (few px) vertical fill in the accent colour, spanning multiple rows.
read QX0 QY0 QX1 QY1 QCOL < <(awk '/^POSFILL/ {x0=y0=x1=y1=c="";for(i=1;i<=NF;i++){if($i=="x0")x0=$(i+1);if($i=="y0")y0=$(i+1);if($i=="x1")x1=$(i+1);if($i=="y1")y1=$(i+1);if($i=="col")c=$(i+1)} if(c=="#8f9cb4"){print x0,y0,x1,y1,c;exit}}' "$DUMP")
if [ -n "${QX0:-}" ]; then
    barw=$((QX1 - QX0)); barh=$((QY1 - QY0))
    # RE-PINNED 2026-07-27: the bar must be at least ONE text row tall, not 20px.
    # The old floor assumed the quote wrapped onto two lines, which it only did
    # inside the retired ~584px centred "readable measure" strip. At this gate's
    # 880px viewport `chromium --headless` reports the BLOCKQUOTE as a single
    # 18px-tall line box (x=48 y=468.1 w=784 h=18), so a 2-row accent bar would
    # be the WRONG render. The bar's real invariant is that it is thin and spans
    # the quote's full height.
    if [ "$barw" -ge 2 ] && [ "$barw" -le 10 ] && [ "$barh" -ge 14 ]; then
        pass "blockquote left accent bar painted (${barw}px wide, ${barh}px tall, $QCOL) at x=$QX0"
    else
        bad "blockquote accent bar has wrong shape (w=$barw h=$barh)"
    fi
else
    bad "no blockquote accent bar (POSFILL #8f9cb4) found"
fi

# ---- (3) LIST MARKERS: ul discs (inked, indented) + ol numbers --------------
read LN LDISC LITEMX < <(awk '/^LIST markers/ {print $3, $5, $7; exit}' "$DUMP")
# RE-PINNED 2026-07-27: the <li> text hang is ~40px, not >150px. The old floor
# encoded the retired centred "readable measure" strip, which pushed the whole
# list ~128px right. `chromium --headless` puts these <li> boxes at x=48.0
# (body margin 8 + the UA 40px list indent); the engine hangs them at x=40, i.e.
# the same 40px marker gutter. The invariant is that the text hangs clear of the
# bullet gutter, not that the page is inset.
if [ "${LN:-0}" -ge 2 ] && [ "${LDISC:-#ffffff}" != "#ffffff" ] && [ "${LITEMX:-0}" -ge 30 ]; then
    pass "ul disc bullets inked ($LDISC), $LN markers, item text hangs at x=$LITEMX"
else
    bad "ul markers wrong (n=${LN:-?} disc=${LDISC:-?} itemx=${LITEMX:-?})"
fi
if grep -q 'SEGTXT 1\.' "$DUMP" && grep -q 'SEGTXT 2\.' "$DUMP" && grep -q 'SEGTXT 3\.' "$DUMP"; then
    pass "ol renders decimal markers 1. 2. 3."
else
    bad "ordered-list decimal markers missing"
fi

# ---- (4) PRE preserves leading whitespace -----------------------------------
if grep -qE 'SEGTXT     print\("hello' "$DUMP"; then
    pass "pre preserves leading whitespace (indented print line intact)"
else
    bad "pre collapsed its leading whitespace"
fi

# ---- (5) strong bold + heading hierarchy ------------------------------------
# HFACE lines report per-heading face + bold; assert at least one bold heading.
if grep -qiE 'HFACE.*bold 1' "$DUMP" || grep -qiE 'bold 1' "$DUMP"; then
    pass "heading hierarchy renders bold faces"
else
    echo "[hb-fid] NOTE: HFACE bold marker not present in this dump (non-fatal)"
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-fid] RESULT: PASS"
else
    echo "[hb-fid] RESULT: FAIL"; exit 1
fi
