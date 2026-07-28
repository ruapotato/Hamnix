#!/usr/bin/env bash
# scripts/test_jsengine_generators_host.sh — FAST, QEMU-free gate for generators
# (function*/yield/yield*) and the ES iteration protocol in the native JS engine
# (lib/web/js/*), via the x86_64-linux host driver (user/js_host.ad). Inline
# assertions against node semantics (no external oracle file to drift).
#
# EVALUATION MODEL (documented limitation): the engine is a tree-walking
# interpreter and cannot reify a resumable C-stack, so generators use a BOUNDED
# EAGER model — calling a generator runs its whole body ONCE, materializing every
# yielded value into a buffer that .next() then REPLAYS. Consequences:
#   * finite generators, yield-in-loops, yield* delegation, early return()/return
#     statement, and for-of / spread / Array.from / destructuring over them are
#     all observationally correct.
#   * side effects in the body run at CALL time (not lazily per .next()).
#   * two-way .next(v) communication is NOT supported (yield evaluates to
#     undefined).
#   * an unbounded generator is capped at GEN_YIELD_CAP (10000) yields.
# The generic iteration protocol ([Symbol.iterator] / user .next()) IS driven
# lazily for for-of, so early `break` and unbounded user iterators are fine.
#
# Covered:
#   function* declaration + expression; yield / yield* (delegating to arrays,
#   strings, Sets, and other generators); generator object .next()/.return()/
#   .throw()/[Symbol.iterator](); for-of over a generator and over any object
#   implementing the iteration protocol; spread [...gen]; Array.from(gen[,map]);
#   array destructuring from a generator; new Set(gen) / new Map(gen).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-gen] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_gen_compile.log"; then
    echo "[js-gen] FAIL: host driver did not compile"; cat "$OUT/js_gen_compile.log"; exit 1
fi
echo "[js-gen] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs-ONE-line> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_gen_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/js_gen_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-gen] PASS $name"
    else
        echo "[js-gen] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- function* declaration + basic yield, driven by for-of ----
assert gen_decl_forof   'function* g(){yield 1;yield 2;yield 3}var r=[];for(const x of g())r.push(x);console.log(r.join(","))' '1,2,3'
assert gen_expr         'var g=function*(){yield 10;yield 20};console.log([...g()].join(","))' '10,20'
assert gen_typeof       'function* g(){yield 1}console.log(typeof g, typeof g())' 'function object'
assert gen_empty        'function* g(){}console.log([...g()].length)' '0'
assert gen_yield_loop   'function* g(){for(let i=0;i<4;i++)yield i*i}console.log([...g()].join(","))' '0,1,4,9'

# ---- spread and Array.from over a generator ----
assert gen_spread       'function* g(){yield 1;yield 2}console.log([...g()].join(","))' '1,2'
assert gen_spread_mix   'function* g(){yield "a";yield "b"}console.log([...g(),...g()].join(","))' 'a,b,a,b'
assert gen_arrayfrom    'function* g(){yield 1;yield 2}console.log(Array.from(g()).join(","))' '1,2'
assert gen_arrayfrom_map 'function* g(){yield 1;yield 2}console.log(Array.from(g(),x=>x*10).join(","))' '10,20'

# ---- generator object .next()/.return()/.throw()/[Symbol.iterator]() ----
assert gen_next         'function* g(){yield 1;yield 2}var it=g();console.log(it.next().value,it.next().value,it.next().done)' '1 2 true'
assert gen_next_return  'function* g(){yield 1;return 99}var it=g();console.log(it.next().value,it.next().value,it.next().done)' '1 99 true'
assert gen_next_exhaust 'function* g(){yield 1}var it=g();it.next();var r=it.next();console.log(r.value,r.done)' 'undefined true'
assert gen_self_iter    'function* g(){yield 1;yield 2}var it=g();console.log(it[Symbol.iterator]()===it)' 'true'
assert gen_return_early 'function* g(){yield 1;yield 2;yield 3}var it=g();it.next();console.log(it.return(42).value,it.return().done,it.next().done)' '42 true true'
assert gen_throw        'function* g(){yield 1}var it=g();var c="no";try{it.throw(new Error("boom"))}catch(e){c=e.message}console.log(c)' 'boom'

