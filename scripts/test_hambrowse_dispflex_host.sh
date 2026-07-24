#!/usr/bin/env bash
# scripts/test_hambrowse_dispflex_host.sh — FAST, QEMU-free gate for the
# round-2 web-standards rungs in the native browser engine (lib/htmlengine.ad):
#
#   (1) display:block / inline-block on an otherwise-inline or unknown element
#       (`label{display:block}`, a class/inline `display:block` span). The
#       element becomes a full-width block box on its own row (form labels stack
#       above their inputs; block-ified spans paint their whole box).
#
#   (2) FLEX with inline (<span>) children + justify-content. A `display:flex`
#       navbar of spans no longer jams at the left: the spans spread into equal
#       columns across the container, and the container's own background paints
#       as a full-width bar. `flex-direction:column` STACKS its children
#       vertically instead of forcing side-by-side columns.
#
#   (3) PAGE-LEVEL background. A <body>/<html> `background` fills the WHOLE
#       viewport (not just element boxes), and the body's text `color` inherits
#       to descendant paragraphs — a dark theme renders readable.
#
# All three are web-standards features shared by a large class of real pages
# (forms, navbars/toolbars, themed pages), so a regression in any must fail here
# without a QEMU boot. Builds BOTH targets (host harness x86_64-linux + native
# hambrowse x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_dispflex.html"
mkdir -p "$OUT"

echo "[hb-dispflex] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-dispflex] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-dispflex] PASS host harness compiled -> $BIN"

echo "[hb-dispflex] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-dispflex] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-dispflex] PASS native hambrowse still compiles"

fail=0
D0="$OUT/dispflex.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-dispflex] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-dispflex] PASS $2"
    else
        echo "[hb-dispflex] FAIL $2 (missing: $1)"; fail=1
    fi
}

seg_row() {   # text -> the row of the SEG carrying it
    grep -E "SEG [0-9]+ [0-9]+ .*\|$1" "$D0" | awk '{print $2}' | head -1
}
seg_x() {     # text -> the x of the SEG carrying it
    grep -E "SEG [0-9]+ [0-9]+ .*\|$1" "$D0" | awk '{print $3}' | head -1
}

# ---- (1) display:block on inline elements ----------------------------------
lr1=$(seg_row "First name")
lr2=$(seg_row "Second name")
ir1=$(seg_row "\[____________________\]")
echo "[hb-dispflex] label rows: first=$lr1 second=$lr2 (first input row=$ir1)"
if [ -n "$lr1" ] && [ -n "$lr2" ] && [ "$lr2" -gt "$lr1" ]; then
    echo "[hb-dispflex] PASS display:block labels each take their own row (stacked)"
else
    echo "[hb-dispflex] FAIL labels did not stack (first=$lr1 second=$lr2)"; fail=1
fi
# The block-ified span paints its WHOLE box (a FILL), not just behind the text.
# FULL-WIDTH SCOPING: this page uses display:flex, so the readable-measure gutter
# is disabled and the block box spans the true body width (0..800) like Firefox,
# not the old 584px-centred strip (was 100..700 at width 800). More-correct.
assert_grep 'FILL [0-9]+ [0-9]+ 0 800 #ffcc00' "display:block span paints its full-width box"

# ---- (2) flex span navbar spreads + container bar + column direction -------
hx=$(seg_x "Home")
cx=$(seg_x "Contact")
echo "[hb-dispflex] nav span x: Home=$hx Contact=$cx"
if [ -n "$hx" ] && [ -n "$cx" ] && [ "$cx" -gt "$((hx + 200))" ]; then
    echo "[hb-dispflex] PASS flex <span> navbar spreads into columns (Home $hx -> Contact $cx)"
else
    echo "[hb-dispflex] FAIL flex span nav did not spread (Home=$hx Contact=$cx)"; fail=1
fi
# FULL-WIDTH SCOPING (as above): the flex container's background bar now spans
# the true body width (0..800) like Firefox, not the 584px-centred strip.
assert_grep 'FILL [0-9]+ [0-9]+ 0 800 #223344' "flex container paints its full-width background bar"
# flex-direction:column stacks children on DIFFERENT rows (not side-by-side).
s1=$(seg_row "Stacked one")
s2=$(seg_row "Stacked two")
echo "[hb-dispflex] flex-column rows: one=$s1 two=$s2"
if [ -n "$s1" ] && [ -n "$s2" ] && [ "$s2" -gt "$s1" ]; then
    echo "[hb-dispflex] PASS flex-direction:column stacks children vertically"
else
    echo "[hb-dispflex] FAIL flex-direction:column did not stack (one=$s1 two=$s2)"; fail=1
fi

# ---- (3) page background + body colour inheritance -------------------------
assert_grep '^PAGEBG #101830' "body background fills the whole viewport (PAGEBG)"
# The plain <p> inherits the body's text colour (#e8e8f0), not the default black.
assert_grep 'SEG [0-9]+ [0-9]+ #e8e8f0 .*\|Body colour inherits' "body color inherits to descendant paragraph"

if [ "$fail" -ne 0 ]; then
    echo "[hb-dispflex] RESULT: FAIL"; exit 1
fi
echo "[hb-dispflex] RESULT: PASS"
