#!/usr/bin/env bash
# scripts/test_jsengine_unicase_host.sh — FAST, QEMU-free gate for UNICODE CASE
# MAPPING (String.prototype.toUpperCase / toLowerCase) via the x86_64-linux
# host driver (user/js_host.ad).
#
# WHY: case mapping used to be ASCII-ONLY, so "café".toUpperCase() was "CAFé",
# "ПРИВЕТ".toLowerCase() came back unchanged, and "ß".toUpperCase() was not
# "SS". lib/web/js/builtins/unicase.ad now carries the whole BMP as 305 range
# rules (CM_PAIR alternating / CM_CONST constant delta) plus flat 1:many
# tables, both GENERATED FROM `node` itself.
#
# This gate has two halves:
#   1. named cases below — the shapes that actually appear in web text, each
#      replayed through `node` value-by-value;
#   2. an EXHAUSTIVE sweep of every non-surrogate code point in the WHOLE
#      Unicode range (U+0080..U+10FFFF, 1114032 of them) through both methods,
#      diffed against `node` when node is available on the box. That is the
#      real proof; the named cases are the readable regression net that
#      survives on a machine with no node. The sweep is sliced into 0x8000-
#      code-point runs because doing it in one process exhausts the engine
#      string pool (SP_CAP), which would look like a mapping failure.
#
# The sweep is what caught the one real gap in the first cut of unicase.ad:
# node lowercases U+10400 (Deseret) to U+10428, and the table had stopped at
# the BMP. Coverage is now the FULL Unicode range.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-unicase] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_unicase_compile.log"; then
    echo "[js-unicase] FAIL: host driver did not compile"; cat "$OUT/js_unicase_compile.log"; exit 1
fi
echo "[js-unicase] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs-ONE-line> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_unicase_case.js"
    local got
    got="$("$BIN" "$OUT/js_unicase_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-unicase] PASS $name"
    else
        echo "[js-unicase] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- ASCII must be untouched (and stay on the byte fast path) ----
assert ascii       'console.log("Hello, World! 123".toUpperCase(), "ABC-def".toLowerCase())'  'HELLO, WORLD! 123 abc-def'

# ---- Latin-1 / Latin Extended-A: the CM_CONST and CM_PAIR patterns ----
assert latin1_up   'console.log("café".toUpperCase(), "àáâãäåæçèéêëìíîïðñòóôõöøùúûüýþ".toUpperCase())' 'CAFÉ ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞ'
assert latin1_lo   'console.log("CAFÉ".toLowerCase(), "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞ".toLowerCase())' 'café àáâãäåæçèéêëìíîïðñòóôõöøùúûüýþ'
assert exta_pair   'console.log("ĀāĂăĄąĆćĈĉĊċČč".toUpperCase(), "ĀāĂăĄąĆćĈĉĊċČč".toLowerCase())' 'ĀĀĂĂĄĄĆĆĈĈĊĊČČ āāăăąąććĉĉċċčč'
assert polish      'console.log("ąćłżźńó".toUpperCase(), "ĄĆŁŻŹŃÓ".toLowerCase())'         'ĄĆŁŻŹŃÓ ąćłżźńó'
assert yacute      'console.log("ÿ".toUpperCase(), "Ÿ".toLowerCase(), "ı".toUpperCase(), "ſ".toUpperCase())' 'Ÿ ÿ I S'

# ---- Cyrillic / Greek ----
assert cyrillic    'console.log("привет".toUpperCase(), "ПРИВЕТ".toLowerCase())'           'ПРИВЕТ привет'
assert cyr_ext     'console.log("ЀЁЂЃЄЅІЇЈЉЊЋЌЍЎЏ".toLowerCase(), "ѐёђѓєѕіїјљњћќѝўџ".toUpperCase())' 'ѐёђѓєѕіїјљњћќѝўџ ЀЁЂЃЄЅІЇЈЉЊЋЌЍЎЏ'
assert greek       'console.log("άέήίόύώ".toUpperCase(), "ΆΈΉΊΌΎΏ".toLowerCase())'         'ΆΈΉΊΌΎΏ άέήίόύώ'

# ---- FINAL SIGMA is context sensitive ----
assert sigma       'console.log("ΑΣ".toLowerCase(), "ΑΣΒ".toLowerCase(), "Σ".toLowerCase())' 'ας ασβ σ'
assert sigma_mix   'console.log("ΣΣΣ ΑΣ Σ".toLowerCase())'                                    'σσς ας σ'

