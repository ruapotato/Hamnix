#!/usr/bin/env bash
# scripts/test_jsengine_async_host.sh — FAST, QEMU-free gate for the JS engine's
# async/await support (lib/jsengine.ad) via the x86_64-linux host driver
# (user/js_host.ad).
#
# Modern real pages use async/await pervasively. This engine is a synchronous
# tree-walk interpreter with a DETERMINISTIC microtask/timer drain and no real
# concurrency, so async/await is modelled WITHOUT CPS/continuations:
#   - an `async function` returns a Promise; its body runs synchronously, a
#     normal return/fall-through FULFILLS it, an uncaught throw REJECTS it
#     (a returned promise/thenable is assimilated).
#   - `await expr` resolves expr to a promise, DRAINS the deterministic
#     microtask/timer queue until it settles, then evaluates to the fulfilled
#     value or RE-THROWS the rejection reason (so a surrounding try/catch sees it).
#
# This is NOT spec-perfect for adversarial interleavings across multiple
# concurrent async chains (the synchronous drain runs an awaiting body eagerly
# rather than yielding a microtask turn), but every awaited VALUE and every
# single-chain ordering matches node. The cases below are deliberately
# single-chain so the expected output is EXACTLY node's, cross-checked with
# `node <case>`.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-async] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_async_compile.log"; then
    echo "[js-async] FAIL: host driver did not compile"; cat "$OUT/js_async_compile.log"; exit 1
fi
echo "[js-async] PASS host driver compiled -> $BIN"

# Confirm the NATIVE js tool still compiles from the same engine (no regress).
echo "[js-async] compiling native js tool for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/js.ad "$OUT/js_native.elf" 2>"$OUT/js_async_native.log"; then
    echo "[js-async] FAIL: native js tool did not compile"; cat "$OUT/js_async_native.log"; exit 1
fi
echo "[js-async] PASS native js tool still compiles"

fail=0
# assert_full <name> <js-src> <expected-full-output-joined-by-|>
assert_full() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_async_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/js_async_case.js" 2>&1 | paste -sd'|' -)"
    if [ "$got" = "$exp" ]; then
        echo "[js-async] PASS $name"
    else
        echo "[js-async] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# an async function returns a Promise; a plain return fulfills it.
assert_full ret_val    'async function f(){ return 5 } f().then(x=>console.log(x));' '5'
# await a fulfilled promise: value flows through, arithmetic on it works.
assert_full await_val  'async function f(){ let x=await Promise.resolve(3); return x+1 } f().then(console.log);' '4'
# two sequential awaits in one body run in order.
assert_full sequential 'async function f(){ console.log(await Promise.resolve(1)); console.log(await Promise.resolve(2)); } f();' '1|2'
# await a rejected promise: the returned promise rejects with the reason.
assert_full reject     'async function f(){ await Promise.reject("e") } f().then(()=>console.log("N"),e=>console.log("rej",e));' 'rej e'
# try/catch around a rejected await catches the reason.
assert_full trycatch   'async function f(){ try{ await Promise.reject("e") }catch(x){ console.log("c",x) } } f();' 'c e'
# await Promise.all inside async yields the array of values.
assert_full await_all  'async function f(){ let a=await Promise.all([Promise.resolve(1),Promise.resolve(2),3]); console.log(a[0],a[1],a[2]) } f();' '1 2 3'
# await a non-promise yields the value directly.
assert_full await_val7 'async function f(){ console.log(await 7) } f();' '7'
# an async arrow (concise body) returns a promise of its awaited value.
assert_full async_arrow 'const g=async n=>await Promise.resolve(n*2); g(5).then(console.log);' '10'
# a bare throw inside async rejects the returned promise.
assert_full async_throw 'async function f(){ throw "boom" } f().catch(e=>console.log("t",e));' 't boom'
# a returned promise is assimilated (flattened), not wrapped.
assert_full flatten    'async function f(){ return Promise.resolve(42) } f().then(console.log);' '42'
# await inside a loop accumulates sequentially.
assert_full loop       'async function f(){ let s=0; for(let i=1;i<=3;i++){ s+=await Promise.resolve(i) } return s } f().then(console.log);' '6'
# awaiting another async fn's call composes.
assert_full nested     'async function inner(){ return await Promise.resolve(21) } async function outer(){ return (await inner())+1 } outer().then(console.log);' '22'
# a rejection thrown by an awaited async fn propagates up through await + catch.
assert_full propagate  'async function h(){ await Promise.reject("R") } async function c(){ try{ await h() }catch(e){ console.log("caught",e); return "ok" } } c().then(v=>console.log(v));' 'caught R|ok'
# async is a CONTEXTUAL keyword: usable as an identifier outside an async fn.
assert_full contextual 'var await=11; function async(x){return x+1} console.log(await, async(4));' '11 5'

if [ "$fail" -eq 0 ]; then
    echo "[js-async] RESULT: PASS"
    exit 0
else
    echo "[js-async] RESULT: FAIL"
    exit 1
fi
