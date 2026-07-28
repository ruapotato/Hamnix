#!/usr/bin/env bash
# scripts/test_jsengine_destructure_host.sh — FAST, QEMU-free gate for the JS
# engine's destructuring-ASSIGNMENT support + the browser `window`-shaped
# globals (lib/web/js/*), via the x86_64-linux host driver (user/js_host.ad).
# Self-contained inline assertions against node semantics (no oracle file).
#
# Regression fixed here: destructuring as an ASSIGNMENT statement — `[a,b]=[b,a]`,
# `[x,,y]=arr`, `[a,...rest]=arr`, `({p,q}=obj)`, nested patterns and element
# defaults — previously did nothing (assign_to ignored an array/object *literal*
# LHS; only the let/const/var DECLARATION path handled patterns). The RHS is now
# fully evaluated BEFORE any store, so `[a,b]=[b,a]` swaps. Declaration
# destructuring (the pre-existing path) must keep working — asserted below.
#
# Also covers: window.innerWidth/innerHeight, window.scrollX/Y + pageXOffset,
# window.location.{href,protocol,pathname}, window.screen, window===globalThis.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-destr] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_destr_compile.log"; then
    echo "[js-destr] FAIL: host driver did not compile"; cat "$OUT/js_destr_compile.log"; exit 1
fi
echo "[js-destr] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-that-console.logs-ONE-line> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_destr_case.js"
    local got
    got="$("$BIN" "$OUT/js_destr_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-destr] PASS $name"
    else
        echo "[js-destr] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- array destructuring ASSIGNMENT (the fixed bug) ----
assert da_swap      'var a=1,b=2;[a,b]=[b,a];console.log(a,b)'                                   '2 1'
assert da_basic     'var a,b;[a,b]=[10,20];console.log(a,b)'                                     '10 20'
assert da_skip      'var x,y;[x,,y]=[10,20,30];console.log(x,y)'                                 '10 30'
assert da_skip2     'var a,b;[,a,,b]=[1,2,3,4];console.log(a,b)'                                 '2 4'
assert da_rest      'var f,r;[f,...r]=[1,2,3,4];console.log(f,r.join(","))'                      '1 2,3,4'
assert da_restskip  'var f,r;[f,,...r]=[1,2,3,4];console.log(f,r.join(","))'                     '1 3,4'
assert da_default   'var m,n;[m=5,n=6]=[100];console.log(m,n)'                                   '100 6'
assert da_defskip   'var m,n;[m=5,n=6]=[undefined,7];console.log(m,n)'                           '5 7'
assert da_extra     'var a,b;[a,b]=[9];console.log(a,b)'                                         '9 undefined'
assert da_member    'var o={};[o.x,o.y]=[3,4];console.log(o.x,o.y)'                              '3 4'
assert da_index     'var a=[0,0,0];[a[0],a[2]]=[7,8];console.log(a.join(","))'                   '7,0,8'
assert da_string    'var a,b;[a,b]="hi";console.log(a,b)'                                        'h i'
assert da_nestarr   'var p,q,r;[p,[q,r]]=[1,[2,3]];console.log(p,q,r)'                           '1 2 3'
assert da_returnval 'var a,b;console.log(([a,b]=[5,6]).length)'                                  '2'

# ---- object destructuring ASSIGNMENT (requires the parenthesized form) ----
assert do_basic     'var p,q;({p,q}={p:7,q:9});console.log(p,q)'                                 '7 9'
assert do_rename    'var nm,ct;({name:nm,city:ct}={name:"Rex",city:"NY"});console.log(nm,ct)'    'Rex NY'
assert do_default   'var nm,missing;({name:nm,missing="def"}={name:"Rex"});console.log(nm,missing)' 'Rex def'
assert do_defskip   'var v;({v=5}={v:9});console.log(v)'                                         '9'
assert do_rest      'var a,o;({a,...o}={a:1,b:2,c:3});console.log(a,JSON.stringify(o))'          '1 {"b":2,"c":3}'
assert do_member    'var t={};({x:t.k}={x:42});console.log(t.k)'                                 '42'
assert do_nested    'var id,t0,t1;({user:{id,tags:[t0,t1]}}={user:{id:42,tags:["x","y"]}});console.log(id,t0,t1)' '42 x y'
assert do_computed  'var k="p",v;({[k]:v}={p:11});console.log(v)'                                '11'

# ---- DECLARATION destructuring must STILL work (no regression) ----
assert dd_arr       'var [a,b]=[1,2];console.log(a,b)'                                           '1 2'
assert dd_skip      'var [,x,,y]=[1,2,3,4];console.log(x,y)'                                     '2 4'
assert dd_rest      'var [h,...t]=[1,2,3];console.log(h,t.join(","))'                            '1 2,3'
assert dd_default   'var [a=1,b=99]=[5];console.log(a,b)'                                        '5 99'
assert dd_obj       'var {name,age}={name:"Rex",age:3};console.log(name,age)'                    'Rex 3'
assert dd_objrest   'var {a,...o}={a:1,b:2,c:3};console.log(a,JSON.stringify(o))'                '1 {"b":2,"c":3}'
assert dd_nested    'var {u:{id,tags:[t0]}}={u:{id:7,tags:["z"]}};console.log(id,t0)'            '7 z'
assert dd_let       'let [a,b]=[3,4];console.log(a,b)'                                           '3 4'
assert dd_const     'const {x}={x:8};console.log(x)'                                             '8'

# ---- sparse array LITERAL as a value: a hole reads as undefined, keeps length ----
assert lit_hole     'var a=[1,,3];console.log(a.length,a[1])'                                    '3 undefined'

# ---- window-shaped globals (bare + window.-prefixed both resolve) ----
assert win_alias    'console.log(typeof window,window===globalThis,window===self)'              'object true true'
assert win_size     'console.log(window.innerWidth,window.innerHeight,innerWidth)'              '1024 768 1024'
assert win_scroll   'console.log(window.scrollX,window.scrollY,window.pageYOffset)'             '0 0 0'
assert win_dpr      'console.log(window.devicePixelRatio)'                                       '1'
assert win_loc      'console.log(window.location.href,window.location.protocol)'                'about:blank about:'
assert win_locbare  'console.log(location.pathname,typeof location.search)'                     'blank string'
assert win_screen   'console.log(window.screen.width,screen.height,screen.colorDepth)'          '1024 768 24'
assert win_write    'window.appDefined=42;console.log(appDefined)'                               '42'

if [ "$fail" -eq 0 ]; then
    echo "[js-destr] RESULT: PASS"
    exit 0
else
    echo "[js-destr] RESULT: FAIL"
    exit 1
fi
