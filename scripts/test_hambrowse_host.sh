#!/usr/bin/env bash
# scripts/test_hambrowse_host.sh — FAST, QEMU-free gate for the hambrowse
# HTML engine (lib/htmlengine.ad) via the x86_64-linux host harness
# (user/hambrowse_host.ad).
#
# The native browser render gate (scripts/test_de_browser.sh) needs a full
# installer-image boot (~6 min). This gate compiles the SAME parse+layout+
# colour engine for the host Linux target and runs it directly on a local
# HTML fixture in milliseconds — so the engine can be regression-tested
# without QEMU. It asserts the layout summary, the wrapped-text FLOW, and
# the CSS-colour rung (style="color:" / <font color> / named + hex, with
# links staying link-blue).
#
# Builds with the frozen Python seed compiler (always compiles 100% of the
# tree; no self-host bootstrap needed) so this gate is dependency-light.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_colors.html"
mkdir -p "$OUT"

echo "[hb-host] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-host] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-host] PASS host harness compiled -> $BIN"

# Confirm the NATIVE target still compiles from the same engine (no regress).
echo "[hb-host] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-host] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-host] PASS native hambrowse still compiles"

echo "[hb-host] running host harness on $FIX ..."
DUMP="$OUT/dump.txt"
if ! "$BIN" "$FIX" 600 >"$DUMP" 2>&1; then
    echo "[hb-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

