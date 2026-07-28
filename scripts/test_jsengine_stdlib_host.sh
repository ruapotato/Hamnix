#!/usr/bin/env bash
# scripts/test_jsengine_stdlib_host.sh — FAST, QEMU-free gate for the JS
# engine's stdlib method coverage (lib/jsengine.ad) via the x86_64-linux host
# driver (user/js_host.ad).
#
# Real interactive pages break when a common Array/String/Math/Object/Number
# method is missing ("value is not a function"). This gate exercises the batch
# of methods added for stdlib completeness and asserts each result against
# node/python semantics with self-contained inline assertions (no external
# oracle file to drift):
#   Array : includes find findIndex some every lastIndexOf concat sort(+cmp)
#           flat fill splice unshift reduceRight
#   String: includes startsWith endsWith padStart padEnd trimStart trimEnd
#           lastIndexOf concat at codePointAt
#   Math  : sign cbrt hypot log log2 exp sin cos tan random + constants
#   Object: entries fromEntries freeze
#   Number: isInteger isNaN isFinite / isFinite(global) / toFixed / toString(radix)
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-stdlib] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_stdlib_compile.log"; then
    echo "[js-stdlib] FAIL: host driver did not compile"; cat "$OUT/js_stdlib_compile.log"; exit 1
fi
echo "[js-stdlib] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_stdlib_case.js"
    local got
    got="$("$BIN" "$OUT/js_stdlib_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-stdlib] PASS $name"
    else
        echo "[js-stdlib] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- Array ----
assert arr_includes    'console.log([1,2,3].includes(2), [1,2,3].includes(5))'                 'true false'
assert arr_find        'console.log([1,2,3].find(x=>x>1), [1,2,3].findIndex(x=>x>1))'           '2 1'
assert arr_some_every  'console.log([1,2,3].some(x=>x>2), [1,2,3].every(x=>x>0), [1,2,3].every(x=>x>1))' 'true true false'
assert arr_lastindexof 'console.log([1,2,1].lastIndexOf(1))'                                    '2'
assert arr_concat      'console.log([1,2].concat([3,4],5).join(","))'                           '1,2,3,4,5'
assert arr_sort_def    'console.log([3,1,2,10].sort().join(","))'                               '1,10,2,3'
assert arr_sort_cmp    'console.log([3,1,2,10].sort((a,b)=>a-b).join(","))'                     '1,2,3,10'
assert arr_flat        'console.log([[1],[2,[3]]].flat(2).join(","))'                           '1,2,3'
assert arr_fill        'console.log([1,2,3,4].fill(9,1,3).join(","))'                           '1,9,9,4'
assert arr_splice_del  'var a=[1,2,3,4];var r=a.splice(1,2);console.log(r.join(",")+"|"+a.join(","))'   '2,3|1,4'
assert arr_splice_ins  'var a=[1,2,3];a.splice(1,0,9,8);console.log(a.join(","))'               '1,9,8,2,3'
assert arr_splice_repl 'var a=[1,2,3,4];a.splice(1,2,0);console.log(a.join(","))'               '1,0,4'
assert arr_unshift     'var a=[2,3];var n=a.unshift(0,1);console.log(n+"|"+a.join(","))'        '4|0,1,2,3'
assert arr_reduceright 'console.log(["a","b","c"].reduceRight((a,b)=>a+b))'                     'cba'

# ---- String ----
assert str_includes    'console.log("hello".includes("ell"), "hello".includes("z"))'           'true false'
assert str_startsends  'console.log("hello".startsWith("he"), "hello".endsWith("lo"))'          'true true'
assert str_padstart    'console.log("x".padStart(3,"0"))'                                        '00x'
assert str_padend      'console.log("x".padEnd(3,"0")+"|")'                                      'x00|'
assert str_trim_side   'console.log("|"+"  x  ".trimStart()+"|"+"  x  ".trimEnd()+"|")'         '|x  |  x|'
assert str_lastindexof 'console.log("abcabc".lastIndexOf("b"))'                                 '4'
assert str_concat      'console.log("a".concat("b","c"))'                                        'abc'
assert str_at          'console.log("abc".at(-1), "abc".at(0))'                                  'c a'
assert str_codepoint   'console.log("A".codePointAt(0))'                                         '65'

# ---- Math ----
assert math_sign       'console.log(Math.sign(-5), Math.sign(3), Math.sign(0))'                 '-1 1 0'
assert math_cbrt       'console.log(Math.cbrt(27), Math.cbrt(-8))'                              '3 -2'
assert math_hypot      'console.log(Math.hypot(3,4))'                                            '5'
assert math_log        'console.log(Math.log(1), Math.log2(8))'                                 '0 3'
assert math_exp0       'console.log(Math.exp(0))'                                                '1'
assert math_sincos     'console.log(Math.sin(0), Math.cos(0), Math.tan(0))'                     '0 1 0'
assert math_random     'var r=Math.random();console.log(r>=0 && r<1, typeof r)'                 'true number'

# ---- Object ----
assert obj_entries     'console.log(JSON.stringify(Object.entries({a:1,b:2})))'                 '[["a",1],["b",2]]'
assert obj_fromentries 'console.log(JSON.stringify(Object.fromEntries([["a",1],["b",2]])))'     '{"a":1,"b":2}'
assert obj_freeze      'var o={a:1};console.log(Object.freeze(o)===o, o.a)'                     'true 1'
assert obj_roundtrip   'console.log(JSON.stringify(Object.fromEntries(Object.entries({x:5}))))' '{"x":5}'

# ---- Number / global ----
assert num_isfinite_g  'console.log(isFinite(1), isFinite(Infinity), isFinite(NaN))'            'true false false'
assert num_isinteger   'console.log(Number.isInteger(3), Number.isInteger(3.5), Number.isInteger("3"))' 'true false false'
assert num_isnan       'console.log(Number.isNaN(NaN), Number.isNaN("x"))'                      'true false'
assert num_isfinite    'console.log(Number.isFinite(3), Number.isFinite(Infinity))'            'true false'
assert num_tofixed     'console.log((3.14159).toFixed(2), (0).toFixed(2), (-1.5).toFixed(0))'   '3.14 0.00 -2'
assert num_tostring    'console.log((255).toString(16), (255).toString(2), (255).toString())'   'ff 11111111 255'

if [ "$fail" -eq 0 ]; then
    echo "[js-stdlib] RESULT: PASS"
    exit 0
else
    echo "[js-stdlib] RESULT: FAIL"
    exit 1
fi
