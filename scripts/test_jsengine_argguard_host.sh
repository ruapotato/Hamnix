#!/usr/bin/env bash
# scripts/test_jsengine_argguard_host.sh — FAST, QEMU-free gate making the
# "a throwing ARGUMENT must not reach a mutating built-in" invariant STRUCTURAL:
# a SOURCE lint over every eval_args_into() call site in lib/web/js, plus the
# runtime cases that prove the lint is guarding something real.
#
# WHY A LINT AND NOT A HOIST
# The engine has ~47 eval_args_into() call sites: eval_call and the seven
# builtin-method dispatcher families (string/number/bigint/array/regex/
# function/object/symbol) each evaluate their own arguments and then check
#     if ctl == CTL_THROW or err_flag != 0:
# before acting. That is a per-site guard repeated 47 times, so a NEW builtin
# added without the check silently reintroduces the `a.push(thrower())` class of
# bug (see scripts/test_jsengine_unwind_host.sh item 6).
#
# The obvious cleanup — hoist argument evaluation into eval_call the way
# try_regex_method's caller does — was EVALUATED AND REJECTED, because it is not
# equivalence-preserving. The dispatchers run BEFORE member_get, and a
# dispatcher that does not recognise the method name returns -2 WITHOUT
# evaluating arguments, after which eval_call falls through to member_get (which
# may run a user GETTER) and only then evaluates the arguments. Hoisting would
# move argument evaluation in front of that getter. node's order is observable:
#
#   Object.defineProperty(Array.prototype,'yyy',{get(){log.push("getter");
#       return function(){return "ok"}}});
#   [1].yyy(g());        // node: "getter,arg"   (this engine: "getter,arg")
#
# Hoisting makes it "arg,getter" — a spec-order regression reachable from
# ordinary JS. So the per-site guards STAY, and this gate makes forgetting one
# a build failure instead of a silent wrong answer.
#
# TWO PARTS
#   PART A (lint): every eval_args_into() call site in lib/web/js must be
#     followed within 3 lines by a CTL_THROW / err_flag check. This is the
#     structural property; it fails loudly when a new builtin omits it.
#   PART B (runtime): the shared choke point still does its half — a throwing
#     argument makes eval_args_into report ZERO args and rewind call_top, so
#     even an unguarded site cannot act on the `undefined` placeholders.
#     Expectations are node v20's stdout.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

fail=0

# ---- PART A: the source lint ------------------------------------------------
echo "[js-argguard] linting eval_args_into() call sites ..."
lint_out="$(python3 - <<'PY'
import glob, os, sys
files = sorted(glob.glob('lib/web/js/*.ad') + glob.glob('lib/web/js/builtins/*.ad'))
total = 0
bad = []
for f in files:
    L = open(f).read().split('\n')
    for i, line in enumerate(L):
        if 'eval_args_into(' not in line:
            continue
        if line.lstrip().startswith('#') or line.lstrip().startswith('def '):
            continue
        total += 1
        ctx = '\n'.join(L[i + 1:i + 4])
        if 'CTL_THROW' not in ctx and 'err_flag' not in ctx:
            bad.append((f, i + 1, line.strip()))
print("SITES %d" % total)
for f, n, l in bad:
    print("UNGUARDED %s:%d  %s" % (f, n, l))
PY
)"
sites="$(echo "$lint_out" | sed -n 's/^SITES //p')"
unguarded="$(echo "$lint_out" | grep -c '^UNGUARDED ' || true)"
echo "[js-argguard] $sites eval_args_into() call sites found, $unguarded unguarded"
if [ "${sites:-0}" -lt 40 ]; then
    echo "[js-argguard] FAIL: only ${sites:-0} call sites seen — the lint stopped finding them (moved/renamed?)"
    fail=1
fi
if [ "$unguarded" -ne 0 ]; then
    echo "$lint_out" | grep '^UNGUARDED '
    echo "[js-argguard] FAIL: an eval_args_into() call site has no CTL_THROW/err_flag guard"
    echo "[js-argguard]       add    if ctl == CTL_THROW or err_flag != 0: <bail>    right after it"
    fail=1
else
    echo "[js-argguard] PASS every eval_args_into() call site is guarded"
fi

