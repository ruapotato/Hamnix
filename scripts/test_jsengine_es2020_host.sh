#!/usr/bin/env bash
# scripts/test_jsengine_es2020_host.sh — FAST, QEMU-free gate for the JS
# engine's ES2015-2021 language + collection features (lib/jsengine.ad) via the
# x86_64-linux host driver (user/js_host.ad).
#
# Modern real-world scripts are minified/transpiled AGAINST these features and
# abort on the first `SyntaxError` if the engine lacks them. This gate exercises
# the batch added in the W3C/ECMAScript conformance campaign (round 1) and
# asserts each result against node semantics with self-contained inline
# assertions (no external oracle file to drift):
#   Language: optional chaining `?.` (member/index/call, short-circuit),
#             nullish coalescing `??`, logical assignment `||= &&= ??=`,
#             exponentiation `** **=` (right-assoc), `for...of`
#             (arrays/strings/Map/Set + destructuring + break/continue).
#   Built-ins: Map/Set (get/set/has/delete/clear/size/forEach/keys/values/
#             entries + iterable ctor), Array.from, findLast/findLastIndex,
#             flatMap, copyWithin, at; Object.create/getPrototypeOf/
#             setPrototypeOf/getOwnPropertyNames/defineProperty/isFrozen (real
#             freeze enforcement)/getOwnPropertyDescriptor; Number.isSafeInteger
#             + MAX_SAFE_INTEGER/EPSILON.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-es2020] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_es2020_compile.log"; then
    echo "[js-es2020] FAIL: host driver did not compile"; cat "$OUT/js_es2020_compile.log"; exit 1
fi
echo "[js-es2020] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs-ONE-line> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_es2020_case.js"
    local got
    got="$("$BIN" "$OUT/js_es2020_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-es2020] PASS $name"
    else
        echo "[js-es2020] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- optional chaining ----
assert oc_member    'var a={b:{c:42}};console.log(a?.b?.c, a?.x?.y)'                              '42 undefined'
assert oc_index     'var a={b:{c:7}};console.log(a?.["b"]?.["c"], a?.["z"]?.["q"])'              '7 undefined'
assert oc_call      'var o={f:function(){return 9}};console.log(o.f?.(), o.g?.())'                '9 undefined'
assert oc_nullbase  'var n=null;console.log(n?.foo, n?.foo(), n?.foo.bar.baz)'                    'undefined undefined undefined'
assert oc_shortcirc 'var c=0;var o=null;var r=o?.f(c=1);console.log(r, c)'                        'undefined 0'
assert oc_nullish   'var a={};console.log(a?.x?.y ?? "def")'                                      'def'

# ---- nullish coalescing ----
assert nc_zero      'console.log(0 ?? 5, null ?? 5, undefined ?? "x", "" ?? "y")'                 '0 5 x '
assert nc_false     'console.log(false ?? 1, NaN ?? 1)'                                           'false NaN'

# ---- logical assignment ----
assert la_or        'var p=0;p||=9;var q=3;q||=9;console.log(p,q)'                                '9 3'
assert la_and       'var r=1;r&&=8;var s=0;s&&=8;console.log(r,s)'                                '8 0'
assert la_nullish   'var t;t??=4;var u=2;u??=4;console.log(t,u)'                                  '4 2'
assert la_noeval    'var o={n:5};var hit=0;function f(){hit=1;return 9}o.n||=f();console.log(o.n,hit)' '5 0'

# ---- exponentiation ----
assert exp_basic    'console.log(2**10, 5**0, 2**-1)'                                             '1024 1 0.5'
assert exp_rassoc   'console.log(2**3**2)'                                                        '512'
assert exp_unary    'console.log(-(2**2))'                                                        '-4'
assert exp_assign   'var e=3;e**=2;console.log(e)'                                                '9'
assert exp_prec     'console.log(2*3**2, 3**2*2)'                                                 '18 18'

# ---- for...of ----
assert fo_array     'var s=0;for(const x of [1,2,3,4])s+=x;console.log(s)'                        '10'
assert fo_string    'var r="";for(const c of "abc")r+=c+".";console.log(r)'                       'a.b.c.'
assert fo_destr     'var r="";for(const [k,v] of [[1,"a"],[2,"b"]])r+=k+v;console.log(r)'         '1a2b'
assert fo_break     'var r="";for(const x of [1,2,3,4,5]){if(x===2)continue;if(x===4)break;r+=x}console.log(r)' '13'
assert fo_entriesA  'var r="";for(const [i,v] of ["x","y"].entries())r+=i+v;console.log(r)'       '0x1y'

