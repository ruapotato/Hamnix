#!/usr/bin/env bash
# scripts/test_hambrowse_inert_css_host.sh — QEMU-free gate for two CSS bugs
# that between them BLANKED real pages, both found chasing the user report
# "the browser ... loads a broken google search window and its not useable".
#
# PART A — INERT MARKUP CONTRIBUTES NO STYLE.
#   lib/web/css/cascade.ad's stylesheet collectors (_collect_css, _collect_cvars,
#   he_css_scan_links) are RAW-SOURCE scanners with no notion of tree position,
#   so they harvested <style> / <link rel=stylesheet> from places the real
#   document has no stylesheet at all:
#     * <noscript>. hambrowse ALWAYS has scripting enabled, so a <noscript>'s
#       content is RAWTEXT, not elements. The DOM side already modelled that;
#       the CSS side did not. real google.com's results page opens with
#       <noscript><style>table,div,span,p{display:none}</style>…</noscript> as
#       its JS-disabled fallback, so the scanner hid every table/div/span/p on
#       the page and laid out ZERO segments.
#     * <template>. Content lives in a separate DocumentFragment, inert until
#       cloned. tests/fixtures/realsites/mdn_html.html carries 23 declarative
#       shadow-root templates, one of which holds [hidden]{display:none
#       !important}; applied document-wide it deleted MDN's own list items.
#   CHROMIUM ORACLE (--headless --dump-dom, getComputedStyle + styleSheets):
#     noscript+template fixture -> sheets=0, div=block, p=block, span=inline
#   so the fallback/template TEXT must not render either. The same scanners ran
#   a <script> out of either region; chromium leaves both their globals unset
#   (ns=0 tp=0), and executing the <noscript> one is actively harmful since it
#   is the fallback a site serves to a client WITHOUT JS.
#
# PART B — ATTRIBUTE SELECTORS MATCH ONLY AT ATTRIBUTE-NAME POSITIONS.
#   _attr_match / _body_has_attr hunted for the attribute NAME as a substring of
#   the raw tag body, accepting any non-alphanumeric char before it — which is
#   trivially satisfied INSIDE a quoted value. So `[hidden]` matched
#   <a href="/docs/Global_attributes/hidden">, and `:checked` matched
#   <input value="checked disabled">. Both now run on a real tag-body
#   tokenizer that steps over quoted values.
#   CHROMIUM ORACLE for tests/fixtures/hambrowse_attrsel_wordpos.html:
#     the four <li> compute to list-item, list-item, list-item, none
#     (only the one that really carries `hidden` is hidden), #p1 is
#     rgb(255,0,0) via [data-x="1"] and #p2 — whose TITLE merely says
#     `data-x=1` — stays black, and the checkbox is UNCHECKED.
#
# Both parts are pure lib/web/ layout assertions, so this runs on the host
# harness with no QEMU and no image.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FX="tests/fixtures"
mkdir -p "$OUT"

echo "[hb-inert] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/inert_compile.log"; then
    echo "[hb-inert] FAIL: host harness did not compile"; cat "$OUT/inert_compile.log"; exit 1
fi

fail=0
assert_grep()   { if grep -Eq -- "$1" "$2"; then echo "[hb-inert] PASS $3"; else echo "[hb-inert] FAIL $3 (missing: $1)"; fail=1; fi; }
assert_nogrep() { if grep -Eq -- "$1" "$2"; then echo "[hb-inert] FAIL $3 (present: $1)"; else echo "[hb-inert] PASS $3"; fi; }

# ---------------------------------------------------------------------------
# PART A — <noscript> / <template> sheets are inert.
# ---------------------------------------------------------------------------
A="$OUT/inert_sheets.txt"
if ! "$BIN" "$FX/hambrowse_inert_sheets.html" 880 >"$A" 2>&1; then
    echo "[hb-inert] FAIL: engine exited non-zero on the inert-sheets fixture"; fail=1
fi
# The <noscript> sheet says div,span,p{display:none}; the <template> sheet says
# p{display:none}. Neither may apply: all three elements must still render.
assert_grep '\|VISIBLE-DIV\|'  "$A" "<noscript><style> does not hide <div> (chromium: display=block)"
assert_grep '\|VISIBLE-PARA\|' "$A" "<template><style> does not hide <p> (chromium: display=block)"
assert_grep '\|VISIBLE-SPAN\|' "$A" "<noscript><style> does not hide <span> (chromium: display=inline)"
# ... and the inert CONTENT itself is not rendered as markup.
assert_nogrep 'NOSCRIPT-FALLBACK' "$A" "<noscript> fallback text stays unrendered with scripting enabled"
assert_nogrep 'TEMPLATE-INERT'    "$A" "<template> content stays unrendered until cloned"
# All three elements laid out: a regression that re-applies either sheet drops
# the segment count, which is exactly how google.com went to segs=0.
assert_grep '^LAYOUT segs=3 ' "$A" "exactly the 3 real elements lay out (segs=3, not 0)"
# ... and neither inert region's <script> RUNS. Executing the <noscript> branch
# is actively harmful — it is the no-JS fallback, and real sites use it to
# redirect or rewrite the page for a client without JS.
# CHROMIUM ORACLE on the same markup: ns=0 tp=0, and only the page script runs.
assert_grep 'REAL-SCRIPT-RAN ns=0 tp=0' "$A" "the page's own <script> runs and sees NEITHER inert script's global"
assert_nogrep 'NOSCRIPT-SCRIPT-RAN'     "$A" "<script> inside <noscript> is not executed"
assert_nogrep 'TEMPLATE-SCRIPT-RAN'     "$A" "<script> inside <template> is not executed"

# ---------------------------------------------------------------------------
# PART B — attribute selectors only match real attribute names.
# ---------------------------------------------------------------------------
B="$OUT/inert_attrsel.txt"
if ! "$BIN" "$FX/hambrowse_attrsel_wordpos.html" 880 >"$B" 2>&1; then
    echo "[hb-inert] FAIL: engine exited non-zero on the attr-selector fixture"; fail=1
fi
assert_grep '\|KEEP-HREF-HIDDEN\|'   "$B" '[hidden] does not match href="…/Global_attributes/hidden"'
assert_grep '\|KEEP-VALUE-MENTION\|' "$B" '[hidden] does not match a title="" that mentions the word'
assert_grep '\|KEEP-PREFIXED-NAME\|' "$B" '[hidden] does not match the data-hidden attribute'
assert_nogrep 'DROP-REAL-HIDDEN'     "$B" '[hidden] DOES match the element that really carries it'
# The value op must still read the right attribute: #p1 (data-x="1") is red,
# #p2 (title="data-x=1", no such attribute) is not.
assert_grep '^SEG [0-9]+ [0-9]+ #ff0000 .*\|RED-BY-ATTR-VALUE\|'   "$B" '[data-x="1"] colours the element that has the attribute'
assert_nogrep '^SEG [0-9]+ [0-9]+ #ff0000 .*\|PLAIN-BY-VALUE-MENTION\|' "$B" '[data-x="1"] does not colour an element whose title merely says so'
# Boolean HTML attributes (checked/indeterminate/selected/required/novalidate)
# run on the same quote-aware scan: value="checked disabled" is NOT checked.
assert_grep '\|\[ \]\|'  "$B" 'value="checked disabled" leaves the checkbox UNCHECKED (chromium)'
assert_nogrep '\|\[x\]\|' "$B" 'no phantom checked state from a word inside a quoted value'

if [ "$fail" -ne 0 ]; then
    echo "[hb-inert] RESULT: FAIL"; exit 1
fi
echo "[hb-inert] RESULT: PASS"