# ---- FULL (1:many) uppercase ----
assert sharp_s     'console.log("ß".toUpperCase(), "straße".toUpperCase(), "ß".toLowerCase())' 'SS STRASSE ß'
assert cap_sharp_s 'console.log("ẞ".toLowerCase(), "ẞ".toUpperCase())'                    'ß ẞ'
assert ligature    'console.log("ﬁ".toUpperCase(), "ﬄ".toUpperCase(), "ﬅ".toUpperCase())' 'FI FFL ST'
assert multi_misc  'console.log("ŉ".toUpperCase(), "ǰ".toUpperCase().length, "ΐ".toUpperCase().length)' 'ʼN 2 3'
assert dotted_i    'console.log("İ".toLowerCase().length, "İ".toLowerCase().charCodeAt(1))'   '2 775'

# ---- three-way titlecase triples (Ǆ/ǅ/ǆ) ----
assert titlecase   'console.log("ǅ".toUpperCase(), "ǅ".toLowerCase(), "Ǆ".toLowerCase(), "ǆ".toUpperCase())' 'Ǆ ǆ ǆ Ǆ'

# ---- other blocks the table covers ----
assert armenian    'console.log("ԱԲԳ".toLowerCase(), "աբգ".toUpperCase())'                 'աբգ ԱԲԳ'
assert fullwidth   'console.log("ＡＢＣ".toLowerCase(), "ａｂｃ".toUpperCase())'             'ａｂｃ ＡＢＣ'
assert latin_ext_a 'console.log("ḁḃḅḇạả".toUpperCase(), "ḀḂḄḆẠẢ".toLowerCase())'           'ḀḂḄḆẠẢ ḁḃḅḇạả'
assert micro_sign  'console.log("µ".toUpperCase(), "Ⱥ".toLowerCase(), "ⱥ".toUpperCase())'   'Μ ⱥ Ⱥ'

# ---- length can GROW; the result is a fresh string ----
assert grow        'console.log("ß".length, "ß".toUpperCase().length, "ﬄ".toUpperCase().length)' '1 2 3'

# ---- ASTRAL case mapping (Deseret; and a caseless astral char is inert) ----
assert astral      'console.log("\u{10400}".toLowerCase().codePointAt(0), "\u{10428}".toUpperCase().codePointAt(0), "\u{1F600}".toUpperCase()==="\u{1F600}")' '66600 66560 true'

# ---- EXHAUSTIVE Unicode sweep vs node (skipped when node is absent) ----
if command -v node >/dev/null 2>&1; then
    : > "$OUT/js_unicase_ours.txt"
    : > "$OUT/js_unicase_node.txt"
    lo=128
    while [ "$lo" -lt 1114112 ]; do
        hi=$((lo + 32768))
        [ "$hi" -gt 1114112 ] && hi=1114112
        cat > "$OUT/js_unicase_slice.js" <<JS
for (var b = $lo; b < $hi; b += 64) {
    var s = "";
    for (var c = b; c < b + 64 && c < $hi; c++) {
        if (c >= 0xD800 && c <= 0xDFFF) continue;
        s += String.fromCodePoint(c);
    }
    if (s.length === 0) continue;
    console.log(b, JSON.stringify(s.toUpperCase()), JSON.stringify(s.toLowerCase()));
}
JS
        "$BIN" "$OUT/js_unicase_slice.js" >> "$OUT/js_unicase_ours.txt" 2>&1
        node    "$OUT/js_unicase_slice.js" >> "$OUT/js_unicase_node.txt" 2>&1
        lo=$hi
    done
    if diff -q "$OUT/js_unicase_ours.txt" "$OUT/js_unicase_node.txt" >/dev/null; then
        echo "[js-unicase] PASS unicode_sweep (all 1114032 non-surrogate code points match node)"
    else
        echo "[js-unicase] FAIL unicode_sweep — first differences:"
        diff "$OUT/js_unicase_ours.txt" "$OUT/js_unicase_node.txt" | head -12
        fail=1
    fi
else
    echo "[js-unicase] SKIP unicode_sweep (no node on this host; named cases still ran)"
fi

if [ "$fail" -eq 0 ]; then
    echo "[js-unicase] ALL PASS"
    exit 0
fi
echo "[js-unicase] FAILURES present"
exit 1