# ---- Map ----
assert map_basic    'var m=new Map();m.set("a",1).set("b",2);console.log(m.get("a"),m.get("b"),m.size)' '1 2 2'
assert map_has_del  'var m=new Map([["a",1]]);console.log(m.has("a"),m.delete("a"),m.has("a"),m.size)'  'true true false 0'
assert map_ctor     'var m=new Map([["x",9],["y",8]]);console.log(m.get("x")+m.get("y"))'         '17'
assert map_iter     'var m=new Map([["a",1],["b",2]]);var r="";for(const [k,v] of m)r+=k+v;console.log(r)' 'a1b2'
assert map_foreach  'var m=new Map([["a",1],["b",2]]);var r="";m.forEach((v,k)=>r+=k+v);console.log(r)'  'a1b2'
assert map_keys     'var m=new Map([["a",1],["b",2]]);console.log([...m.keys()].join(",")+"|"+[...m.values()].join(","))' 'a,b|1,2'
assert map_overwrite 'var m=new Map();m.set("k",1);m.set("k",2);console.log(m.get("k"),m.size)'   '2 1'
assert map_numkey   'var m=new Map();m.set(1,"a");m.set(NaN,"n");console.log(m.get(1),m.get(NaN))' 'a n'

# ---- Set ----
assert set_dedup    'var s=new Set([1,2,2,3,3,3]);console.log(s.size)'                            '3'
assert set_has_add  'var s=new Set([1,2]);s.add(3).add(3);console.log(s.has(2),s.has(9),s.size)'  'true false 3'
assert set_iter     'var s=new Set([1,2,3]);var a=0;for(const v of s)a+=v;console.log(a)'         '6'
assert set_from     'console.log(Array.from(new Set([3,1,2,1])).join("-"))'                       '3-1-2'
assert set_delete   'var s=new Set([1,2,3]);console.log(s.delete(2),s.has(2),s.size)'             'true false 2'

# ---- Array new methods ----
assert arr_findlast 'console.log([1,2,3,4].findLast(x=>x%2===1),[1,2,3,4].findLastIndex(x=>x%2===1))' '3 2'
assert arr_flatmap  'console.log([1,2,3].flatMap(x=>[x,x*10]).join(","))'                         '1,10,2,20,3,30'
assert arr_copyw    'console.log([1,2,3,4,5].copyWithin(0,3).join(","))'                          '4,5,3,4,5'
assert arr_at       'console.log([10,20,30].at(-1),[10,20,30].at(0),[10,20,30].at(9))'            '30 10 undefined'
assert arr_from_map 'console.log(Array.from([1,2,3],x=>x*2).join(","))'                           '2,4,6'
assert arr_from_str 'console.log(Array.from("hi").join("-"))'                                     'h-i'
assert arr_from_lk  'console.log(Array.from({length:3},(_,i)=>i).join(","))'                      '0,1,2'

# ---- Object new methods ----
assert obj_create   'var p={g:function(){return "hi"}};var o=Object.create(p);console.log(o.g(),Object.getPrototypeOf(o)===p)' 'hi true'
assert obj_freeze   'var f=Object.freeze({a:1});f.a=99;f.b=2;console.log(f.a,f.b,Object.isFrozen(f))' '1 undefined true'
assert obj_defprop  'var o={};Object.defineProperty(o,"x",{value:42});console.log(o.x)'           '42'
assert obj_getdesc  'console.log(JSON.stringify(Object.getOwnPropertyDescriptor({a:5},"a")))'     '{"value":5,"writable":true,"enumerable":true,"configurable":true}'
assert obj_getnames 'console.log(Object.getOwnPropertyNames({a:1,b:2}).join(","))'                'a,b'
assert obj_setproto 'var p={g:9};var o={};Object.setPrototypeOf(o,p);console.log(o.g)'            '9'

# ---- destructuring parameters (function + arrow) ----
assert dp_fn_arr    'function f([a,b]){return a+b}console.log(f([3,4]))'                           '7'
assert dp_fn_obj    'function g({x,y}){return x*y}console.log(g({x:5,y:6}))'                       '30'
assert dp_arrow     'var h=([a,b])=>a-b;console.log(h([9,2]))'                                     '7'
assert dp_map       'console.log([["a",1],["b",2]].map(([k,v])=>k+v).join(","))'                  'a1,b2'
assert dp_nested    'function f({a:{b}}){return b}console.log(f({a:{b:42}}))'                      '42'
assert dp_default   'function f([a,b=9]){return a+b}console.log(f([1]))'                           '10'

# ---- Number statics ----
assert num_safeint  'console.log(Number.isSafeInteger(42),Number.isSafeInteger(2**53))'          'true false'
assert num_maxsafe  'console.log(Number.MAX_SAFE_INTEGER)'                                        '9007199254740991'
assert num_epsilon  'console.log(Number.EPSILON>0,Number.MIN_SAFE_INTEGER)'                       'true -9007199254740991'

if [ "$fail" -eq 0 ]; then
    echo "[js-es2020] RESULT: PASS"
    exit 0
else
    echo "[js-es2020] RESULT: FAIL"
    exit 1
fi
