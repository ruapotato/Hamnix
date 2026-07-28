#!/usr/bin/env bash
# scripts/test_jsengine_reunicode_host.sh — FAST, QEMU-free gate for the RegExp
# `u`/`v` (Unicode) flag subset in the JS engine (lib/web/js/setup.ad +
# lib/web/js/lexer.ad), via the x86_64-linux host driver (user/js_host.ad).
#
# THE GAP (round-7 remaining map, item 1): the byte-oriented regex engine had NO
# unicode mode. `\u{CP}` code-point escapes, `😀` surrogate-pair
# combining, and `\p{...}` property classes were all unsupported; the `u`/`v`
# flags were ignored (no `unicode`/`unicodeSets` reflection). String literals
# also dropped `\u{CP}` escapes entirely.
#
# THE FEATURE (honest subset — the engine stores strings as UTF-8 byte buffers):
#   * lexer: string/template `\u{CP}` braced escapes + `\uHHHH\uHHHH` surrogate
#     pairs decode to their UTF-8 byte sequence (emit_utf8).
#   * regex: the `u`/`v` flag sets re_uni + reflects `unicode`/`unicodeSets`.
#     `\u{CP}` and combined surrogate pairs compile to a UTF-8 byte-sequence atom
#     that matches ASTRAL characters in a UTF-8 subject byte-for-byte (quantifiers
#     apply to the whole code point). `\p{Name}`/`\P{Name}` general-category
#     property classes (L, N/Nd, Lu, Ll, White_Space, ASCII, + long aliases) are
#     supported over the ASCII range, top-level and inside [...] classes.
#
# DEFERRED (documented in docs/browser_w3c_conformance.md): astral/Latin-1
# code-point property matching (byte engine); case-fold operates on bytes;
# astral members inside a [...] class (a byte bitmap cannot hold them).
# NOTE: `.` and character classes now consume a WHOLE UTF-8 sequence rather
# than one byte (they used to return sequence FRAGMENTS), so the engine behaves
# as if `u` were always on for single-character consumers.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-reuni] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/js_host.ad -o "$BIN" 2>"$OUT/js_reuni_compile.log"; then
    echo "[js-reuni] FAIL: host driver did not compile"; cat "$OUT/js_reuni_compile.log"; exit 1
fi
echo "[js-reuni] PASS host driver compiled -> $BIN"

fail=0
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_reuni_case.js"
    local got
    got="$("$BIN" "$OUT/js_reuni_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-reuni] PASS $name"
    else
        echo "[js-reuni] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- flag reflection ----
assert unicode_on     'console.log(/a/u.unicode)'                              'true'
assert unicode_off    'console.log(/a/.unicode)'                               'false'
assert vsets_on       'console.log(/a/v.unicodeSets)'                          'true'
assert v_implies_uni  'console.log(/a/v.unicode||/a/v.unicodeSets)'            'true'
assert flags_has_u    'console.log(/a/giu.flags.indexOf("u")>=0)'             'true'

# ---- string-literal \u{CP} decoding (lexer) ----
assert str_braced     'console.log("\u{41}\u{42}\u{43}")'                      'ABC'
# An astral code point is TWO UTF-16 code units, so .length is 2 — measured
# `node -e 'console.log("\u{1F600}".length)'` => 2, and chromium --headless
# (title probe) => "L=2,55357". The former expectation of 4 was the engine's
# stored UTF-8 BYTE count, which neither oracle produces.
assert str_astral_len 'console.log("\u{1F600}".length)'                        '2'
assert str_astral_cca 'console.log("\u{1F600}".charCodeAt(0))'                  '55357'
assert str_surrogate  'console.log("😀"==="\u{1F600}")'             'true'

# ---- \u{CP} code-point escapes in u-mode ----
assert astral_test    'console.log(/\u{1F600}/u.test("x\u{1F600}y"))'         'true'
assert astral_index   'console.log("ab\u{1F600}c".match(/\u{1F600}/u).index)' '2'
assert astral_exec    'console.log(/\u{1F600}/u.exec("\u{1F600}!")[0]==="\u{1F600}")' 'true'
assert braced_ascii   'console.log(/\u{41}/u.test("A"))'                       'true'
assert emoji_literal  'console.log(/\u{1F600}/u.test("😀"))'        'true'

# ---- surrogate pair in a regex literal ----
assert surrogate_re   'console.log(/😀/u.test("\u{1F600}"))'        'true'

# ---- quantifier applies to the whole code point ----
assert astral_plus    'console.log(/\u{1F600}+/u.exec("\u{1F600}\u{1F600}Z")[0]==="\u{1F600}\u{1F600}")' 'true'
assert astral_nomatch 'console.log(/\u{1F600}/u.test("\u{1F601}"))'          'false'

# ---- \p{...} / \P{...} property classes (ASCII range) ----
assert prop_L         'console.log(/^\p{L}+$/u.test("Hello"))'                'true'
assert prop_L_alias   'console.log(/^\p{Letter}+$/u.test("abc"))'            'true'
assert prop_N         'console.log(/\p{N}/u.test("7"))'                        'true'
assert prop_Nd        'console.log(/^\p{Nd}+$/u.test("2026"))'               'true'
assert prop_Lu_yes    'console.log(/\p{Lu}/u.test("aX"))'                     'true'
assert prop_Lu_no     'console.log(/\p{Lu}/u.test("abc"))'                    'false'
assert prop_Ll        'console.log(/^\p{Ll}+$/u.test("lower"))'              'true'
assert prop_negL      'console.log(/\P{L}/u.test("5"))'                       'true'
assert prop_negL_no   'console.log(/^\P{L}+$/u.test("abc"))'                 'false'
assert prop_ws        'console.log(/\p{White_Space}/u.test("a b"))'          'true'
assert prop_ascii     'console.log(/^\p{ASCII}+$/u.test("plain"))'          'true'

# ---- property classes inside a [...] set ----
assert class_prop_n   'console.log(/[\p{N}]+/u.exec("abc123")[0])'           '123'
assert class_prop_mix 'console.log(/[\p{L}\p{N}]+/u.exec(" a1b2 ")[0])'      'a1b2'
assert class_prop_neg 'console.log(/[\P{L}]/u.test("5"))'                    'true'

# ---- legacy (non-u) behavior preserved ----
assert nonu_p_literal 'console.log(/\p/.test("p"))'                           'true'
assert nonu_replace   'console.log("a\u{1F600}b".replace(/\u{1F600}/u,"_"))' 'a_b'

if [ "$fail" -ne 0 ]; then
    echo "[js-reuni] RESULT: FAIL"; exit 1
fi
echo "[js-reuni] RESULT: PASS"
