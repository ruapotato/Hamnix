#!/usr/bin/env bash
# scripts/test_jsengine_toprimitive_host.sh — FAST, QEMU-free gate for
# ToPrimitive (ES2023 7.1.1) and everything that routes through it, via the
# x86_64-linux host driver (user/js_host.ad).
#
# WHY THIS GATE EXISTS
# ToPrimitive was entirely absent for objects. to_string_val handed every object
# to display_val — the CONSOLE INSPECT renderer — and to_number returned NaN for
# objects outright, so:
#
#     String([5])   -> "[5]"        (node: "5")
#     ""+[3]        -> "[3]"        (node: "3")
#     [1,2].toString() -> "[object Array]"   (node: "1,2")
#     Number([5])   -> NaN          (node: 5)
#     [5]==5        -> false        (node: true)
#     String({})    -> "{  }"       (node: "[object Object]")
#     ""+{valueOf:()=>7} -> "{ valueOf: function }"   (node: "7")
#
# and valueOf / toString / Symbol.toPrimitive overrides were ignored. String
# concatenation with an array or object is everywhere in ordinary JS, so this
# was not an edge case — it silently corrupted text on real pages.
#
# WHAT IS PINNED HERE
#   * ToPrimitive structure: @@toPrimitive first (and that it BEATS
#     valueOf/toString), else OrdinaryToPrimitive with the hint-ordered pair
#     (valueOf,toString for number/default; toString,valueOf for string), only
#     CALLABLE properties are called, and a pair that both return objects is a
#     TypeError.
#   * ToString / ToNumber / `+` / `==` / relational / template literals /
#     computed property keys all going through it.
#   * Array.prototype.toString DELEGATING to join (including a user override),
#     and join stringifying elements with ToString rather than the inspect
#     renderer.
#   * Object.prototype.toString tags, including @@toStringTag and wrappers.
#   * Date defaulting to the STRING hint: `date + 1` concatenates, `date - 1`
#     is numeric.
#   * Cyclic arrays rendering the self-reference as "" instead of recursing,
#     and a self-referential valueOf raising RangeError instead of a segfault.
#   * Number/String/Boolean WRAPPER objects carrying a [[PrimitiveValue]].
#
# EVERY expectation below was produced by running the same one-liner through
# `node` (v20) under TZ=UTC and pasting its stdout — not from reading the spec.
# TZ=UTC is pinned because node's Date.prototype.toString is LOCAL time while
# this engine has no timezone database and is always UTC; under TZ=UTC the two
# agree exactly, character for character.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
export TZ=UTC

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-toprim] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_toprim_compile.log"; then
    echo "[js-toprim] FAIL: host driver did not compile"; cat "$OUT/js_toprim_compile.log"; exit 1
fi
echo "[js-toprim] PASS host driver compiled -> $BIN"