fail=0
assert_grep() {
    local pat="$1" msg="$2"
    if grep -q -- "$pat" "$DUMP"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# Layout produced content + a link.
if grep -Eq 'LAYOUT segs=[1-9][0-9]* rows=[1-9][0-9]* links=[1-9]' "$DUMP"; then
    echo "[hb-host] PASS layout produced segments/rows/links"
else
    echo "[hb-host] FAIL layout summary missing content"; fail=1
fi

# Wrapped-text FLOW reconstructs the page.
assert_grep 'FLOW  Green Heading' "flow shows the heading text"
assert_grep 'red span and' "flow shows inline coloured words in-line"

# CSS colour rung: each colour form resolves correctly.
assert_grep '#00aa00 b1 .*|Green Heading|'        "h1 style=color:#0a0 -> green (3-digit hex expanded)"
assert_grep '#ff0000 .*| red span|'               "span style=color:red -> #ff0000"
assert_grep '#0000ff .*| blue font|'              "font color=blue -> #0000ff"
assert_grep '#800080 .*|Whole purple'             "p style=color:#800080 -> purple"
assert_grep '#008080 .*|teal item|'               "font color=teal -> #008080"
assert_grep '#ffa500 .*| inside orange|'          "span style=color:orange -> #ffa500"

# Links keep their role colour even adjacent to a coloured span, and default
# text is body-black.
assert_grep '#1a4fd0 b0 u1 s0 l0 bg- | blue link|'   "link stays link-blue (#1a4fd0), underlined, link id 0"
assert_grep '#101010 .*|Plain body text'          "uncoloured text stays body-black (#101010)"

# Background-colour rung: bgcolor / background-color fill the box BEHIND the
# text (seg bg field) without changing the TEXT colour.
#   * bgcolor="yellow" paragraph: text body-black, bg #ffff00.
#   * <span style="background-color:#ffff00"> highlight: text body-black, bg yellow.
assert_grep '#101010 b0 u0 s0 l-1 bg#ffff00 |bgcolor is not text color.|' \
    "p bgcolor=yellow -> body-black text on yellow bg"
assert_grep '#101010 b0 u0 s0 l-1 bg#ffff00 | highlight|' \
    "span background-color:#ffff00 -> body-black text on yellow bg"
# The TEXT-colour field (immediately after 'SEG row x ') must never be yellow:
# that would mean bgcolor leaked into the text colour (word-boundary failure).
if grep -Eq '^SEG [0-9]+ [0-9]+ #ffff00' "$DUMP"; then
    echo "[hb-host] FAIL bgcolor was mistaken for text color"; fail=1
else
    echo "[hb-host] PASS bgcolor not mistaken for text color (word boundary)"
fi

# ====================================================================
# BOX-MODEL fixture — <hr>, <blockquote> indent, <h4>-<h6>.
# ====================================================================
FIX2="tests/fixtures/hambrowse_boxmodel.html"
DUMP2="$OUT/dump_boxmodel.txt"
echo "[hb-host] running host harness on $FIX2 ..."
if ! "$BIN" "$FIX2" 600 >"$DUMP2" 2>&1; then
    echo "[hb-host] FAIL: box-model harness exited non-zero"; cat "$DUMP2"; exit 1
fi
cat "$DUMP2"

assert_grep2() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP2"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# <h1> still lays a heading rule (type 1); <hr> lays a distinct type-2 rule.
assert_grep2 '^RULE row 0 type 1$'      "h1 emits a heading rule (type 1)"
assert_grep2 '^RULE row [0-9]+ type 2$' "hr emits a full-width rule (type 2)"
# The <hr> row must be otherwise empty (no segment sits on the rule's row).
hr_row=$(grep -E '^RULE row [0-9]+ type 2$' "$DUMP2" | head -1 | awk '{print $3}')
if [ -n "$hr_row" ] && grep -Eq "^SEG $hr_row " "$DUMP2"; then
    echo "[hb-host] FAIL hr rule row $hr_row is not empty"; fail=1
else
    echo "[hb-host] PASS hr rule sits on its own empty row (row $hr_row)"
fi
# <blockquote> content is indented from the body left margin (x 8 -> 32).
assert_grep2 '^SEG [0-9]+ 32 .*Quoted text that is indented' \
    "blockquote indents content to x=32"
# Text before/after the blockquote stays at the x=8 body margin.
assert_grep2 '^SEG [0-9]+ 8 .*Back to the left margin' \
    "post-blockquote text returns to the x=8 margin"
# <h4>/<h5>/<h6> render as body-colour bold headings (Chrome UA default: no blue), NO rule row.
assert_grep2 '^SEG [0-9]+ 8 #101010 b1 .*Sub sub heading'  "h4 -> body-colour bold heading"
assert_grep2 '^SEG [0-9]+ 8 #101010 b1 .*Smaller heading'  "h5 -> body-colour bold heading"
assert_grep2 '^SEG [0-9]+ 8 #101010 b1 .*Smallest heading' "h6 -> body-colour bold heading"

# <img> PIXEL rung: an <img> is now a real image BOX on its own block row (the
# pixel renderer blits the decoded PNG into it — see scripts/test_hambrowse_img.sh).
# In this monospace-grid dump the image box carries the bracketed alt text as a
# glyph fallback ("[alt]", or "[img]" when no alt), on its own row, with the
# surrounding prose flowing above and below it.
assert_grep2 '^SEG [0-9]+ 8 .*\|\[Hamnix logo\]\|' \
    "img alt='Hamnix logo' -> [Hamnix logo] image-box fallback on its own row"
assert_grep2 '^SEG [0-9]+ 8 .*\|\[img\]\|' \
    "bare img (no alt) -> [img] image-box fallback on its own row"
assert_grep2 '\|Logo here:\|'      "prose before the image still renders"
assert_grep2 '\|and text after\.\|' "prose after the image still renders"

# ====================================================================
# TABLE fixture — two-pass column layout (measure widest cell per column,
# then place), <th> bold, per-cell colour + background.
# ====================================================================
FIX3="tests/fixtures/hambrowse_table.html"
DUMP3="$OUT/dump_table.txt"
echo "[hb-host] running host harness on $FIX3 ..."
if ! "$BIN" "$FIX3" 600 >"$DUMP3" 2>&1; then
    echo "[hb-host] FAIL: table harness exited non-zero"; cat "$DUMP3"; exit 1
fi
cat "$DUMP3"

assert_grep3() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP3"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# Column x-positions are computed from each column's WIDEST cell using the
# PROPORTIONAL glyph-advance model (lib/web/layout/tables.ad::_adv8/_measure_table,
# commit 73ad044e "match Chrome cell height + proportional column widths",
# table SSIM 0.36->0.56). A column's char width = ceil(sum_of_glyph_advances /
# CELL_W); cell text is then inset CELL_PADX=6px from the column's left border.
#   col0 "Blueberry": adv sum 78px -> ceil(78/8)=10 cells -> next col at
#         8+(10+2)*8 = 104          (the old monospace model counted 9 chars -> 96)
#   col1 "Colour"(bold th): adv sum 58px -> ceil(58/8)=8 cells -> next col at
#         104+(8+2)*8 = 184
# Cell text starts at col_x + 6 (the 6px inset): col0 -> 14, col1 -> 110,
# col2 -> 190. Header + every body row share these exact inset column x's.
# NOTE: the earlier expected x's (col1=102, col2=182) predate the proportional
# model (they encoded the old monospace char-count of b16501c4) and were STALE;
# updated to the proportional Chrome-matching x's. Chrome renders this fixture's
# col0:col1 border-box width ratio as 68:52 = 1.31 (measured via
# getBoundingClientRect); the proportional model's 96:80 = 1.20 tracks that far
# closer than the old monospace 88:80 = 1.10 (see build/framediff_gfx/table/
# sxs_chromium.png for the pixel columns aligning with Chrome).
assert_grep3 '^SEG 2 14 #101010 b1 .*Fruit\|'   "th 'Fruit' bold at col0 (x=14, 6px inset)"
assert_grep3 '^SEG 2 110 #101010 b1 .*Colour\|' "th 'Colour' bold at col1 (x=110, proportional col width)"
assert_grep3 '^SEG 2 190 #101010 b1 .*Qty\|'    "th 'Qty' bold at col2 (x=190)"
assert_grep3 '^SEG 3 14 #101010 b0 .*Apple\|'   "td 'Apple' plain at col0 (x=14, aligned to header)"
assert_grep3 '^SEG 3 110 #101010 b0 .*red\|'    "td 'red' at col1 (x=110, aligned to header)"
assert_grep3 '^SEG 3 190 #101010 b0 .*12\|'     "td '12' at col2 (x=190, aligned to header)"
assert_grep3 '^SEG 4 110 #101010 b0 .*blue\|'   "wide row 'Blueberry' keeps col1 at x=110"
# Per-cell colour + background survive the padded column placement.
assert_grep3 '^SEG 6 14 #101010 b0 u0 s0 l-1 bg#c0c0c0 .*Lime\|' "td bgcolor=silver fills the cell (#c0c0c0)"
assert_grep3 '^SEG 6 110 #008000 .*green\|'                   "font color=green inside a cell -> #008000"
# Cell text must sit strictly INSIDE the cell's left border (x>col_x): col0's
# border is at x=8, so no cell text may start at x<=8 — proving the padding.
if grep -Eq '^SEG [2-6] 8 #' "$DUMP3"; then
    echo "[hb-host] FAIL a cell drew text flush on the col0 border (x=8, no pad)"; fail=1
else
    echo "[hb-host] PASS every cell's text is inset from the col0 border (none at x=8)"
fi
# The FLOW reconstruction shows the columns aligned as a grid (bold-header col
# widened so "Colour" is not cramped against "Qty").
assert_grep3 '^FLOW  Fruit       Colour    Qty$'  "FLOW renders the header row as aligned columns"
assert_grep3 '^FLOW  Blueberry   blue      340$'  "FLOW renders the wide row aligned to the same columns"

# ====================================================================
# BLOCK-MARGIN fixture — CSS margin-left/padding-left shift a <p>/<div>'s
# content column (not just decorate it). Body margin = CONTENT_X = 8.
#   margin-left:32px            -> x = 8 + 32       = 40
#   margin-left:16 + padding:16 -> x = 8 + 16 + 16  = 40
#   outer div margin-left:24px, inner <p> none -> inherits 8 + 24 = 32
# and the indent POPS back to 8 once the blocks close.
# ====================================================================
FIXM="tests/fixtures/hambrowse_margin.html"
DUMPM="$OUT/dump_margin.txt"
echo "[hb-host] running host harness on $FIXM ..."
if ! "$BIN" "$FIXM" 600 >"$DUMPM" 2>&1; then
    echo "[hb-host] FAIL: margin harness exited non-zero"; cat "$DUMPM"; exit 1
fi
cat "$DUMPM"

assert_grepM() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMPM"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

assert_grepM '^SEG 0 8 .*Flush left paragraph'          "no-margin p flows at body margin x=8"
assert_grepM '^SEG 2 40 .*Indented block shifted'       "div margin-left:32px shifts content to x=40"
# Margin-less <div> blocks pack ADJACENTLY (no inter-div paragraph gap — matches
# real browsers), so these land on consecutive rows 2..5; the trailing <p>
# re-gaps at row 7. Row indices track the (correct) tight block spacing; the
# x-positions remain the box-model assertion.
assert_grepM '^SEG 3 40 .*Margin plus padding'          "margin-left:16 + padding-left:16 -> x=40"
assert_grepM '^SEG 4 32 .*Nested paragraph inherits'    "nested p inherits outer div indent (x=32)"
assert_grepM '^SEG 5 32 .*own\.'                         "wrapped line of the nested block stays at x=32"
assert_grepM '^SEG 7 8 .*Back flush at the body margin' "indent pops back to x=8 after blocks close"

# ====================================================================
# COLSPAN fixture — <thead>/<tbody> wrappers (transparent) + colspan cells.
# Columns are sized by the single-span cells only; bold <th>s reserve ~1/3
# extra chars and every cell's text is inset CELL_PADX=6px from its border:
#   col0 "Region"(th)  -> x=8,  next 8+(8+2)*8   = 88 ; text at 8+6  = 14
#   col1 "Q1"(bold th) -> x=88, PROPORTIONAL adv -> 4 cells: next 88+(4+2)*8 = 136;
#                         text at 88+6 = 94
#   col2 "Q2"(bold th) -> x=136, text at 136+6 = 142
# NOTE: col2's earlier expected x=134 (and col1's 3-cell width) predate the
# proportional glyph-advance column model (commit 73ad044e); "Q1" bold measures
# just over 3 cells so its column rounds up to 4, shifting col2 text from 134 to
# 142. Updated to the proportional Chrome-matching x (same model that renders the
# table fixture's columns aligned with Chrome, build/framediff_gfx/table/).
# A colspan=2 cell starts at col1 (text x=94) and its right edge is col_x[3]
# (spanning col1+col2), so its text flows across BOTH columns' width; a
# colspan=3 cell starts at col0 (text x=14) and spans the whole table.
# ====================================================================
FIXS="tests/fixtures/hambrowse_span.html"
DUMPS="$OUT/dump_span.txt"
echo "[hb-host] running host harness on $FIXS ..."
if ! "$BIN" "$FIXS" 600 >"$DUMPS" 2>&1; then
    echo "[hb-host] FAIL: span harness exited non-zero"; cat "$DUMPS"; exit 1
fi
cat "$DUMPS"

assert_grepS() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMPS"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# thead/tbody are transparent: the header <th>s size the columns and the
# body <td>s align to the SAME x-positions across the wrapper boundary.
assert_grepS '^SEG 2 14 #101010 b1 .*Region\|'  "th 'Region' bold at col0 (x=14, thead transparent)"
assert_grepS '^SEG 2 94 #101010 b1 .*Q1\|'      "th 'Q1' bold at col1 (x=94)"
assert_grepS '^SEG 2 142 #101010 b1 .*Q2\|'     "th 'Q2' bold at col2 (x=142)"
assert_grepS '^SEG 3 14 #101010 b0 .*North\|'   "tbody td 'North' aligns to col0 (x=14)"
assert_grepS '^SEG 3 94 #101010 b0 .*10\|'      "tbody td '10' aligns to col1 (x=94)"
assert_grepS '^SEG 3 142 #101010 b0 .*20\|'     "tbody td '20' aligns to col2 (x=142)"
# colspan=2: cell starts at col1 (x=94) and wraps within the SPANNED right edge
# (col_x[3]) — its text flows across col1+col2, not col1's own 3 chars.
assert_grepS '^SEG 4 14 #101010 b0 .*Totals\|'  "row: single-span 'Totals' at col0 (x=14)"
assert_grepS '^SEG 4 94 #101010 b0 .*All\|'     "colspan=2 cell starts at col1 (x=94), spans col1+col2"
assert_grepS '^SEG [5-6] 94 #101010 b0 .*quarters\|' "colspan=2 body wraps inside the spanned width"
# colspan=3: cell starts at col0 (x=14) and spans the whole table width.
assert_grepS '^SEG [0-9]+ 14 #101010 b0 .*Grand total across\|' "colspan=3 cell starts at col0 (x=14) across full width"
# The single-span columns were NOT inflated by the spanning cells' long text
# (col2 text stays at x=142 from the header widths, not pushed further right by
# the colspan cells' long "All quarters combined" / "Grand total ..." text).
if grep -Eq '^SEG 2 142 ' "$DUMPS"; then
    echo "[hb-host] PASS spanning cells do not inflate single-span column widths"
else
    echo "[hb-host] FAIL spanning cell inflated a column width"; fail=1
fi

# ====================================================================
# LIST fixture — <ul>/<ol>/<li> markers, ordered numbering, <ol start=>,
# nesting, and hanging indent (marker in the gutter, item text + wrapped
# continuation lines aligned one level in).
#   level 1 text indent = CONTENT_X(8) + 1*LIST_STEP(32) = 40
#   level 2 text indent = 8 + 2*32                       = 72
# The marker hangs at (text_indent - LIST_STEP): level1 -> x=8, level2 -> x=40.
# ====================================================================
FIXL="tests/fixtures/hambrowse_lists.html"
DUMPL="$OUT/dump_lists.txt"
echo "[hb-host] running host harness on $FIXL ..."
if ! "$BIN" "$FIXL" 600 >"$DUMPL" 2>&1; then
    echo "[hb-host] FAIL: lists harness exited non-zero"; cat "$DUMPL"; exit 1
fi
cat "$DUMPL"

assert_grepL() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMPL"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# <ul> item: '-' bullet in the gutter at x=8, item text hanging at x=40.
assert_grepL '^SEG 2 8 #101010 b0 u0 s0 l-1 bg- \|-\|$'      "ul bullet marker '-' hangs at x=8"
assert_grepL '^SEG 2 40 #101010 b0 u0 s0 l-1 bg- \|Apples\|' "ul item text hangs at x=40 (one level in)"
# A long item wraps and the continuation line aligns under the TEXT (x=40),
# NOT back under the marker — this is the hanging indent.
assert_grepL '^SEG 3 40 .*certainly wrap across the\|$'    "long ul item wraps at the text column"
assert_grepL '^SEG 4 40 .*available line width so we can check hanging indentation\|' \
    "wrapped continuation line aligns at x=40 (hanging indent, not x=8)"
# <ol> items number 1./2./3. in the gutter, text hanging at x=40.
# NOTE: each mid-document <h3> follows a list, and its UA top margin COLLAPSES
# with that list's bottom margin (Chrome-parity margin collapsing) — one gap row
# at the boundary, not two. So the ol block sits one row higher than the old
# double-gap layout (row 9, not 10), and the nested block — below two collapsed
# heading boundaries — sits two rows higher (row 15, not 17). The x columns
# (marker gutter x=8/40, text x=40/72) are unchanged; only the row indices moved.
assert_grepL '^SEG 9 8 #101010 b0 u0 s0 l-1 bg- \|1\.\|'   "ol first item numbered '1.' at x=8"
assert_grepL '^SEG 9 40 .*Preheat\|'                     "ol item text hangs at x=40"
assert_grepL '^SEG 10 8 .*\|2\.\|'                        "ol second item numbered '2.'"
assert_grepL '^SEG 11 8 .*\|3\.\|'                        "ol third item numbered '3.'"
# Nested <ol> inside a <ul> item: outer '-' at x=8, inner '1.'/'2.' one level
# deeper (marker at x=40, text at x=72), and the inner counter restarts at 1.
assert_grepL '^SEG 15 8 .*\|-\|'      "nested: outer ul bullet at x=8"
assert_grepL '^SEG 15 40 .*Fruit\|'   "nested: outer ul item text at x=40"
assert_grepL '^SEG 16 40 .*\|1\.\|'   "nested: inner ol marker '1.' hangs at x=40"
assert_grepL '^SEG 16 72 .*Apple\|'   "nested: inner ol item text hangs at x=72"
assert_grepL '^SEG 17 40 .*\|2\.\|'   "nested: inner ol counter continues to '2.'"
# <ol start="10"> seeds the counter: items number 10./11.
assert_grepL '^SEG [0-9]+ 8 .*\|10\.\|'  "ol start=10 -> first item numbered '10.'"
assert_grepL '^SEG [0-9]+ 8 .*\|11\.\|'  "ol start=10 -> second item numbered '11.'"
# FLOW reconstruction shows the marker + hanging text.
assert_grepL '^FLOW  -   Apples$'    "FLOW shows ul bullet + item"
assert_grepL '^FLOW  1\.  Preheat$'  "FLOW shows ol number + item"

# ====================================================================
# CSS-CASCADE fixture — <style> rules with element/.class/#id/descendant
# selectors + specificity, font-weight, text-align (baked into seg_x),
# display:none, rgb()/named colours, and inline style="" overriding the sheet.
# ====================================================================
FIX4="tests/fixtures/hambrowse_css.html"
DUMP4="$OUT/dump_css.txt"
echo "[hb-host] running host harness on $FIX4 ..."
if ! "$BIN" "$FIX4" 600 >"$DUMP4" 2>&1; then
    echo "[hb-host] FAIL: css harness exited non-zero"; cat "$DUMP4"; exit 1
fi
cat "$DUMP4"

assert_grep4() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP4"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# element `h1 { color:navy; text-align:center }` — navy + bold heading whose
# row is shifted right of the x=8 margin by the centring post-pass.
assert_grep4 '^SEG 0 (1[0-9][0-9]|[2-9][0-9][0-9]) #000080 b1 .*Centered Title\|' \
    "h1 style rule -> navy bold, centred (seg_x shifted right of margin)"
# #id beats element: rgb(0,128,0) green wins over p{color:#333}.
assert_grep4 '^SEG [0-9]+ 8 #008000 .*Lead paragraph green' \
    "#lead id rule with rgb() -> green (#008000), beats p element rule"
# element rule p{color:#333}.
assert_grep4 '^SEG [0-9]+ 8 #333333 b0 .*Normal gray paragraph' \
    "p element rule -> gray (#333333)"
# .class beats element; font-weight:bold applies.
assert_grep4 '^SEG [0-9]+ 8 #ff0000 b1 .*Warning bold red' \
    ".warn class rule -> red + font-weight:bold (beats p element rule)"
# descendant `div p { background-color:yellow }` — bg fills, text stays p-gray.
assert_grep4 '^SEG [0-9]+ 8 #333333 b0 u0 s0 l-1 bg#ffff00 .*Nested para on yellow' \
    "div p descendant rule -> yellow background, gray text"
# text-align:right baked into seg_x (line pushed to the right edge).
assert_grep4 '^SEG [0-9]+ ([4-9][0-9][0-9]) .*Right aligned line' \
    ".box text-align:right -> line shifted to the right edge"
# display:none — the hidden paragraph produces NO segment.
if grep -q 'should not see' "$DUMP4"; then
    echo "[hb-host] FAIL display:none did not skip the element"; fail=1
else
    echo "[hb-host] PASS display:none skips the element (no segment emitted)"
fi
# flow continues after a display:none element (skip terminated correctly).
assert_grep4 '^SEG [0-9]+ 8 #333333 .*Visible after hidden line' \
    "content after display:none still renders (skip name NUL-terminated)"
# inline style="" colour (rgb()) overrides the element sheet rule.
assert_grep4 '^SEG [0-9]+ 8 #0a14c8 .*Inline rgb override wins' \
    "inline style rgb(10,20,200) overrides p{color:#333}"
# inline style="text-align:center" also shifts seg_x.
assert_grep4 '^SEG [0-9]+ (1[0-9][0-9]|[2-9][0-9][0-9]) .*Inline centered paragraph' \
    "inline text-align:center -> centred line"

# ====================================================================
# CSS-BOX-MODEL fixture — margin/padding/width/border driven by <style> CLASS
# rules (not just inline style=""), routed through the full cascade so class-
# based layouts indent/constrain/border like real hand-written pages.
#   1em == 16px == 2 cells; % of the body content width (bw-2*CONTENT_X=584).
#   .box{margin-left:32px}          -> x = 8 + 32          = 40
#   .empad{margin-left:16;padding-left:16} -> x = 8+16+16   = 40
#   .em{margin-left:2em}            -> x = 8 + 32           = 40
#   .short{margin:16px 0 0 24px}    -> x = 8 + 24 = 32, +1 blank top-gap line
#   .narrow{width:120px}            -> wraps at indent_x+120 = 128 (15 cells)
#   .card{border:1px solid black}   -> 1-cell inset (x=16), '+---+' top/bottom,
#                                      side '|' bars at x=8 (left) and x=584.
#   inline style overrides the class/id rule per axis (specificity: inline wins)
# ====================================================================
FIXB="tests/fixtures/hambrowse_cssbox.html"
DUMPB="$OUT/dump_cssbox.txt"
echo "[hb-host] running host harness on $FIXB ..."
if ! "$BIN" "$FIXB" 600 >"$DUMPB" 2>&1; then
    echo "[hb-host] FAIL: cssbox harness exited non-zero"; cat "$DUMPB"; exit 1
fi
cat "$DUMPB"

assert_grepB() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMPB"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

assert_grepB '^SEG 0 8 .*Flush left at the body margin' \
    "no-box block flows at the body margin x=8"
assert_grepB '^SEG [0-9]+ 40 .*Class margin-left shifts this block' \
    ".box class margin-left:32px shifts content to x=40 (from a <style> rule)"
assert_grepB '^SEG [0-9]+ 40 .*Class margin plus padding both shift' \
    ".empad class margin-left:16 + padding-left:16 -> x=40"
assert_grepB '^SEG [0-9]+ 40 .*Class margin in em units' \
    ".em class margin-left:2em -> 32px -> x=40 (em == 16px)"
assert_grepB '^SEG [0-9]+ 32 .*Shorthand margin left plus top' \
    ".short shorthand margin:16 0 0 24 -> left 24px -> x=32"
# the shorthand's 16px top margin adds exactly one blank line before the block:
# the margin-less .box/.empad/.em pack adjacently at rows 2/3/4, so a bare
# adjacent block would be row 5; the 16px top margin pushes .short to row 6 (one
# blank gap at row 5) — proving the top margin still inserts a line.
assert_grepB '^SEG 6 32 .*Shorthand margin left plus top' \
    ".short margin-top:16px inserts one blank line (block at row 6, not row 5)"
# width:120px constrains the wrap column: the sentence wraps to many short rows
# instead of one full-width line. First wrapped row starts at x=8; a later row
# proves the early wrap (a full-width line would not reach row 15+).
assert_grepB '^SEG 7 8 .*This narrow\|$' \
    ".narrow width:120px wraps early -> first line 'This narrow' at x=8"
assert_grepB '^SEG 1[5-9] 8 .*(wraps|rows|page|would|allow)' \
    ".narrow width:120px keeps wrapping onto later rows (constrained width)"
# border box: top/bottom '+---+' rules, content inset by one cell (x=16), and
# vertical '|' bars at the left (x=8) and right (x=584) columns.
# NOTE: the side bars now share the FIRST content row (row 17), the same row the
# top '+---+' rule sits on. The 1px top border is drawn at the TOP EDGE of the
# first content row (lib/web/layout/box.ad::_block_box_open, "the reserved top-
# rule row was removed") instead of consuming its own ~19px grid row — the fix
# that stopped every bordered block (card/panel/grid-item/fieldset) from being
# pushed ~19px too far DOWN vs Chrome. The earlier expected row (18) encoded that
# old reserved-top-rule-row bug; updated to row 17. The pixel border still fully
# encloses the content (build/framediff_gfx/hambrowse_cssbox/sxs_chromium.png:
# the bordered card box matches Chrome's).
assert_grepB '^SEG [0-9]+ 8 .*\+-+\+\|$' \
    ".card border draws a '+---+' horizontal rule spanning the box"
assert_grepB '^SEG [0-9]+ 16 .*Bordered card block with inset content' \
    ".card border insets the content column by one cell (x=8 -> x=16)"
assert_grepB '^SEG 17 8 #101010 b0 u0 s0 l-1 bg- \|\|\|$' \
    ".card border draws a left '|' side bar at x=8 on the content row"
assert_grepB '^SEG 17 584 #101010 b0 u0 s0 l-1 bg- \|\|\|$' \
    ".card border draws a right '|' side bar at x=584 on the content row"
# there must be TWO horizontal border rules (top + bottom) for the one .card.
if [ "$(grep -Ec '^SEG [0-9]+ 8 .*\+-+\+\|$' "$DUMPB")" -eq 2 ]; then
    echo "[hb-host] PASS .card border has both a top and a bottom rule"
else
    echo "[hb-host] FAIL .card border rule count wrong (want 2)"; fail=1
fi
# INLINE style="" overrides the CLASS box rule (specificity: inline wins):
# a .box element with inline margin-left:0 flows back at x=8, NOT x=40.
assert_grepB '^SEG [0-9]+ 8 .*Inline zero overrides the class margin' \
    "inline margin-left:0 overrides the .box class margin (x=8, not x=40)"
# INLINE overrides an #id rule too: #over{margin-left:64px} + inline
# margin-left:8px -> x=16 (8 body + 8 inline), not x=72.
assert_grepB '^SEG [0-9]+ 16 .*Inline eight overrides the id rule' \
    "inline margin-left:8px overrides #over{margin-left:64px} (x=16, not x=72)"
# indent/width/border all POP: the trailing paragraph is back at the body x=8.
assert_grepB '^SEG [0-9]+ 8 .*Back flush at the body margin' \
    "box state pops -> trailing paragraph back at the body margin x=8"

# ====================================================================
# JAVASCRIPT + minimal DOM fixture — <script> runs at load; console.log is
# captured; the DOM the script mutates (textContent, style.color,
# style.display) changes what renders; document.title is settable.
# ====================================================================
FIX5="tests/fixtures/hambrowse_js.html"
DUMP5="$OUT/dump_js.txt"
echo "[hb-host] running host harness on $FIX5 ..."
if ! "$BIN" "$FIX5" 600 >"$DUMP5" 2>&1; then
    echo "[hb-host] FAIL: js harness exited non-zero"; cat "$DUMP5"; exit 1
fi
cat "$DUMP5"

assert_grep5() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP5"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# console.log output is captured and surfaced.
assert_grep5 '^JSLOG hello from js$'  "console.log string is captured"
assert_grep5 '^JSLOG 1\+1 = 2$'       "console.log evaluates + prints an expression (1+1=2)"
# getElementById(...).textContent = ... changes what renders.
assert_grep5 '\|JS set this heading\|' "textContent set on #head changes the heading text"
assert_grep5 '\|mutated by script\|'   "textContent set on #msg changes the paragraph text"
# The ORIGINAL placeholder text is gone (proves the mutation replaced it).
if grep -q 'Placeholder heading' "$DUMP5"; then
    echo "[hb-host] FAIL original #head text still rendered"; fail=1
else
    echo "[hb-host] PASS original #head placeholder text replaced by JS"
fi
# style.color set by JS -> the element renders in that colour.
assert_grep5 '^SEG [0-9]+ 8 #ff0000 .*\|tint me\|' "style.color='red' -> #ff0000 text"
# style.display='none' hides the element (no segment for its text).
if grep -q 'you should not see this hidden line' "$DUMP5"; then
    echo "[hb-host] FAIL style.display='none' element still rendered"; fail=1
else
    echo "[hb-host] PASS style.display='none' hides the element (no segment)"
fi
# The static (non-scripted) tail paragraph is untouched.
assert_grep5 '\|Static tail paragraph stays put.\|' "un-scripted content renders unchanged"
# document.title is settable from JS.
assert_grep5 '^TITLE Title From JS$' "document.title assignment reflected"

# ---- graceful JS error: a runtime error must not crash the render --------
cat > "$OUT/js_err.html" <<'HTML'
<html><body>
<p id="a">before</p>
<script>
  document.getElementById('a').textContent = 'set ok';
  bogusUndefinedRef.doStuff();
</script>
<p>after error</p>
</body></html>
HTML
DUMP6="$OUT/dump_js_err.txt"
if ! "$BIN" "$OUT/js_err.html" 600 >"$DUMP6" 2>&1; then
    echo "[hb-host] FAIL: js-error harness exited non-zero"; cat "$DUMP6"; exit 1
fi
cat "$DUMP6"
# The error must be SURFACED with its identifier named — as an UNCAUGHT
# EXCEPTION, which is what a real browser console prints and what node/V8 report.
#
# This used to assert `JSERR 1`, the engine's FATAL error flag. That was wrong:
# an undefined identifier is an ordinary catchable ReferenceError, and raising the
# fatal flag for it meant try/catch could not see it AND the rest of the script
# was abandoned. Real bundles feature-detect missing globals inside try/catch
# constantly, so that one behaviour detonated real pages — on google.com it
# killed 3 of 10 scripts and produced the user-visible
# "_DumpException is not a function". A fatal JSERR here would now be the bug.
if grep -q 'Uncaught ReferenceError: bogusUndefinedRef is not defined' "$DUMP6"; then
    echo "[hb-host] PASS runtime JS error surfaced as a named uncaught ReferenceError"
else
    echo "[hb-host] FAIL runtime JS error not surfaced"; fail=1
fi
if grep -q '^JSERR 1' "$DUMP6"; then
    echo "[hb-host] FAIL an undefined identifier raised the FATAL engine flag (must be catchable)"; fail=1
else
    echo "[hb-host] PASS an undefined identifier is NOT a fatal engine error"
fi
# the render survives the error: pre-error mutation applied + tail still renders.
if grep -q '|set ok|' "$DUMP6" && grep -q '|after error|' "$DUMP6"; then
    echo "[hb-host] PASS render survives a JS error (pre-error DOM change kept, page intact)"
else
    echo "[hb-host] FAIL render did not survive the JS error"; fail=1
fi

# ====================================================================
# EVENTS — a programmatic click (no pointer) fires a stored JS handler via
# js_call_fn in the persistent context, then re-lays-out. This is the
# acceptance path for interactivity.
# ====================================================================
FIXE="tests/fixtures/hambrowse_events.html"
# (a) el.onclick = fn  -> click #btn increments a counter the render reflects.
DUMPE="$OUT/dump_events_btn.txt"
echo "[hb-host] running host harness on $FIXE (click btn) ..."
if ! "$BIN" "$FIXE" 600 btn >"$DUMPE" 2>&1; then
    echo "[hb-host] FAIL: events harness exited non-zero"; cat "$DUMPE"; exit 1
fi
cat "$DUMPE"
assert_grepE() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMPE"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}
# Before the click the counter reads 0; the CLICK separator is emitted.
assert_grepE '^CLICK btn$' "programmatic click on #btn dispatched"
# After the click, the onclick handler ran: counter text updated + console.log.
assert_grepE '^JSLOG clicked, count=1$' "onclick handler ran (console.log after dispatch)"
# The post-click dump (after CLICK) shows the mutated counter text.
awk '/^CLICK btn$/{c=1} c' "$DUMPE" | grep -q '|count is 1|' && \
    echo "[hb-host] PASS el.onclick handler mutation rendered (count is 1)" || \
    { echo "[hb-host] FAIL onclick DOM mutation did not render"; fail=1; }
# The counter was 0 BEFORE the click (pre-click dump).
awk '/^CLICK btn$/{exit} {print}' "$DUMPE" | grep -q '|count is 0|' && \
    echo "[hb-host] PASS pre-click state was count is 0" || \
    { echo "[hb-host] FAIL pre-click state wrong"; fail=1; }

# (b) addEventListener('click', fn) -> click #msg mutates text + colour.
DUMPE2="$OUT/dump_events_msg.txt"
echo "[hb-host] running host harness on $FIXE (click msg) ..."
if ! "$BIN" "$FIXE" 600 msg >"$DUMPE2" 2>&1; then
    echo "[hb-host] FAIL: events harness (msg) exited non-zero"; cat "$DUMPE2"; exit 1
fi
cat "$DUMPE2"
if awk '/^CLICK msg$/{c=1} c' "$DUMPE2" | grep -Eq '#ff0000 .*\|msg was clicked\|'; then
    echo "[hb-host] PASS addEventListener('click') handler ran (text + red colour rendered)"
else
    echo "[hb-host] FAIL addEventListener click handler did not render"; fail=1
fi

# ====================================================================
# RICHER DOM — innerHTML, createElement+appendChild, className, querySelector,
# getAttribute/setAttribute, and background-color/font-weight/text-align.
# ====================================================================
FIXD="tests/fixtures/hambrowse_dom2.html"
DUMPD="$OUT/dump_dom2.txt"
echo "[hb-host] running host harness on $FIXD ..."
if ! "$BIN" "$FIXD" 600 >"$DUMPD" 2>&1; then
    echo "[hb-host] FAIL: dom2 harness exited non-zero"; cat "$DUMPD"; exit 1
fi
cat "$DUMPD"
assert_grepD() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMPD"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}
# innerHTML set to markup -> parsed + rendered (the <b> becomes bold).
assert_grepD '^SEG 0 8 #101010 b1 .*\|bold new\|' "innerHTML set -> <b> renders bold"
if grep -q 'old inner' "$DUMPD"; then
    echo "[hb-host] FAIL innerHTML did not replace original inner"; fail=1
else
    echo "[hb-host] PASS innerHTML replaced the original inner markup"
fi
# style.backgroundColor + fontWeight + textAlign together on #styled.
assert_grepD '^SEG [0-9]+ (1[0-9][0-9]|[2-9][0-9][0-9]) #101010 b1 .*bg#ffff00 \|style me\|' \
    "style.backgroundColor/fontWeight/textAlign -> yellow bg, bold, centred"
# className change -> the .warn CSS rule now applies (red + bold).
assert_grepD '^SEG [0-9]+ 8 #ff0000 b1 .*\|class target\|' \
    "element.className='warn' -> .warn CSS rule applies (red bold)"
# createElement + appendChild -> the new <li> renders, coloured green.
assert_grepD '#008000 .*\|appended item\|' "createElement+appendChild adds a green <li>"
# querySelector('.class') + getAttribute reflected via console.log.
assert_grepD '^JSLOG querySelector .warn text = warn para$' "querySelector('.warn') returns the element"
assert_grepD '^JSLOG getAttribute data-role = banner$'       "getAttribute reads a source attribute"
# setAttribute('class','warn') -> .warn rule applies to #attr.
assert_grepD '^SEG [0-9]+ 8 #ff0000 b1 .*\|attr target\|' \
    "setAttribute('class','warn') -> .warn CSS rule applies"

# ====================================================================
# FORMS — <input>/<textarea>/<button>/<select> rendering, the form DOM
# (value/checked/type/name, form.elements, document.forms), form events
# (oninput/onchange/onclick/onsubmit) fired via the pointer-free host hooks
# (he_dom_set_value / he_dom_set_checked / he_dom_submit), and GET-style
# serialization of a form that does NOT preventDefault.
# ====================================================================
FIXF="tests/fixtures/hambrowse_forms.html"

run_forms() {   # args passed straight to the harness after WIDTH
    "$BIN" "$FIXF" 600 "$@"
}

# ---- (0) initial render: every control draws a monospace box ------------
DUMPF="$OUT/dump_forms.txt"
echo "[hb-host] rendering $FIXF ..."
if ! run_forms >"$DUMPF" 2>&1; then
    echo "[hb-host] FAIL: forms harness exited non-zero"; cat "$DUMPF"; exit 1
fi
cat "$DUMPF"
assert_grepF() {
    local pat="$1" msg="$2" file="${3:-$DUMPF}"
    if grep -Eq -- "$pat" "$file"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}
assert_grepF '^FLOW  Name field: \[hi__________________\]$' "text input renders [value] padded to the 20-cell UA default width"
assert_grepF '^FLOW  Subscribe: \[x\]$'         "checked checkbox renders [x]"
assert_grepF '^FLOW  Colour: \(\*\) red$'       "checked radio renders (*)"
assert_grepF '^FLOW  Notes: \[note text___________\]$' "textarea renders content padded to the 20-col UA default width"
assert_grepF '^FLOW  Pick: \[ beta v\]$'        "select renders the selected option (beta)"
assert_grepF '^FLOW  \[ Save \]$'               "<button> renders a [ label ] box"
assert_grepF 'Search'                            "input type=submit renders a button"
# the hidden input renders nothing (no box) on the second form's line.
assert_grepF '^FLOW  \[dogs________________\] \[ Go \]$'    "hidden input renders nothing (only visible fields box)"
# form DOM surface: input.type/name, select.value/selectedIndex, collections.
assert_grepF '^JSLOG name\.type=text$'  "input.type defaults to text"
assert_grepF '^JSLOG name\.name=who$'   "element.name reads the name attribute"
assert_grepF '^JSLOG pick\.value=beta$' "select.value returns the selected option text"
assert_grepF '^JSLOG pick\.idx=1$'      "select.selectedIndex returns the selected index"
assert_grepF '^JSLOG f1\.elements=3$'   "form.elements lists the form's controls"
assert_grepF '^JSLOG doc\.forms=2$'     "document.forms lists the page's forms"

# ---- (1) text input: he_dom_set_value fires oninput -> updates echo -----
DUMPF1="$OUT/dump_forms_setval.txt"
run_forms setval name Fluffy >"$DUMPF1" 2>&1
cat "$DUMPF1"
awk '/^SETVAL/{c=1} c' "$DUMPF1" > "$OUT/forms_after_setval.txt"
assert_grepF '^FLOW  Name field: \[Fluffy______________\]$' \
    "he_dom_set_value updates the text input box" "$OUT/forms_after_setval.txt"
assert_grepF '^FLOW  echo: Fluffy$' \
    "oninput handler read input.value and updated another element" \
    "$OUT/forms_after_setval.txt"

# ---- (2) checkbox: he_dom_set_checked fires onchange --------------------
DUMPF2="$OUT/dump_forms_check.txt"
run_forms check sub 0 >"$DUMPF2" 2>&1
cat "$DUMPF2"
awk '/^CHECK/{c=1} c' "$DUMPF2" > "$OUT/forms_after_check.txt"
assert_grepF '^FLOW  Subscribe: \[ \]$' \
    "unchecking the checkbox re-renders [ ]" "$OUT/forms_after_check.txt"
assert_grepF '^FLOW  sub is off$' \
    "onchange handler read input.checked and updated the status line" \
    "$OUT/forms_after_check.txt"

# ---- (3) button onclick mutates the DOM --------------------------------
DUMPF3="$OUT/dump_forms_click.txt"
run_forms click go >"$DUMPF3" 2>&1
cat "$DUMPF3"
awk '/^CLICK/{c=1} c' "$DUMPF3" > "$OUT/forms_after_click.txt"
assert_grepF '^FLOW  saved!$' \
    "<button> onclick handler mutated the DOM" "$OUT/forms_after_click.txt"
# the pre-click state ('not saved') was present before the click.
awk '/^CLICK/{exit} {print}' "$DUMPF3" | grep -q 'not saved' && \
    echo "[hb-host] PASS pre-click button state was 'not saved'" || \
    { echo "[hb-host] FAIL pre-click button state wrong"; fail=1; }

# ---- (4) onsubmit reads values + preventDefault stops navigation -------
DUMPF4="$OUT/dump_forms_submit1.txt"
run_forms submit f1 >"$DUMPF4" 2>&1
cat "$DUMPF4"
awk '/^SUBMIT/{c=1} c' "$DUMPF4" > "$OUT/forms_after_submit1.txt"
assert_grepF '^FLOW  searched cats fancy=yes$' \
    "onsubmit read input.value + input.checked and updated the page" \
    "$OUT/forms_after_submit1.txt"
assert_grepF '^JSLOG submit q=cats$' \
    "onsubmit handler ran (console.log captured)" "$OUT/forms_after_submit1.txt"
# preventDefault() was honoured: NO navigation happened.
if grep -q '^NAV ' "$OUT/forms_after_submit1.txt"; then
    echo "[hb-host] FAIL preventDefault ignored (form navigated anyway)"; fail=1
else
    echo "[hb-host] PASS onsubmit preventDefault suppressed navigation (no NAV)"
fi

# ---- (5) a form WITHOUT preventDefault GET-serializes its fields --------
DUMPF5="$OUT/dump_forms_submit2.txt"
run_forms submit f2 >"$DUMPF5" 2>&1
cat "$DUMPF5"
awk '/^SUBMIT/{c=1} c' "$DUMPF5" > "$OUT/forms_after_submit2.txt"
assert_grepF '^NAV /search\?term=dogs&lang=en$' \
    "form without preventDefault serializes to its action (/search) + visible+hidden fields (submit button excluded)" \
    "$OUT/forms_after_submit2.txt"

# ====================================================================
# FORMS DEPTH — radio-group exclusivity, JS `select.selectedIndex = N` writes,
# and a submit that gathers EVERY control kind (text + select + checkbox +
# checked radio). tests/fixtures/hambrowse_forms2.html exercises all three.
# ====================================================================
FIXG="tests/fixtures/hambrowse_forms2.html"
run_forms2() { "$BIN" "$FIXG" 600 "$@"; }

# ---- (0) initial render: the "plan" group shows free checked, pro empty ---
DUMPG="$OUT/dump_forms2.txt"
echo "[hb-host] rendering $FIXG ..."
if ! run_forms2 >"$DUMPG" 2>&1; then
    echo "[hb-host] FAIL: forms2 harness exited non-zero"; cat "$DUMPG"; exit 1
fi
cat "$DUMPG"
assert_grepG() {
    local pat="$1" msg="$2" file="${3:-$DUMPG}"
    if grep -Eq -- "$pat" "$file"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}
assert_grepG '^FLOW  Plan: \(\*\) free$' "radio group: 'free' starts checked (*)"
assert_grepG '^FLOW  \( \) pro$'         "radio group: 'pro' starts unchecked ( )"
assert_grepG '^FLOW  Lang: \[ fr v\]$'   "select renders the source-selected option (fr)"

# ---- (1) radio-group exclusivity: checking 'pro' unchecks 'free' ----------
DUMPG1="$OUT/dump_forms2_radio.txt"
run_forms2 check pp 1 >"$DUMPG1" 2>&1
cat "$DUMPG1"
awk '/^CHECK/{c=1} c' "$DUMPG1" > "$OUT/forms2_after_radio.txt"
assert_grepG '^FLOW  \(\*\) pro$' \
    "checking 'pro' renders it selected (*)" "$OUT/forms2_after_radio.txt"
assert_grepG '^FLOW  Plan: \( \) free$' \
    "radio-group exclusivity: 'free' was auto-unchecked ( )" "$OUT/forms2_after_radio.txt"
assert_grepG '^FLOW  plan is pro$' \
    "only the newly-checked radio fired onchange (status = pro)" "$OUT/forms2_after_radio.txt"

# ---- (2) select.selectedIndex = 2 write re-renders + reads back -----------
DUMPG2="$OUT/dump_forms2_select.txt"
run_forms2 click pickde >"$DUMPG2" 2>&1
cat "$DUMPG2"
awk '/^CLICK/{c=1} c' "$DUMPG2" > "$OUT/forms2_after_select.txt"
assert_grepG '^FLOW  Lang: \[ de v\]$' \
    "JS select.selectedIndex=2 re-renders the third option (de)" \
    "$OUT/forms2_after_select.txt"

# ---- (3) submit gathers text + select + checkbox + the checked radio ------
DUMPG3="$OUT/dump_forms2_submit.txt"
run_forms2 submit f3 >"$DUMPG3" 2>&1
cat "$DUMPG3"
awk '/^SUBMIT/{c=1} c' "$DUMPG3" > "$OUT/forms2_after_submit.txt"
assert_grepG '^NAV /join\?user=ada&tier=gold&news=yes&col=blue$' \
    "submit gathers to its action (/join) every field=value (select=gold, checkbox=yes, checked radio col=blue)" \
    "$OUT/forms2_after_submit.txt"

# ====================================================================
# DEFAULT UA STYLESHEET (visual-polish) rung — a PLAIN page (no author CSS)
# should already look intentional: a readable centred measure on wide windows,
# section spacing above headings, a light code-block/inline-code background,
# and muted blockquote text. tests/fixtures/hambrowse_article.html is a plain
# article that exercises all of these.
# ====================================================================
FIXA="tests/fixtures/hambrowse_article.html"
DUMPA="$OUT/dump_article.txt"
echo "[hb-host] running host harness on $FIXA (600 px) ..."
if ! "$BIN" "$FIXA" 600 >"$DUMPA" 2>&1; then
    echo "[hb-host] FAIL: article harness exited non-zero"; cat "$DUMPA"; exit 1
fi
cat "$DUMPA"

assert_grepA() {
    local pat="$1" msg="$2" file="${3:-$DUMPA}"
    if grep -Eq -- "$pat" "$file"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# The leading <h1> sits at row 0 (no spurious top-margin at the document start)
# and still lays its heading rule.
assert_grepA '^SEG 0 8 #101010 b1 u0 s0 l-1 bg- \|The Hamnix Project\|' \
    "leading h1 at row 0 (heading top-margin suppressed at document start)"
assert_grepA '^RULE row 0 type 1$' "leading h1 emits a heading rule"
# A mid-document heading gets ONE blank section-spacing line above it — and that
# margin COLLAPSES with the preceding paragraph's bottom margin (Chrome parity),
# so the h2 "Design goals" lands at row 11 (preceding prose on row 9, the single
# collapsed margin on the empty row 10), NOT the old double-gap row 12.
assert_grepA '^SEG 11 8 #101010 b1 u0 s0 l-1 bg- \|Design goals\|' \
    "mid-doc h2 gets a collapsed section top-margin (lands at row 11, one gap not two)"
if grep -Eq '^SEG 10 ' "$DUMPA"; then
    echo "[hb-host] FAIL heading top-margin row 10 is not blank"; fail=1
else
    echo "[hb-host] PASS heading top-margin inserts a single blank line (row 10 empty)"
fi
# <pre> renders teal monospace on the light code background (#eef0f3) across
# every code line.
assert_grepA '^SEG 52 8 #0a6b5a b0 u0 s0 l-1 bg#eef0f3 \|fn main\(\) \{\|' \
    "pre line -> teal text on the light code background (#eef0f3)"
assert_grepA '^SEG 54 8 #0a6b5a b0 u0 s0 l-1 bg#eef0f3 \|\}\|' \
    "every pre line carries the code background"
# inline <code> also gets the teal tint + code background (mid-paragraph).
assert_grepA '^SEG [0-9]+ [0-9]+ #0a6b5a b0 u0 s0 l-1 bg#eef0f3 \| code\|' \
    "inline <code> -> teal text on the light code background"
# <blockquote> text renders in a muted grey (#5a5a5a), still indented to x=32.
assert_grepA '^SEG 45 32 #5a5a5a b0 u0 s0 l-1 bg- \|Anything that can go wrong' \
    "blockquote text -> muted grey (#5a5a5a), indented to x=32"

# ---- edge-to-edge prose on a WIDE window: Chrome/Firefox parity. A plain-prose
# page that does NOT declare its own author `max-width` spans the FULL viewport
# width (body content starts at the body margin x=8), rather than being capped at
# a 584px centred reading column. This matches Chrome exactly: at a 900px window
# the first paragraph's border-box left = 8px and width = 869px (measured via
# getBoundingClientRect), i.e. edge-to-edge — NOT a centred 584px strip.
# NOTE: the earlier expected x=158 encoded an always-on 584px centred measure
# (gutter (900-16-584)/2 = 150) that _page_gutter() no longer applies to plain
# prose (lib/web/state.ad::_page_gutter now returns 0 unless g_page_maxwidth) —
# it was STALE. Updated to the Chrome-matching edge-to-edge x=8.
DUMPA9="$OUT/dump_article_wide.txt"
echo "[hb-host] running host harness on $FIXA (900 px, edge-to-edge prose) ..."
if ! "$BIN" "$FIXA" 900 >"$DUMPA9" 2>&1; then
    echo "[hb-host] FAIL: wide-article harness exited non-zero"; cat "$DUMPA9"; exit 1
fi
cat "$DUMPA9"
assert_grepA '^SEG 2 8 #101010 b0 u0 s0 l-1 bg- \|Hamnix is a native operating system' \
    "wide window: plain prose spans edge-to-edge at the body margin (x=8 at 900px, Chrome parity)" "$DUMPA9"
# each wrapped prose line begins at the body margin x=8 (no artificial centring
# gutter): there is no line whose START x lands in the 750-899 band.
if grep -Eq '^SEG 2 (7[5-9][0-9]|8[0-9][0-9]) ' "$DUMPA9"; then
    echo "[hb-host] FAIL wide window prose line started in the right gutter band"; fail=1
else
    echo "[hb-host] PASS wide window prose lines all start at the body margin (edge-to-edge)"
fi

# ====================================================================
# HTML CHARACTER ENTITIES — named (&amp; &lt; &mdash; &copy; …), numeric
# decimal (&#8212;) and hex (&#x2014;), decoded to their UTF-8 bytes during
# TEXT and ATTRIBUTE-VALUE parsing. A malformed/unknown entity (&notanentity;
# or a bare '&') passes through UNCHANGED (the '&' is not eaten).
# ====================================================================
FIXENT="tests/fixtures/hambrowse_entities.html"
DUMPENT="$OUT/dump_entities.txt"
echo "[hb-host] running host harness on $FIXENT ..."
if ! "$BIN" "$FIXENT" 600 >"$DUMPENT" 2>&1; then
    echo "[hb-host] FAIL: entities harness exited non-zero"; cat "$DUMPENT"; exit 1
fi
cat "$DUMPENT"

assert_grepENT() {
    local pat="$1" msg="$2"
    if grep -Fq -- "$pat" "$DUMPENT"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}
assert_grepENT_re() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMPENT"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# Named: &mdash; -> em dash (U+2014, UTF-8 e2 80 94), rendered in the flow.
assert_grepENT 'FLOW  DASH A — B' "&mdash; decodes to an em dash (—)"
# &amp; -> '&'  (the decoded '&' must NOT re-start another entity).
assert_grepENT 'FLOW  AMP fish & chips' "&amp; decodes to a literal ampersand (&)"
# &lt; / &gt; -> '<' '>'; the decoded '<' is text, NOT a tag start.
assert_grepENT 'FLOW  ANGLE <tag> end' "&lt;/&gt; decode to < > as literal text (not markup)"
# Numeric decimal &#8212; and hex &#x2014; / &#X2014; -> em dash.
assert_grepENT 'FLOW  DEC — here'   "&#8212; (decimal) decodes to an em dash"
assert_grepENT 'FLOW  HEX — here'   "&#x2014; (hex) decodes to an em dash"
assert_grepENT 'FLOW  HEXUP — up'   "&#X2014; (uppercase-X hex) decodes to an em dash"
# &nbsp; -> a normal space (word stays joined across the entity).
assert_grepENT 'FLOW  NBSP one two' "&nbsp; decodes to a space"
# Malformed/unknown entities pass through UNCHANGED (the '&' is not eaten).
assert_grepENT 'FLOW  BOGUS &notanentity; kept' "unknown &notanentity; passes through unchanged"
assert_grepENT 'FLOW  BARE fish & chips raw'     "a bare '&' (not an entity) passes through unchanged"
# Latin-1 / symbol named entities decode to their UTF-8 form.
assert_grepENT 'FLOW  SYMS ©2026 ® ™' "&copy;/&reg;/&trade; decode to © ® ™"
assert_grepENT 'FLOW  QUOTES “hi” ‘x’ end' "curly-quote entities decode (&ldquo;&rdquo;&lsquo;&rsquo;)"
assert_grepENT 'FLOW  MATH 3 × 4 ÷ 2 ± 1 deg °' "&times;/&divide;/&plusmn;/&deg; decode to × ÷ ± °"
assert_grepENT 'FLOW  MISC – … · € ½' "&ndash;/&hellip;/&middot;/&euro;/&frac12; decode"
# ATTRIBUTE-VALUE decode: an input value="a&amp;b" renders the decoded '&' in
# its monospace box (proves entities are decoded in attribute values too).
assert_grepENT_re '^FLOW  \[a&b_+\]$' "entities decode inside attribute values (input value a&amp;b -> a&b)"

# ====================================================================
# FLEXBOX — display:flex lays a container's DIRECT-CHILD block boxes out
# HORIZONTALLY as equal-width columns (the real-page pattern the old block
# model got wrong: an article body beside its infobox, a card/nav row). Each
# child column shares the container's top row; the flow resumes full-width
# below the tallest column. At 600px the body content column is 8..592 (584px
# wide): 2 cols -> width (584-8)/2=288, col1 at x=8+(288+8)=304; 3 cols ->
# width (584-16)/3=189, col1 at x=205, col2 at x=402.
# ====================================================================
FIXFLX="tests/fixtures/hambrowse_flex.html"
DUMPFLX="$OUT/dump_flex.txt"
echo "[hb-host] running host harness on $FIXFLX ..."
if ! "$BIN" "$FIXFLX" 600 >"$DUMPFLX" 2>&1; then
    echo "[hb-host] FAIL: flex harness exited non-zero"; cat "$DUMPFLX"; exit 1
fi
cat "$DUMPFLX"

assert_grepFLX() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMPFLX"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# Two flex columns sit on the SAME top row (row 0): the first at the body
# margin x=8, the second pinned one column over at x=304 — side by side, NOT
# stacked. The second column keeps its background-color.
assert_grepFLX '^SEG 0 8 #101010 b0 u0 s0 l-1 bg- \|Left alpha one\|' \
    "flex: first column at the body margin x=8 on row 0"
assert_grepFLX '^SEG 0 304 #101010 b0 u0 s0 l-1 bg#eef0f3 \|Right beta\|' \
    "flex: second column laid HORIZONTALLY beside the first (x=304, same row 0)"
# The first (taller) column's second line flows DOWN inside its own column
# (still x=8), proving columns have independent vertical flow.
assert_grepFLX '^SEG 2 8 #101010 b0 u0 s0 l-1 bg- \|Left alpha two\|' \
    "flex: first column's second line flows down within its column (x=8, row 2)"
# After the flex row, normal flow resumes FULL-WIDTH at the body margin, BELOW
# the tallest column (row 4, past the 2-line left column) — not overlapping.
assert_grepFLX '^SEG 4 8 #101010 b0 u0 s0 l-1 bg- \|After the flex row here\|' \
    "flex: flow resumes full-width below the tallest column (row 4, x=8)"
# A THREE-column flex row places all three children on one row at evenly
# stepped x-positions (x=8 / 205 / 402) — equal-width column division.
assert_grepFLX '^SEG 6 8 #101010 b0 u0 s0 l-1 bg- \|Col A\|'   "flex: 3-col row, column 0 at x=8"
assert_grepFLX '^SEG 6 205 #101010 b0 u0 s0 l-1 bg- \|Col B\|' "flex: 3-col row, column 1 at x=205 (equal share)"
assert_grepFLX '^SEG 6 402 #101010 b0 u0 s0 l-1 bg- \|Col C\|' "flex: 3-col row, column 2 at x=402 (equal share)"
# The tail paragraph pops back to the body margin after the 3-col row.
assert_grepFLX '^SEG 8 8 #101010 b0 u0 s0 l-1 bg- \|Tail line\|' \
    "flex: tail paragraph back at the body margin x=8 after the flex row closes"

# ====================================================================
# INTERACTIVITY fixture — inline on<evt>="" handlers with NO <script>.
# Proves the DOM-event -> JS-handler -> DOM-mutation -> re-render loop for a
# page whose only JS is inline handlers: such a page must still get a LIVE JS
# context, `this` must bind to the element (this.value), and the mutated node
# must re-render. Drive it with the pointer-free setval/click verbs.
# ====================================================================
FIXI="tests/fixtures/hambrowse_interactive.html"
DBEF="$OUT/dump_interactive_before.txt"
DINP="$OUT/dump_interactive_input.txt"
DCLK="$OUT/dump_interactive_click.txt"

echo "[hb-host] running interactivity fixture (before / input / click) ..."
"$BIN" "$FIXI" 640                     >"$DBEF" 2>&1
"$BIN" "$FIXI" 640 setval q hamnix     >"$DINP" 2>&1
"$BIN" "$FIXI" 640 click tog           >"$DCLK" 2>&1
cat "$DINP"

# BEFORE any input: the result node shows only its original text; the typed
# query must NOT yet appear (guards a false-green where the render is stale).
if grep -q 'Results for: hamnix' "$DBEF"; then
    echo "[hb-host] FAIL interactivity: post-input text present BEFORE input (stale render)"; fail=1
else
    echo "[hb-host] PASS interactivity: result node clean before input"
fi

# AFTER oninput (setval q=hamnix): the handler read this.value and mutated the
# #out node; the re-render must show it. If the JS context never came up (no
# <script>) or `this` didn't bind, this line is absent -> FAIL.
if grep -q 'Results for: hamnix' "$DINP"; then
    echo "[hb-host] PASS interactivity: oninput this.value drove #out re-render (Results for: hamnix)"
else
    echo "[hb-host] FAIL interactivity: oninput handler did not update the render"; fail=1
fi
# The typed value is also reflected back into the input box itself.
if grep -q '\[hamnix' "$DINP"; then
    echo "[hb-host] PASS interactivity: input box reflects typed value"
else
    echo "[hb-host] FAIL interactivity: input box did not reflect typed value"; fail=1
fi

# AFTER onclick (no <script> on the page): the button's inline onclick fired
# and mutated a different node.
if grep -q 'button was clicked' "$DCLK"; then
    echo "[hb-host] PASS interactivity: inline onclick fired without a <script> element"
else
    echo "[hb-host] FAIL interactivity: inline onclick did not fire (no live JS context?)"; fail=1
fi

# ====================================================================
# HTML COMMENTS — `<!-- … -->` spans are stripped before ANY tokenizer runs,
# so markup hidden inside a comment (a demo <script>, a stray '>' or '<', an
# IE `<!--[if IE]>…<![endif]-->` conditional) neither renders as page text NOR
# executes as script. `<!DOCTYPE …>` is NOT a comment and must not be eaten.
# ====================================================================
FIXC="tests/fixtures/hambrowse_comments.html"
DUMPC="$OUT/dump_comments.txt"
echo "[hb-host] running host harness on $FIXC ..."
if ! "$BIN" "$FIXC" 600 >"$DUMPC" 2>&1; then
    echo "[hb-host] FAIL: comments harness exited non-zero"; cat "$DUMPC"; exit 1
fi
cat "$DUMPC"

assert_grepC() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMPC"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# The real, uncommented content all renders (the <!DOCTYPE> did not break parse).
assert_grepC '^SEG 0 8 #101010 b1 .*\|Comments Fixture\|' "h1 renders (DOCTYPE not mistaken for a comment)"
assert_grepC '\|Visible lead paragraph\.\|'  "content before the comment renders"
assert_grepC '\|Between the two comments\.\|' "content between comments renders"
assert_grepC '\|Final visible paragraph\.\|'  "content after the comments renders"
# The .lead CSS rule (declared alongside a /* … */ comment) still applied.
assert_grepC '^SEG [0-9]+ 8 #008000 .*\|Visible lead paragraph\.\|' \
    ".lead { color:#008000 } applied (stylesheet comment did not break the rule)"

# The commented-out markup must NOT leak as rendered TEXT.
for leaked in 'HACKED' 'commented script executed' 'a bogus' 'stray' \
              'legacy IE-only conditional content'; do
    if grep -q "$leaked" "$DUMPC"; then
        echo "[hb-host] FAIL commented-out text leaked into the render: '$leaked'"; fail=1
    else
        echo "[hb-host] PASS commented-out text not rendered: '$leaked'"
    fi
done

# The commented-out <script> must NOT execute: its console.log is absent, the
# DOM it tried to mutate is untouched, and document.title stays the real title.
if grep -q '^JSLOG commented script executed$' "$DUMPC"; then
    echo "[hb-host] FAIL a <script> inside a comment executed"; fail=1
else
    echo "[hb-host] PASS <script> inside a comment did NOT execute (no JSLOG)"
fi
assert_grepC '^JSLOG real script executed$' "the real (uncommented) <script> still executed"
assert_grepC '^TITLE Comments Fixture$'      "document.title kept (commented script did not overwrite it)"

# ====================================================================
# CSS POSITION fixture — position:relative (in-flow, offset) + position:
# absolute (out of flow, placed against the nearest positioned ancestor).
# A `.card { position:relative }` box holds two absolutely-positioned badges:
# `.tl { top:0; left:0 }` pins to the card's top-LEFT, `.tr { top:0; right:0 }`
# pins to its top-RIGHT. Being out of flow they OVERLAY the card body (same row)
# instead of stacking below it, and the card stays compact. A relatively-
# positioned paragraph is shifted right+down from its in-flow spot.
# ====================================================================
# NOTE: the SEG assertions below describe a `.card{position:relative}` box with
# top-left/top-right absolute badges plus a relative-offset paragraph. Round-10
# (852710cb) repurposed hambrowse_position.html for the POSFILL pixel gate, so
# this SEG gate uses its own fixture (hambrowse_position_card.html) to keep both.
FIXP="tests/fixtures/hambrowse_position_card.html"
DUMPP="$OUT/dump_position.txt"
echo "[hb-host] running host harness on $FIXP ..."
if ! "$BIN" "$FIXP" 600 >"$DUMPP" 2>&1; then
    echo "[hb-host] FAIL: position harness exited non-zero"; cat "$DUMPP"; exit 1
fi
cat "$DUMPP"

assert_grepP() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMPP"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# The card body text sits at the card's content origin (row 2, x=16). NOTE: rows
# are ONE LOWER than the pre-border-model geometry — a bordered box no longer
# reserves a whole top-rule grid row for its 1px top border (the border is stroked
# AT the content-box top), so the card content + everything after it moves up one
# row (the Chrome-matching card-top fix).
assert_grepP '^SEG 2 16 #101010 b0 u0 s0 l-1 bg- \|Card body text line one here\.\|' \
    "position: card body text at the card content origin (row 2, x=16)"
# ABSOLUTE top-left: the .tl badge lands at the card's top-LEFT (x=16) and,
# being out of flow, shares the card body's row (row 2) instead of pushing it
# down. Same x as the body text proves left:0 maps to the containing-block left.
assert_grepP '^SEG 2 16 #ffffff b0 u0 s0 l-1 bg#ff0000 \|TL\|' \
    "position:absolute top:0 left:0 -> card top-left, out of flow (row 2, x=16)"
# ABSOLUTE top-right: the .tr badge is pinned to the card's RIGHT edge (x=328)
# on the SAME top row.
assert_grepP '^SEG 2 328 #ffffff b0 u0 s0 l-1 bg#00aa00 \|TR\|' \
    "position:absolute top:0 right:0 -> card top-right, right-anchored (row 2, x=328)"
# Out of flow means the card stays COMPACT, so the trailing plain paragraph is at
# row 7 — NOT shoved far down by in-flow badges.
assert_grepP '^SEG 7 8 #101010 b0 u0 s0 l-1 bg- \|Plain trailing paragraph\.\|' \
    "position: absolute badges are out of flow (card compact, trailing para at row 7)"
# RELATIVE offset: the nudged paragraph is shifted right by left:48px (x 8->56)
# and down by top:16px (one row) from its normal-flow position (x 8->56, row 6).
assert_grepP '^SEG 6 56 #0000ff b0 u0 s0 l-1 bg- \|Nudged para here\.\|' \
    "position:relative left:48 top:16 -> shifted right (x=56) and down (row 6)"

if [ "$fail" -eq 0 ]; then
    echo "[hb-host] RESULT: PASS"
    exit 0
else
    echo "[hb-host] RESULT: FAIL"
    exit 1
fi