# ---- PART B: the shared choke point, at runtime ------------------------------
echo "[js-argguard] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_argguard_compile.log"; then
    echo "[js-argguard] FAIL: host driver did not compile"
    cat "$OUT/js_argguard_compile.log"; exit 1
fi

ran=0
assert() {
    local name="$1" js="$2" exp="$3"
    ran=$((ran + 1))
    printf '%s\n' "$js" > "$OUT/js_argguard_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/js_argguard_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-argguard] PASS $name"
    else
        echo "[js-argguard] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

T='function t(){throw "T"}'
# a throwing argument must leave every mutating builtin family untouched
assert arr_push       "$T;var a=[1];try{a.push(t())}catch(e){}console.log(a.length,a.join('|'))" '1 1'
assert arr_unshift    "$T;var a=[1];try{a.unshift(t())}catch(e){}console.log(a.join('|'))"       '1'
assert arr_splice     "$T;var a=[1,2,3];try{a.splice(t(),1)}catch(e){}console.log(a.join(','))"  '1,2,3'
assert arr_fill       "$T;var a=[1,2,3];try{a.fill(t())}catch(e){}console.log(a.join(','))"      '1,2,3'
assert arr_copywithin "$T;var a=[1,2,3];try{a.copyWithin(t(),1)}catch(e){}console.log(a.join(','))" '1,2,3'
assert str_concat     "$T;var s='a';try{s=s.concat(t())}catch(e){}console.log(s)"                'a'
assert str_replace    "$T;var s='abc';try{s=s.replace('a',t())}catch(e){}console.log(s)"         'abc'
assert str_padstart   "$T;var s='ab';try{s=s.padStart(t())}catch(e){}console.log(s)"             'ab'
assert map_set        "$T;var m=new Map();try{m.set(t(),1)}catch(e){}console.log(m.size)"        '0'
assert set_add        "$T;var s=new Set();try{s.add(t())}catch(e){}console.log(s.size)"          '0'
assert num_tofixed    "$T;var n=1.5;var o='keep';try{o=n.toFixed(t())}catch(e){}console.log(o)"  'keep'
assert regex_test     "$T;var r=/a/;var o='keep';try{o=r.test(t())}catch(e){}console.log(o)"     'keep'
assert fn_call        "$T;function f(){return 'ran'}var o='keep';try{o=f.call(t())}catch(e){}console.log(o)" 'keep'
assert fn_apply       "$T;function f(){return 'ran'}var o='keep';try{o=f.apply(t())}catch(e){}console.log(o)" 'keep'
assert fn_bind        "$T;function f(){return 'ran'}var o='keep';try{o=f.bind(t())}catch(e){}console.log(o)" 'keep'
assert obj_hasown     "$T;var o={};var r='keep';try{r=o.hasOwnProperty(t())}catch(e){}console.log(r)" 'keep'
assert user_fn        "$T;var log=[];function f(x){log.push('called')}try{f(t())}catch(e){}console.log(log.length)" '0'
# ...and the very same builtins still work when nothing throws
assert still_works_arr "console.log([1].concat([2]).join(','), [1,2,3].fill(0,1).join(','), [1,2,3].splice(1,1).join(','))" '1,2 1,0,0 2'
assert still_works_str "console.log('a'.concat('b'), 'abc'.replace('a','X'), 'ab'.padStart(4,'-'))" 'ab Xbc --ab'
assert still_works_msf "var m=new Map();m.set('k',1);var s=new Set();s.add(1);console.log(m.size,s.size,(1.5).toFixed(1),/a/.test('a'))" '1 1 1.5 true'
# the ORDER the hoist would have broken: dispatcher misses -> getter -> args
assert getter_before_args \
    "var log=[];Object.defineProperty(Array.prototype,'yyy',{get:function(){log.push('getter');return function(){return 'ok'}},configurable:true});function g(){log.push('arg');return 1}console.log([1].yyy(g()), log.join(','))" \
    'ok getter,arg'

if [ "$ran" -lt 20 ]; then
    echo "[js-argguard] FAIL: only $ran runtime assertions ran (expected >= 20)"; fail=1
fi
echo "[js-argguard] $ran runtime assertions executed"

if [ "$fail" -eq 0 ]; then
    echo "[js-argguard] ALL PASS"
else
    echo "[js-argguard] SOME FAILED"
fi
exit "$fail"
