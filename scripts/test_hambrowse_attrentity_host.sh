#!/usr/bin/env bash
# scripts/test_hambrowse_attrentity_host.sh — FAST, QEMU-free gate that
# ATTRIBUTE VALUES reaching JavaScript are ENTITY-DECODED, end to end.
#
# WHY: the HTML tokenizer decodes character references inside attribute values,
# but every DOM read in this engine copied the RAW SOURCE SPAN. So
# `<input value="&eacute;t&eacute;">` reached script as 17 bytes where chromium
# reports 3 characters, and `getAttribute("href")` on `?a=1&amp;b=2` handed
# back a literal `&amp;` — which breaks every page that reads a URL out of the
# DOM and re-navigates to it. This is the attribute-side companion to
# scripts/test_hambrowse_utf16dom_host.sh (text nodes) and
# scripts/test_jsengine_utf16_host.sh (the string layer).
#
# EVERY EXPECTED LINE BELOW IS A MEASURED `chromium --headless --dump-dom`
# VALUE for this exact fixture. Two of them are the interesting ones:
#   * a1.href keeps its literal `&not=` — chromium does NOT decode the
#     semicolon-less `&not` when the next character is `=`, so a query string
#     survives intact, while `&amp;b` in the same attribute DOES decode.
#   * d1.title is "1 2" with charCode 160, NOT a folded space: the DOM
#     view of `&nbsp;` is a real U+00A0 (pages branch on it), even though
#     LAYOUT still folds it to a space. That is the ent_dom_mode split.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_attrentity.html"
mkdir -p "$OUT"

echo "[hb-attrent] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/attrentity_compile.log"; then
    echo "[hb-attrent] FAIL: host harness did not compile"; cat "$OUT/attrentity_compile.log"; exit 1
fi
echo "[hb-attrent] PASS host harness compiled -> $BIN"

echo "[hb-attrent] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/attrentity_native.log"; then
    echo "[hb-attrent] FAIL: native hambrowse did not compile"; cat "$OUT/attrentity_native.log"; exit 1
fi
echo "[hb-attrent] PASS native hambrowse still compiles"

D0="$OUT/attrentity_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-attrent] FAIL: render exited non-zero"; exit 1; }
grep -E 'JSLOG|JSERR' "$D0" || true

fail=0
assert_line() {
    if grep -Fqx -- "JSLOG $1" "$D0"; then echo "[hb-attrent] PASS $2"
    else echo "[hb-attrent] FAIL $2"; echo "    want: JSLOG $1"; fail=1; fi
}

if grep -q 'JSERR' "$D0"; then echo "[hb-attrent] FAIL script raised JSERR"; fail=1; fi

assert_line "i1.value été 3" "input value: named entities decoded, length in characters"
assert_line "i2.value a&b<c>d\"e" "input value: the &amp;/&lt;/&gt;/&quot; core set"
assert_line "a1.href ?a=1&not=2&b=3" "getAttribute(href): &amp; decodes, semicolon-less &not= does NOT"
assert_line "d1.title 1 2 160 3" "title: &nbsp; is a real U+00A0 in the DOM view"
assert_line "d1.class c&d" "className is decoded"
assert_line "d1.data p&q p&q" "getAttribute(data-*) and dataset agree, both decoded"
assert_line "i3.name n&m" "name attribute is decoded"
assert_line "i3.value éA  3" "numeric &#233; / &#x41; / &nbsp; in one value"
assert_line "m1 /x?u=a&v=b café 4" "reflected alt and getAttribute(src) are decoded"
assert_line "t1.value été 3" "textarea value (text node path) stays correct"
assert_line "e1 plain one two one two" "entity-free attributes are byte-identical"

if [ "$fail" -eq 0 ]; then
    echo "[hb-attrent] ALL PASS"
    exit 0
fi
echo "[hb-attrent] FAILURES present"
exit 1
