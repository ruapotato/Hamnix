#!/usr/bin/env bash
# scripts/test_jsengine_es2022b_host.sh — FAST, QEMU-free gate for the JS engine's
# 2026-07-17 ECMAScript conformance batch (lib/web/js/*) via the x86_64-linux
# host driver (user/js_host.ad). Self-contained inline assertions against node
# semantics (no external oracle file to drift).
#
# Covered this round:
#   Object.hasOwn(obj, key)  — ES2022 static hasOwnProperty (objects, array
#                              indices + length, primitive -> false, key coercion).
#   Object.is(a, b)          — SameValue: NaN===NaN, +0 !== -0, reference identity.
#   Unary minus preserves signed zero: -(+0) === -0 (1/-0 === -Infinity).
#   RegExp `s` (dotAll) flag — `.` also matches U+000A; `.dotAll` reflected;
#                              interacts with g/exec/match/replace.
#   RegExp `y` (sticky) flag — the match must begin exactly at .lastIndex (no
#                              forward scan); `.sticky` reflected; exec/test/
#                              replace/matchAll honour the anchor + advance
#                              .lastIndex.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-es2022b] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_es2022b_compile.log"; then
    echo "[js-es2022b] FAIL: host driver did not compile"; cat "$OUT/js_es2022b_compile.log"; exit 1
fi
echo "[js-es2022b] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs-ONE-line> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_es2022b_case.js"
    local got
    got="$("$BIN" "$OUT/js_es2022b_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-es2022b] PASS $name"
    else
        echo "[js-es2022b] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- Object.hasOwn ----
assert hasown_obj    'console.log(Object.hasOwn({a:1},"a"),Object.hasOwn({a:1},"b"))'                    'true false'
assert hasown_arr    'console.log(Object.hasOwn([1,2],0),Object.hasOwn([1,2],5),Object.hasOwn([1,2],"length"))' 'true false true'
assert hasown_prim   'console.log(Object.hasOwn("hi","x"),Object.hasOwn(5,"x"))'                          'false false'
assert hasown_coerce 'var o={};o[2]=9;console.log(Object.hasOwn(o,2),Object.hasOwn(o,"2"))'              'true true'
assert hasown_inherit 'function A(){}A.prototype.p=1;var a=new A();console.log(Object.hasOwn(a,"p"))'    'false'
assert hasown_undef  'var o={x:undefined};console.log(Object.hasOwn(o,"x"))'                             'true'

# ---- Object.is ----
assert is_basic      'console.log(Object.is(1,1),Object.is("a","a"),Object.is(1,2))'                     'true true false'
assert is_nan        'console.log(Object.is(NaN,NaN),NaN===NaN)'                                          'true false'
assert is_zero       'console.log(Object.is(0,-0),Object.is(-0,-0),Object.is(0,0))'                      'false true true'
assert is_ref        'var o={};console.log(Object.is(o,o),Object.is({},{}))'                             'true false'
assert is_types      'console.log(Object.is(null,null),Object.is(undefined,undefined),Object.is(null,undefined))' 'true true false'
assert is_mixed      'console.log(Object.is(1,"1"),Object.is(true,1))'                                    'false false'

# ---- unary minus preserves signed zero ----
assert negzero_div   'console.log(1/-0)'                                                                  '-Infinity'
assert negzero_pos   'console.log(1/0)'                                                                   'Infinity'
assert negzero_str   'console.log(String(-0),String(0))'                                                  '0 0'
assert neg_normal    'console.log(-5, -(3-1))'                                                            '-5 -2'

# ---- RegExp `s` dotAll flag ----
assert dotall_nl     'console.log(/a.b/s.test("a\nb"),/a.b/.test("a\nb"))'                                'true false'
assert dotall_prop   'console.log(/x/s.dotAll,/x/.dotAll,/x/gim.dotAll)'                                  'true false false'
assert dotall_flags  'console.log(/x/gs.flags)'                                                           'gs'
assert dotall_still  'console.log(/a.b/s.test("aXb"))'                                                    'true'
assert dotall_match  'console.log("x\ny".match(/x.y/s)[0].length)'                                        '3'
assert dotall_repl   'console.log("a\nb".replace(/./gs,"-"))'                                             '---'
assert dotall_repl_no 'console.log("a\nb".replace(/./g,"-").length)'                                      '3'
assert dotall_ctor   'console.log(new RegExp("a.b","s").test("a\nb"))'                                    'true'

# ---- RegExp `y` sticky flag ----
assert sticky_prop   'console.log(/x/y.sticky,/x/.sticky,/x/gy.flags)'                                    'true false gy'
assert sticky_anchor 'var r=/a/y;r.lastIndex=1;console.log(r.test("ba"),r.lastIndex)'                    'true 2'
assert sticky_noscan 'var r=/a/y;console.log(r.test("ba"),r.lastIndex)'                                  'false 0'
assert sticky_exec   'var r=/\d/y;r.lastIndex=2;console.log(r.exec("ab3")[0])'                            '3'
assert sticky_execno 'var r=/\d/y;r.lastIndex=0;console.log(r.exec("ab3"))'                              'null'
assert sticky_seq    'var r=/\w/y;var s="",m;while(m=r.exec("abc"))s+=m[0];console.log(s,r.lastIndex)'    'abc 0'
assert sticky_tokens 'var r=/\d+|\+/y;var s="12+3",out=[],m;while(m=r.exec(s)){out.push(m[0]);}console.log(out.join(" "))' '12 + 3'
assert sticky_gap    'var r=/\d/y;var out=[],m;while(m=r.exec("1a2"))out.push(m[0]);console.log(out.join(","))' '1'
assert sticky_matchall 'var out=[];for(const m of "aXbXc".matchAll(/[a-c]/gy))out.push(m[0]);console.log(out.join(""))' 'a'
assert sticky_replace 'console.log("aaa".replace(/a/gy,"b"))'                                             'bbb'

# ---- combined: named groups + dotAll still resolve .groups ----
assert combo_named   'var m=/(?<x>.)(?<y>.)/s.exec("a\nb");console.log(m.groups.x==="a",m.groups.y==="\n")' 'true true'

if [ "$fail" -eq 0 ]; then
    echo "[js-es2022b] RESULT: PASS"
    exit 0
else
    echo "[js-es2022b] RESULT: FAIL"
    exit 1
fi
