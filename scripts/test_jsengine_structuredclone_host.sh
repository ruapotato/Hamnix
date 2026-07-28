#!/usr/bin/env bash
# scripts/test_jsengine_structuredclone_host.sh — FAST, QEMU-free gate for the
# structuredClone() global in the native JS engine (lib/web/js/*), via the
# x86_64-linux host driver.
#
# Covered (round 7): deep clone of plain objects, arrays, Map, Set, Date,
# ArrayBuffer, and typed arrays; shared-reference and cycle preservation via a
# visited map; non-cloneable values (functions/symbols) throw a DataCloneError.
#
# Limits (documented): only own DATA properties are cloned (accessor properties
# are skipped); recursion is depth-capped defensively; transfer lists are not
# supported.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-sc] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_sc_compile.log"; then
    echo "[js-sc] FAIL: host driver did not compile"; cat "$OUT/js_sc_compile.log"; exit 1
fi
echo "[js-sc] PASS host driver compiled -> $BIN"

fail=0
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_sc_case.js"
    local got
    got="$("$BIN" "$OUT/js_sc_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-sc] PASS $name"
    else
        echo "[js-sc] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- deep independence ----
assert sc_deep      'var o={a:1,b:{c:2,d:[3,4]}};var c=structuredClone(o);c.b.c=99;c.b.d[0]=88;console.log(o.b.c,o.b.d[0],c.b.c,c.b.d[0])' '2 3 99 88'
assert sc_json      'var c=structuredClone({a:1,b:{c:2,d:[3,4]}});console.log(JSON.stringify(c))'      '{"a":1,"b":{"c":2,"d":[3,4]}}'
assert sc_prim      'console.log(structuredClone(5),structuredClone("hi"),structuredClone(true),structuredClone(null))' '5 hi true null'
assert sc_array     'var a=[1,[2,3],4];var c=structuredClone(a);c[1][0]=99;console.log(a[1][0],c[1][0])' '2 99'

# ---- shared references + cycles ----
assert sc_shared    'var sh={x:1};var s={p:sh,q:sh};var c=structuredClone(s);console.log(c.p===c.q,c.p!==sh)' 'true true'
assert sc_cycle     'var y={};y.self=y;var c=structuredClone(y);console.log(c.self===c,c!==y)'         'true true'

# ---- Map / Set / Date ----
assert sc_map       'var m=new Map([["a",1],["b",2]]);var c=structuredClone(m);c.set("a",100);console.log(m.get("a"),c.get("a"),c.get("b"),c.size)' '1 100 2 2'
assert sc_set       'var s=new Set([1,2,3]);var c=structuredClone(s);c.add(4);console.log(s.has(4),c.has(4),c.size)' 'false true 4'
assert sc_date      'var d=new Date(1234567);var c=structuredClone(d);console.log(c.getTime(),c!==d)'  '1234567 true'

# ---- ArrayBuffer / typed arrays ----
assert sc_typed     'var t=new Int32Array([5,6,7]);var c=structuredClone(t);c[0]=50;console.log(t[0],c[0],c.length)' '5 50 3'
assert sc_buffer    'var b=new ArrayBuffer(4);var v=new Uint8Array(b);v[0]=9;var c=structuredClone(b);var cv=new Uint8Array(c);console.log(cv[0],c.byteLength)' '9 4'

# ---- non-cloneable ----
assert sc_fn_throw  'try{structuredClone(function(){})}catch(e){console.log(e.name)}'                  'DataCloneError'
assert sc_nested_fn 'try{structuredClone({a:1,f:function(){}})}catch(e){console.log(e.name)}'          'DataCloneError'

if [ "$fail" -eq 0 ]; then
    echo "[js-sc] ALL PASS"
else
    echo "[js-sc] SOME FAILED"
fi
exit "$fail"
