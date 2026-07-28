#!/usr/bin/env bash
# scripts/test_jsengine_reflect_host.sh — FAST, QEMU-free gate for the ES2015
# Reflect namespace in the native JS engine (lib/web/js/*), via the x86_64-linux
# host driver (user/js_host.ad). Inline assertions against node semantics.
#
# Covered (round 7): Reflect.{get,set,has,ownKeys,getPrototypeOf,setPrototypeOf,
#   defineProperty,deleteProperty,apply,construct}. These are thin wrappers over
#   the engine's existing object operations (member_get/member_set/op_in/
#   obj_del_prop/object_keys/object_define_property/invoke/run_constructor).
#
# Limits: Reflect.get/set ignore the optional `receiver` argument (no accessor
#   re-binding); Reflect.construct ignores `newTarget`; ownKeys returns own
#   string keys (the engine does not distinguish enumerable/non-enumerable or
#   surface symbol keys separately).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-reflect] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_reflect_compile.log"; then
    echo "[js-reflect] FAIL: host driver did not compile"; cat "$OUT/js_reflect_compile.log"; exit 1
fi
echo "[js-reflect] PASS host driver compiled -> $BIN"

fail=0
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_reflect_case.js"
    local got
    got="$("$BIN" "$OUT/js_reflect_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-reflect] PASS $name"
    else
        echo "[js-reflect] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- get / set / has ----
assert refl_get      'var o={a:1,b:2};console.log(Reflect.get(o,"a"),Reflect.get(o,"b"))'          '1 2'
assert refl_get_miss 'console.log(Reflect.get({a:1},"z"))'                                          'undefined'
assert refl_get_arr  'console.log(Reflect.get([10,20,30],1))'                                       '20'
assert refl_set      'var o={};console.log(Reflect.set(o,"x",5),o.x)'                               'true 5'
assert refl_set_chain 'var o={};Reflect.set(o,"a",1);Reflect.set(o,"b",2);console.log(o.a+o.b)'    '3'
assert refl_has      'var o={a:1};console.log(Reflect.has(o,"a"),Reflect.has(o,"b"))'              'true false'
assert refl_has_proto 'var o=Object.create({inherited:1});console.log(Reflect.has(o,"inherited"))' 'true'

# ---- ownKeys ----
assert refl_ownkeys  'console.log(Reflect.ownKeys({a:1,b:2,c:3}).join(","))'                        'a,b,c'
assert refl_ownkeys_arr 'console.log(Reflect.ownKeys([9,8]).join(","))'                             '0,1'

# ---- getPrototypeOf / setPrototypeOf ----
assert refl_getproto 'var p={};var o=Object.create(p);console.log(Reflect.getPrototypeOf(o)===p)'   'true'
assert refl_setproto 'var p={greet(){return "hi"}};var o={};Reflect.setPrototypeOf(o,p);console.log(o.greet())' 'hi'
assert refl_setproto_ret 'var o={};console.log(Reflect.setPrototypeOf(o,{}))'                       'true'

# ---- defineProperty / deleteProperty ----
assert refl_defprop  'var o={};Reflect.defineProperty(o,"x",{value:42});console.log(o.x)'           '42'
assert refl_defprop_ret 'var o={};console.log(Reflect.defineProperty(o,"y",{value:1}))'             'true'
assert refl_delprop  'var o={a:1,b:2};console.log(Reflect.deleteProperty(o,"a"),o.a,o.b)'           'true undefined 2'

# ---- apply ----
assert refl_apply    'function add(a,b){return a+b}console.log(Reflect.apply(add,null,[4,5]))'      '9'
assert refl_apply_this 'var o={n:10};function f(){return this.n}console.log(Reflect.apply(f,o,[]))' '10'
assert refl_apply_spread 'console.log(Reflect.apply(Math.max,null,[3,9,2,7]))'                      '9'

# ---- construct ----
assert refl_construct 'class P{constructor(x,y){this.x=x;this.y=y}sum(){return this.x+this.y}}var p=Reflect.construct(P,[3,7]);console.log(p.x,p.y,p.sum())' '3 7 10'
assert refl_construct_inst 'class A{}var a=Reflect.construct(A,[]);console.log(a instanceof A)'     'true'
assert refl_construct_fields 'class C{v=5;constructor(n){this.n=n}}var c=Reflect.construct(C,[9]);console.log(c.v,c.n)' '5 9'

if [ "$fail" -eq 0 ]; then
    echo "[js-reflect] ALL PASS"
else
    echo "[js-reflect] SOME FAILED"
fi
exit "$fail"
