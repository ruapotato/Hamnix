#!/usr/bin/env bash
# scripts/test_jsengine_strpos_host.sh — FAST, QEMU-free gate for STRING
# POSITION ARGUMENTS and the Object.*/JSON edges around them, via the
# x86_64-linux host driver (user/js_host.ad).
#
# WHY: a cluster of String.prototype methods silently ignored or mis-converted
# their position arguments, so code that looked right returned the wrong thing
# with no error:
#   * substring behaved like slice — it neither CLAMPED a negative argument to
#     0 nor SWAPPED start/end. "hello".substring(3,1) was "" (node: "el") and
#     "hello".substring(-2) was "lo" (node: "hello").
#   * startsWith / includes ignored their START position and endsWith ignored
#     its END position entirely. Note endsWith's second argument is an END, not
#     a start: "hello".endsWith("hell",4) is TRUE.
#   * split ignored `limit` completely.
# All of them went through cast[int32](to_number(...)), which produced garbage
# for NaN and Infinity and never clamped; the shared clamp_pos/rel_pos now do
# ToIntegerOrInfinity properly — TRUNCATE toward zero FIRST, then clamp, which
# is observably different ("hello".slice(-2.5) is "lo", not "o").
#
# Also pinned here: Object.keys/values/entries/getOwnPropertyNames over a
# PRIMITIVE STRING (they returned [] instead of the index keys over its UTF-16
# code units), and JSON.stringify's well-formed escaping of a LONE SURROGATE.
#
# EVERY EXPECTATION BELOW WAS REPLAYED THROUGH `node` VALUE-BY-VALUE.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-strpos] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_strpos_compile.log"; then
    echo "[js-strpos] FAIL: host driver did not compile"; cat "$OUT/js_strpos_compile.log"; exit 1
fi
echo "[js-strpos] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs-ONE-line> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_strpos_case.js"
    local got
    got="$("$BIN" "$OUT/js_strpos_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-strpos] PASS $name"
    else
        echo "[js-strpos] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- substring CLAMPS and SWAPS; slice does neither ----
assert sub_swap    'console.log("hello".substring(3,1), "hello".substring(1,3))'                      'el el'
assert sub_neg     'console.log("hello".substring(-2), "hello".substring(-1,-3)+"|")'                 'hello |'
assert sub_over    'console.log("hello".substring(1,99), "hello".substring(99))'                      'ello '
assert sub_nan     'console.log("hello".substring(NaN,3), "hello".substring(1.7,4.9))'                'hel ell'
assert sub_undef   'console.log("hello".substring(1,undefined), "hello".substring(undefined,2))'      'ello he'
assert slice_keeps 'console.log("hello".slice(3,1)+"|", "hello".slice(-2), "hello".slice(-2.5))'      '| lo lo'
assert sub_mb      'console.log("café".substring(3), "café".substring(4,3))'              'é é'

# ---- startsWith / includes take a START position ----
assert sw_pos      'console.log("hello".startsWith("llo",2), "hello".startsWith("llo"))'              'true false'
assert sw_clamp    'console.log("hello".startsWith("h",-5), "hello".startsWith("o",99), "hello".startsWith("",99))' 'true false true'
assert inc_pos     'console.log("hello".includes("h",1), "hello".includes("lo",3), "hello".includes("",99))' 'false true true'
assert sw_mb       'console.log("café".startsWith("é",3), "café".startsWith("fé",2))' 'true true'

# ---- endsWith takes an END position, NOT a start ----
assert ew_end      'console.log("hello".endsWith("hell",4), "hello".endsWith("h",1))'                 'true true'
assert ew_default  'console.log("hello".endsWith("o"), "hello".endsWith("l"))'                        'true false'
assert ew_clamp    'console.log("hello".endsWith("l",-1), "hello".endsWith("",0), "hello".endsWith("hello",99))' 'false true true'
assert ew_mb       'console.log("café".endsWith("é"), "café".endsWith("caf",3))'          'true true'

# ---- split honours limit (ToUint32: 0 -> [], negative/undefined -> no limit) ----
assert spl_lim     'console.log(JSON.stringify("a,b,c,d".split(",",2)))'                              '["a","b"]'
assert spl_zero    'console.log(JSON.stringify("a,b,c".split(",",0)), JSON.stringify("abc".split("",0)))' '[] []'
assert spl_undefsep 'console.log(JSON.stringify("abc".split(undefined,0)), JSON.stringify("abc".split(undefined,1)))' '[] ["abc"]'
assert spl_neg     'console.log(JSON.stringify("a,b,c".split(",",-1)), JSON.stringify("a,b,c".split(",",undefined)))' '["a","b","c"] ["a","b","c"]'
assert spl_empty   'console.log(JSON.stringify("abcd".split("",2)), JSON.stringify("aé b".split("",3)))' '["a","b"] ["a","é"," "]'
assert spl_regex   'console.log(JSON.stringify("a1b2c".split(/\d/,2)), JSON.stringify("a1b2c".split(/(\d)/,3)))' '["a","b"] ["a","1","b"]'
assert spl_big     'console.log(JSON.stringify("a,b".split(",",4294967295)))'                         '["a","b"]'

# ---- Object.* over a PRIMITIVE STRING ----
assert obj_keys    'console.log(JSON.stringify(Object.keys("abé")), JSON.stringify(Object.keys("")))' '["0","1","2"] []'
assert obj_astral  'console.log(JSON.stringify(Object.keys("\u{1F600}")))'                            '["0","1"]'
assert obj_values  'console.log(JSON.stringify(Object.values("ab")), JSON.stringify(Object.entries("ab")))' '["a","b"] [["0","a"],["1","b"]]'
assert obj_gopn    'console.log(JSON.stringify(Object.getOwnPropertyNames("ab")))'                    '["0","1","length"]'
assert obj_nonstr  'console.log(JSON.stringify(Object.keys(42)), JSON.stringify(Object.values(true)))' '[] []'
assert forin_str   'var k=[];for(var i in "abc")k.push(i);console.log(JSON.stringify(k))'             '["0","1","2"]'

# ---- JSON.stringify escapes a LONE surrogate, keeps a well-formed pair ----
assert json_lone   'console.log(JSON.stringify("\uD800"), JSON.stringify("a\uDC00b"))'                '"\ud800" "a\udc00b"'
assert json_pair   'console.log(JSON.stringify("\u{1F600}"), JSON.stringify("café"))'            '"😀" "café"'
assert json_nest   'console.log(JSON.stringify({a:"\uD834"}))'                                        '{"a":"\ud834"}'

# ---- the ASCII fast path must be untouched ----
assert ascii_all   'var s="The quick brown fox";console.log(s.substring(4,9), s.startsWith("The"), s.endsWith("fox"), s.includes("brown"), s.split(" ").length)' 'quick true true true 4'

if [ "$fail" -eq 0 ]; then
    echo "[js-strpos] ALL PASS"
    exit 0
fi
echo "[js-strpos] FAILURES present"
exit 1