# ---- return statement short-circuits the body ----
assert gen_return_stmt  'function* g(){yield 1;if(true)return;yield 2}console.log([...g()].join(","))' '1'
assert gen_try_finally  'function* g(){try{yield 1;yield 2}finally{}}console.log([...g()].join(","))' '1,2'

# ---- yield* delegation (generator, array, string, Set) ----
assert yieldstar_gen    'function* inner(){yield 1;yield 2}function* outer(){yield 0;yield* inner();yield 3}console.log([...outer()].join(","))' '0,1,2,3'
assert yieldstar_arr    'function* g(){yield* [1,2,3]}console.log([...g()].join(","))' '1,2,3'
assert yieldstar_str    'function* g(){yield* "ab"}console.log([...g()].join(","))' 'a,b'
assert yieldstar_set    'function* g(){yield* new Set([1,2,2,3])}console.log([...g()].join(","))' '1,2,3'
assert yieldstar_nest   'function* g2(){yield 1;yield 2}function* g(){yield* g2()}console.log([...g()].join(","))' '1,2'

# ---- generic iteration protocol: any object with [Symbol.iterator] / .next ----
assert proto_spread     'var obj={[Symbol.iterator](){let i=0;return{next(){return i<3?{value:i++,done:false}:{value:undefined,done:true}}}}};console.log([...obj].join(","))' '0,1,2'
assert proto_forof      'var obj={[Symbol.iterator](){let i=0;return{next(){return i<3?{value:i++,done:false}:{value:undefined,done:true}}}}};var r=[];for(const x of obj)r.push(x);console.log(r.join(","))' '0,1,2'
assert proto_arrayfrom  'var obj={[Symbol.iterator](){let i=0;return{next(){return i<2?{value:i++,done:false}:{value:0,done:true}}}}};console.log(Array.from(obj).join(","))' '0,1'

# ---- generators feeding call spread, destructuring, Set/Map ctors ----
assert gen_call_spread  'function* g(){yield 5;yield 6}function add(a,b){return a+b}console.log(add(...g()))' '11'
assert gen_destructure   'function* g(){yield 10;yield 20}var [a,b]=g();console.log(a,b)' '10 20'
assert gen_new_set      'function* g(){yield 1;yield 2}var s=new Set(g());console.log(s.has(1),s.has(2),s.size)' 'true true 2'
assert gen_new_map      'function* g(){yield [1,10];yield [2,20]}var m=new Map(g());console.log(m.get(1),m.get(2))' '10 20'

# ---- for-of early break on a lazily driven protocol iterator ----
assert proto_break      'function* g(){yield 1;yield 2;yield 3}var r=[];for(const x of g()){r.push(x);if(x===2)break}console.log(r.join(","))' '1,2'

# ---- bounded infinite generator: eager cap replays the first N correctly ----
assert gen_bounded_fib  'function* fib(){let a=0,b=1;while(true){yield a;let t=a+b;a=b;b=t}}var it=fib();var r=[];for(let i=0;i<8;i++)r.push(it.next().value);console.log(r.join(","))' '0,1,1,2,3,5,8,13'

# ---- generator methods: *name(){} in object literals and class bodies (round 7) ----
assert genmeth_objlit    'var o={*g(){yield 1;yield 2;yield 3}};console.log([...o.g()].join(","))' '1,2,3'
assert genmeth_obj_forof 'var o={*g(){yield 4;yield 5}};var s=0;for(const x of o.g())s+=x;console.log(s)' '9'
assert genmeth_class     'class C{*nums(){yield "a";yield "b"}}console.log([...new C().nums()].join(","))' 'a,b'
assert genmeth_static    'class C{static *ids(){yield 10;yield 20}}console.log([...C.ids()].join(","))' '10,20'
assert genmeth_yieldstar 'class C{*g(){yield* [7,8,9]}}console.log([...new C().g()].join(","))' '7,8,9'
assert genmeth_thisref   'class C{constructor(){this.v=3}*g(){yield this.v;yield this.v*2}}console.log([...new C().g()].join(","))' '3,6'
assert genmeth_nextapi   'var o={*g(){yield 1;yield 2}};var it=o.g();console.log(it.next().value,it.next().value,it.next().done)' '1 2 true'

if [ "$fail" -eq 0 ]; then
    echo "[js-gen] ALL PASS"
else
    echo "[js-gen] SOME FAILED"
fi
exit "$fail"
