#!/usr/bin/env bash
# scripts/test_hambrowse_tagquote_host.sh — FAST, QEMU-free gate for QUOTE-AWARE
# tag-boundary tokenization (lib/web/html/tags.ad _hx_tag_end / _hx_tag_end_p),
# W3C html5-parsing round 2.
#
# HTML rule: inside a double- or single-quoted attribute value, a '>' byte is
# ordinary value text — it does NOT close the tag ("attribute value (quoted)"
# tokenizer states). Before this round every tag-boundary scan naively advanced
# to the first '>' byte, so markup like <a title="a>b">, <span data-x="a>b">,
# or <input value="v>w"> ended the tag early and leaked the value tail (b">…)
# as visible page text, corrupting the whole rest of the line.
#
# This gate renders a fixture whose tags carry '>' inside quoted attributes and
# asserts on the reconstructed FLOW (never glyph-ink pixels): the element text
# renders clean and NONE of the attribute-value tail leaks into the flow.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler — a regression in either
# target fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_tagquote.html"
mkdir -p "$OUT"

echo "[hb-tq] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/tq_compile.log"; then
    echo "[hb-tq] FAIL: host harness did not compile"; cat "$OUT/tq_compile.log"; exit 1
fi
echo "[hb-tq] PASS host harness compiled -> $BIN"

echo "[hb-tq] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/tq_native.log"; then
    echo "[hb-tq] FAIL: native hambrowse did not compile"; cat "$OUT/tq_native.log"; exit 1
fi
echo "[hb-tq] PASS native hambrowse still compiles"

fail=0
D0="$OUT/tq_run.txt"
if ! "$BIN" "$FIX" 700 >"$D0" 2>&1; then
    echo "[hb-tq] FAIL: render exited non-zero"; cat "$D0"; exit 1
fi
grep '^FLOW' "$D0" || true

assert_grep() {   # literal-pattern message
    if grep -Fq -- "$1" "$D0"; then
        echo "[hb-tq] PASS $2"
    else
        echo "[hb-tq] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # literal-pattern message
    if grep -Fq -- "$1" "$D0"; then
        echo "[hb-tq] FAIL $2 (leaked: $1)"; fail=1
    else
        echo "[hb-tq] PASS $2"
    fi
}

# Each element renders clean, with the following literal words intact, and NO
# attribute-value tail leaks into the visible flow.
assert_grep 'ALPHA LINKONE END1'  "<a title=\"a>b\"> anchor text renders clean (double-quoted '>')"
assert_grep 'BETA SPANTWO END2'   "<span data-x=\"if(a>b&&c<d)\"> renders clean ('>' and '<' in value)"
assert_grep 'GAMMA BOLDY END3'    "<b title='p>q>r'> renders clean (single-quoted, multiple '>')"
assert_grep 'DELTA MIXQ END4'     "mixed single/double quoted attrs with '>' render clean"
assert_grep 'EPS [v>w'            "<input value=\"v>w\"> keeps the '>' inside the field value"

# The attribute-value tails must NOT leak into the page text.
assert_nogrep 'a>b"'   "no leaked double-quoted attribute tail (a>b\")"
assert_nogrep 'b&&c'   "no leaked span data-x tail"
assert_nogrep "q>r'"   "no leaked single-quoted attribute tail (q>r')"
assert_nogrep 'm>n"'   "no leaked mixed-quote attribute tail"

# ---------------------------------------------------------------- DOM view.
# The LAYOUT scanner was made quote-aware first (round 2); the DOM, forms,
# CSS-harvest, table and flex scanners each kept their own naive "advance to
# the first '>'" walk, so textContent still leaked attribute tails long after
# the rendered flow was clean — <span title="x > y"> gave `A y">BC` for `ABC`,
# and wikipedia's body.textContent over-reported by 21231 chars.
#
# Every expectation below is chromium --headless --dump-dom on THIS fixture:
#   TQ dt=[ABC] TQ dt2=[PQR] TQ dt3=[MNO] TQ dt5=[Uy>VW] TQ title=[x > y]
assert_grep 'TQ dt=[ABC]'      "textContent: '>' inside a double-quoted attr is value text"
assert_grep 'TQ dt2=[PQR]'     "textContent: '><' inside a single-quoted JSON attr is value text"
assert_grep 'TQ dt3=[MNO]'     "textContent: two quoted attrs each carrying '>'"
assert_grep 'TQ dt5=[Uy>VW]'   "textContent: an UNQUOTED value still ends at the first '>'"
assert_grep 'TQ title=[x > y]' "getAttribute keeps the '>' inside the value"
assert_nogrep 'JSERR'          "no script error"

if [ "$fail" -ne 0 ]; then
    echo "[hb-tq] RESULT: FAIL"; exit 1
fi
echo "[hb-tq] RESULT: PASS"
