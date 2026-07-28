#!/usr/bin/env bash
# scripts/test_hambrowse_gencontent_host.sh — FAST, QEMU-free gate for CSS
# GENERATED CONTENT (::before / ::after) in the native browser layout engine
# (lib/web/layout/box.ad + the _gencontent_open/_gencontent_close hooks in
# lib/web/dom/forms.ad). The cascade already parses ::before/::after selectors
# but marks them inert; this round GENERATES the inline content box on the
# layout/paint side. It proves:
#
#   .tag::before   { content:"* "; color:#ff8800; font-weight:bold }
#        -> a bold orange "*" inline box BEFORE the element's own text
#   a.ext::after   { content:" >>"; color:#0088ff }
#        -> a blue ">>" inline box AFTER a link's text (pseudo colour overrides
#           the link role colour; the box stays inside the anchor)
#   [data-x]::before { content:attr(data-x) }
#        -> the element's data-x attribute value emitted before its text
#   .empty::before { content:"" }
#        -> an empty inline box: NO glyphs, element text undisturbed
#   .quiet::before { content:none } -> nothing generated (no box, no colour)
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either backend is caught with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_gencontent.html"
mkdir -p "$OUT"

echo "[hb-gencontent] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/gencontent_compile.log"; then
    echo "[hb-gencontent] FAIL: host harness did not compile"; cat "$OUT/gencontent_compile.log"; exit 1
fi
echo "[hb-gencontent] PASS host harness compiled -> $BIN"

echo "[hb-gencontent] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/gencontent_native.log"; then
    echo "[hb-gencontent] FAIL: native hambrowse did not compile"; cat "$OUT/gencontent_native.log"; exit 1
fi
echo "[hb-gencontent] PASS native hambrowse still compiles"

fail=0
D0="$OUT/gencontent_run.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-gencontent] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E '^FLOW|^SEG' "$D0" || true

seg_line() {  # regex over the |text| field -> first matching SEG line
    grep -E "^SEG [0-9]+ [0-9]+ .*\|$1\|" "$D0" | head -1
}

assert_seg() {    # text-regex  field-regex  message
    local ln; ln="$(seg_line "$1")"
    if [ -z "$ln" ]; then
        echo "[hb-gencontent] FAIL $3 (no segment for |$1|)"; fail=1; return
    fi
    if echo "$ln" | grep -Eq -- "$2"; then
        echo "[hb-gencontent] PASS $3"
    else
        echo "[hb-gencontent] FAIL $3 (seg: $ln)"; fail=1
    fi
}

assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-gencontent] FAIL $2 (unexpected: $1)"; fail=1
    else
        echo "[hb-gencontent] PASS $2"
    fi
}

assert_flow() {   # exact-visual-line message
    if grep -Fq -- "$1" "$D0"; then
        echo "[hb-gencontent] PASS $3"
    else
        echo "[hb-gencontent] FAIL $3 (missing FLOW row: $1)"; fail=1
    fi
}

# STALE-ORIGIN RE-PIN (2026-07-27): the FLOW row indent below dropped from 14
# monospace columns to 1. Prose used to be laid out inside a centred ~128px
# "readable measure" strip; the engine now renders plain prose full-width from
# the UA 8px body margin (= exactly one 8px CELL_W column), which is what Chrome
# does — `chromium --headless` reports getBoundingClientRect().x == 8 for every
# <p> in this fixture. Only the leading indent changed; the generated-content
# text each row must carry is untouched.
# content:"* " -> a bold ORANGE star box before the tag text, distinct segment.
assert_seg '\*'     '#ff8800'  "::before string emits its own segment"
assert_seg '\*'     ' b1 '     "::before applies the pseudo font-weight:bold"
assert_seg ' Widget' '#101010' "element's own text follows the ::before box"
assert_flow 'FLOW  * Widget' x "::before renders inline ahead of the text"

# content:" >>" -> a BLUE arrow box after the link; pseudo colour beats link blue.
assert_seg ' >>'    '#0088ff'  "::after string emits after the element text"
assert_seg ' >>'    ' l0 '     "::after inside <a> keeps the link identity"
assert_seg 'Docs'   '#1a4fd0'  "link's own text keeps the link role colour"

# content:attr(data-x) -> the attribute value, in the pseudo's green.
assert_seg 'SKU42-' '#11aa22'  "::before content:attr(x) emits the attribute value"
assert_flow 'FLOW  SKU42-Gizmo' x "attr() content renders ahead of the text"

# content:"" -> empty inline box: no glyphs, the element text is untouched.
assert_flow 'FLOW  Plain' x "empty content generates no visible glyphs"

# content:none -> nothing generated; the .quiet rule's #ff0000 must never paint.
assert_nogrep '#ff0000'        "content:none suppresses the generated box"
assert_flow 'FLOW  Silent' x "content:none leaves the element text intact"

if [ "$fail" -ne 0 ]; then
    echo "[hb-gencontent] RESULT: FAIL"; exit 1
fi
echo "[hb-gencontent] RESULT: PASS"