fail=0
ran=0
# assert <name> <js-that-console.logs-ONE-line> <expected-first-line-from-node>
assert() {
    local name="$1" js="$2" exp="$3"
    ran=$((ran + 1))
    printf '%s\n' "$js" > "$OUT/js_toprim_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/js_toprim_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-toprim] PASS $name"
    else
        echo "[js-toprim] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

assert string_of_array                  'console.log(String([5]))' '5'
assert concat_array                     'console.log(""+[3])' '3'
assert array_tostring                   'console.log([1,2].toString())' '1,2'
assert number_of_array                  'console.log(Number([5]))' '5'
assert loose_eq_array                   'console.log([5]==5)' 'true'
assert string_of_object                 'console.log(String({}))' '[object Object]'
assert string_of_date                   'console.log(String(new Date(0)))' 'Thu Jan 01 1970 00:00:00 GMT+0000 (Coordinated Universal Time)'
assert concat_valueof                   'console.log(""+{valueOf:()=>7})' '7'
assert concat_tostring                  'console.log(""+{toString:()=>"ts"})' 'ts'
assert valueof_beats_tostring           'console.log(""+{valueOf:()=>7,toString:()=>"ts"})' '7'
assert string_hint_prefers_tostring     'console.log(String({valueOf:()=>7,toString:()=>"ts"}))' 'ts'
assert template_array                   'console.log(`${[1,2]}`)' '1,2'
assert template_object                  'console.log(`${{}}`)' '[object Object]'
assert empty_arrays                     'console.log([]+[])' ''
assert array_plus_object                'console.log([]+{})' '[object Object]'
assert num_plus_array                   'console.log(1+[2])' '12'
assert array_times                      'console.log([2]*3)' '6'
assert array_concat_empty               'console.log([1,2]+"")' '1,2'
assert nested_array_tostring            'console.log([[1],[2]].toString())' '1,2'
assert holes_and_nullish                'console.log([null,undefined,1].toString())' ',,1'
assert deep_nested_join                 'console.log([1,[2,[3]]].toString())' '1,2,3'
assert sparse_string                    'console.log(String([1,,3]))' '1,,3'
assert date_minus                       'console.log(new Date(0)-0)' '0'
assert date_plus_is_string              'console.log(typeof (new Date(0)+1))' 'string'
assert date_times_is_number             'console.log(1*new Date(5))' '5'
assert object_concat_empty              'console.log({}+"")' '[object Object]'
assert array_lt_number                  'console.log([5]<6)' 'true'
assert array_gt_number                  'console.log([5]>4)' 'true'
assert object_eq_tag                    'console.log(({}) == "[object Object]")' 'true'
assert string_of_bools                  'console.log(String([true,false]))' 'true,false'
assert unary_plus_empty_array           'console.log(+[])' '0'
assert unary_plus_nested_empty          'console.log(+[[]])' '0'
assert unary_plus_object                'console.log(+{})' 'NaN'
assert array_eq_true                    'console.log([1]==true)' 'true'
assert array_eq_false                   'console.log([0]==false)' 'true'
assert noncallable_tostring_skipped     'console.log(String({toString:null,valueOf:()=>3}))' '3'
assert symbol_toprimitive_string        'console.log(String({[Symbol.toPrimitive](h){return "hint:"+h}}))' 'hint:string'
assert symbol_toprimitive_number        'console.log(+{[Symbol.toPrimitive](h){return h==="number"?42:0}})' '42'
assert symbol_toprimitive_template      'console.log(`${{[Symbol.toPrimitive](h){return h}}}`)' 'string'
assert symbol_toprimitive_default       'console.log(""+{[Symbol.toPrimitive](h){return h}})' 'default'
assert symbol_toprimitive_beats_valueof 'console.log(""+{[Symbol.toPrimitive](){return 1},valueOf(){return 2},toString(){return "3"}})' '1'
assert optostring_array                 'console.log(Object.prototype.toString.call([]))' '[object Array]'
assert optostring_date                  'console.log(Object.prototype.toString.call(new Date(0)))' '[object Date]'
assert optostring_null                  'console.log(Object.prototype.toString.call(null))' '[object Null]'
assert optostring_regexp                'console.log(Object.prototype.toString.call(/x/))' '[object RegExp]'
assert optostring_function              'console.log(Object.prototype.toString.call(function(){}))' '[object Function]'
assert optostring_tag                   'var o={};o[Symbol.toStringTag]="Xy";console.log(Object.prototype.toString.call(o))' '[object Xy]'
assert optostring_wrappers              'console.log(Object.prototype.toString.call(new Number(5)), Object.prototype.toString.call(new String("x")), Object.prototype.toString.call(new Boolean(true)))' '[object Number] [object String] [object Boolean]'
assert json_unaffected                  'console.log(JSON.stringify([1,2]))' '[1,2]'
assert join_explicit                    'console.log([1,2].join("-"), [1,2].join())' '1-2 1,2'
assert string_of_object_in_array        'console.log(String([{}]))' '[object Object]'
assert string_of_plain_object           'console.log(String({a:1}))' '[object Object]'
assert deep_single_nest                 'console.log(""+[[["x"]]])' 'x'
assert cyclic_array                     'var a=[1];a.push(a);console.log(String(a))' '1,'
assert map_string                       'console.log(String([1,2,3].map(String)))' '1,2,3'
assert string_concat_nullish            'console.log("x"+null+undefined)' 'xnullundefined'
assert array_of_null                    'console.log([null]+"")' ''
assert array_of_undefined               'console.log(String([undefined]))' ''
assert zero_eq_object                   'console.log(0=={})' 'false'
assert both_return_objects_throws       'try{""+{valueOf:()=>({}),toString:()=>({})}}catch(e){console.log(e.name+": "+e.message)}' 'TypeError: Cannot convert object to primitive value'
assert valueof_object_falls_to_tostring 'console.log(""+{valueOf:()=>({}),toString:()=>"ok"})' 'ok'
assert date_concat_matches_tostring     'console.log(new Date(0)+"" === new Date(0).toString())' 'true'
assert date_string_full                 'console.log(String(new Date(86400000)))' 'Fri Jan 02 1970 00:00:00 GMT+0000 (Coordinated Universal Time)'
assert invalid_date_string              'console.log(new Date(NaN).toString())' 'Invalid Date'
assert array_minus_array                'console.log([2]-[1])' '1'
assert array_relational_strings         'console.log([1]<[2], ["b"]>["a"], String([1,2]=="1,2"), String([1,2]==="1,2"))' 'true true true false'
assert object_lt_object                 'console.log({}<{})' 'false'
assert wrapper_number                   'console.log(String(new Number(5)), new Number(5)+1)' '5 6'
assert wrapper_string                   'console.log(String(new String("hi")), new String("hi")+"!")' 'hi hi!'
assert wrapper_boolean                  'console.log(new Boolean(false)+"", String(new Boolean(true)))' 'false true'
assert wrapper_hidden_from_keys         'console.log(Object.keys(new Number(5)).length, JSON.stringify({n:1}))' '0 {"n":1}'
assert wrapper_number_methods           'console.log(new Number(5).toFixed(2), new Number(5).valueOf(), new Number(5).toString())' '5.00 5 5'
assert join_override_honored            'var arr=[1,2];arr.join=function(){return "OVR"};console.log(String(arr))' 'OVR'
assert join_delegates_elements          'console.log([{toString(){return "A"}},2].join("-"))' 'A-2'
assert tolocalestring_array             'console.log([1,2,3].toLocaleString())' '1,2,3'
assert tolocalestring_object            'console.log(String({}.toLocaleString()))' '[object Object]'
assert toprimitive_infinite_throws      'try{var o={};o.valueOf=function(){return ""+o};""+o}catch(e){console.log(e.name)}' 'RangeError'
assert prop_key_uses_tostring           'var k={toString:()=>"kk"};var o={};o[k]=7;console.log(o.kk, Object.keys(o).join(","))' '7 kk'
assert switch_uses_strict               'console.log([1]=="1", [1]==="1")' 'true false'
assert sort_default_tostring            'console.log([10,9,1].sort().join(","))' '1,10,9'
assert concat_bigint_object             'console.log(String(1n+{valueOf:()=>2n}))' '3'
assert in_operator_key                  'console.log("1" in [7,8])' 'true'

# a gate that asserted nothing would be worthless: prove we actually ran cases
if [ "$ran" -lt 82 ]; then
    echo "[js-toprim] FAIL: only $ran assertions ran (expected >= 82)"; exit 1
fi
echo "[js-toprim] $ran assertions executed"

if [ "$fail" -eq 0 ]; then
    echo "[js-toprim] ALL PASS"
else
    echo "[js-toprim] SOME FAILED"
fi
exit "$fail"
