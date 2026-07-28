#!/usr/bin/env bash
# scripts/test_jsengine_throwguard_host.sh — FAST, QEMU-free gate that the FIRST
# engine-raised exception WINS: a second throw_error() during the same unwind
# must not replace the live one. Runs on the x86_64-linux host driver
# (user/js_host.ad).
#
# WHY THIS GATE EXISTS
# The evaluator carries ONE global completion state (`ctl` + `throw_val`).
# throw_error() — the engine's own TypeError/ReferenceError/RangeError raiser —
# opens with
#
#     if ctl == CTL_THROW or err_flag != 0:
#         return
#
# An audit flagged that guard as possibly-dead code and could not construct a
# reachable case. It is NOT dead. Delete the `ctl == CTL_THROW` half, rebuild,
# and EIGHT of the twelve cases below change their reported error:
#
#     nosuch.foo      ReferenceError: nosuch is not defined
#                  -> TypeError: cannot read property 'foo' of null or undefined
#     1n + nosuch     ReferenceError: nosuch is not defined
#                  -> TypeError: Cannot mix BigInt and other types
#
# The mechanism is ordinary and everywhere: eval_expr raises a ReferenceError
# for the missing base, RETURNS `undefined` as its (meaningless) value, and the
# CONSUMING operation — member access, for-of, BigInt arithmetic — then raises
# its own error about that `undefined`. Without the guard the second error
# overwrites the first and the page reports a bogus TypeError about `undefined`
# instead of the real "x is not defined". That is exactly the failure mode that
# makes a broken script un-debuggable, and it is reachable from one line of
# ordinary JS.
#
# EVERY expectation below is `node` v20's own `e.name + ": " + e.message`,
# pasted from its stdout.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-throwguard] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_throwguard_compile.log"; then
    echo "[js-throwguard] FAIL: host driver did not compile"
    cat "$OUT/js_throwguard_compile.log"; exit 1
fi
echo "[js-throwguard] PASS host driver compiled -> $BIN"

fail=0
ran=0
# assert <name> <js-that-console.logs-ONE-line> <expected-first-line-from-node>
assert() {
    local name="$1" js="$2" exp="$3"
    ran=$((ran + 1))
    printf '%s\n' "$js" > "$OUT/js_throwguard_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/js_throwguard_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-throwguard] PASS $name"
    else
        echo "[js-throwguard] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# P() reports name+message so a SWAPPED exception is visible, not just "threw".
P='function P(f){try{f()}catch(e){console.log(e.name+": "+e.message)}}'
REF='ReferenceError: nosuch is not defined'

# ---- the eight cases the guard actually saves ------------------------------
# each one: eval_expr raises ReferenceError, hands back `undefined`, and the
# consumer would raise its own TypeError about that `undefined`.
assert member_of_missing      "$P;P(function(){return nosuch.foo})"            "$REF"
assert member_chain_missing   "$P;P(function(){return nosuch.a.b.c})"          "$REF"
assert index_by_missing       "$P;P(function(){var o={};return o[nosuch].bar})" "$REF"
assert index_both_missing     "$P;P(function(){return nosuch[nosuch2]})"       "$REF"
assert index_null_base        "$P;P(function(){var o=null;return o[nosuch]})"  "$REF"
assert bigint_mix_missing     "$P;P(function(){return (1n + nosuch)})"         "$REF"
assert forof_missing_iterable "$P;P(function(){for(const x of nosuch.list){}})" "$REF"
assert forin_missing_obj      "$P;P(function(){for(const k in nosuch.map){}})" "$REF"

# ---- and the cases that already reported the first error ------------------
assert call_missing           "$P;P(function(){return nosuch()})"              "$REF"
assert call_method_missing    "$P;P(function(){return nosuch.foo()})"          "$REF"
assert new_missing            "$P;P(function(){new nosuch()})"                 "$REF"
assert spread_obj_missing     "$P;P(function(){return {...nosuch}})"           "$REF"
assert spread_arr_missing     "$P;P(function(){return [...nosuch]})"           "$REF"

# ---- the guard must NOT swallow a LATER, INDEPENDENT exception -------------
# once the first is caught, ctl is back to NONE and the next one must raise.
assert second_error_after_catch \
    "$P;var r=[];try{nosuch.foo}catch(e){r.push(e.name)}try{null.bar}catch(e){r.push(e.name)}console.log(r.join(','))" \
    'ReferenceError,TypeError'
assert loop_raises_each_time \
    "var r=[];for(var i=0;i<3;i++){try{null.x}catch(e){r.push(e.name)}}console.log(r.join(','))" \
    'TypeError,TypeError,TypeError'
# a USER throw inside a catch of an engine error still propagates
assert user_throw_in_catch \
    'try{try{nosuch.foo}catch(e){throw new Error("wrapped:"+e.name)}}catch(e2){console.log(e2.message)}' \
    'wrapped:ReferenceError'
# an engine error raised INSIDE a catch block (ctl is CTL_NONE again there)
assert engine_error_in_catch \
    'try{try{nosuch.foo}catch(e){null.bar}}catch(e2){console.log(e2.name)}' \
    'TypeError'
# finally must still be able to override with its own engine error
assert engine_error_in_finally \
    'function f(){try{throw new Error("a")}finally{null.bar}}try{f()}catch(e){console.log(e.name)}' \
    'TypeError'

# a gate that asserted nothing would be worthless: prove we actually ran cases
if [ "$ran" -lt 18 ]; then
    echo "[js-throwguard] FAIL: only $ran assertions ran (expected >= 18)"; exit 1
fi
echo "[js-throwguard] $ran assertions executed"

if [ "$fail" -eq 0 ]; then
    echo "[js-throwguard] ALL PASS"
else
    echo "[js-throwguard] SOME FAILED"
fi
exit "$fail"
