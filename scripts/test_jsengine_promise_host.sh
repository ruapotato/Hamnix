#!/usr/bin/env bash
# scripts/test_jsengine_promise_host.sh — FAST, QEMU-free gate for the JS
# engine's Promise support (lib/jsengine.ad) via the x86_64-linux host driver
# (user/js_host.ad).
#
# Modern real pages are promise-heavy. The engine implements a Promise/A+ shaped
# Promise whose reaction callbacks run as MICROTASKS on the SAME #178 deferred-
# callback queue (drain_timers): a settled promise enqueues a microtask job
# carrying the reaction id, and the drain runs all microtasks before any
# setTimeout macrotask. Everything settles deterministically during the
# end-of-script drain (NOT wall-clock async), so the expected output is exact.
#
# Assertions are cross-checked against node semantics:
#   - .then chaining + value propagation
#   - microtask ordering (then/queueMicrotask) and micro-before-macro
#   - proper microtask interleaving across two chains
#   - rejection + .catch; a throw in .then propagates to the next .catch
#   - .finally runs on both paths and passes value/reason through
#   - Promise.resolve / Promise.reject
#   - Promise.all (fulfill array / reject on first reject), race, allSettled
#   - thenable assimilation (a .then returning a Promise is adopted)
#   - new Promise executor (sync resolve/reject; a throw rejects)
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-promise] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_promise_compile.log"; then
    echo "[js-promise] FAIL: host driver did not compile"; cat "$OUT/js_promise_compile.log"; exit 1
fi
echo "[js-promise] PASS host driver compiled -> $BIN"

fail=0
# assert_full <name> <js-src> <expected-full-output-joined-by-|>
assert_full() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_promise_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/js_promise_case.js" 2>&1 | paste -sd'|' -)"
    if [ "$got" = "$exp" ]; then
        echo "[js-promise] PASS $name"
    else
        echo "[js-promise] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# .then chaining: value flows through each stage.
assert_full chain        'Promise.resolve(1).then(x=>x+1).then(x=>console.log(x));' '2'
# ordering: sync code first, then microtasks (then before a later queueMicrotask).
assert_full ordering     'Promise.resolve().then(()=>console.log("a")); console.log("sync"); queueMicrotask(()=>console.log("b"));' 'sync|a|b'
# a promise microtask runs before a setTimeout(...,0) macrotask.
assert_full micro_macro  'setTimeout(()=>console.log("macro"),0); Promise.resolve().then(()=>console.log("micro"));' 'micro|macro'
# two chains interleave one microtask tick at a time (node: p1 q1 p2 q2).
assert_full interleave   'Promise.resolve().then(()=>console.log("p1")).then(()=>console.log("p2")); Promise.resolve().then(()=>console.log("q1")).then(()=>console.log("q2"));' 'p1|q1|p2|q2'
# multiple .then on the SAME promise fire in registration order.
assert_full order_multi  'let p=Promise.resolve(); p.then(()=>console.log(1)); p.then(()=>console.log(2)); p.then(()=>console.log(3));' '1|2|3'
# rejection is caught by .catch.
assert_full catch        'Promise.reject("boom").catch(e=>console.log("caught",e));' 'caught boom'
# a throw inside .then propagates to the next .catch.
assert_full throw_prop   'Promise.resolve(1).then(()=>{throw "x"}).catch(e=>console.log("got",e));' 'got x'
# .finally runs on the fulfill path and passes the value through.
assert_full finally_ful  'Promise.resolve(7).finally(()=>console.log("fin")).then(v=>console.log("v",v));' 'fin|v 7'
# .finally runs on the reject path and passes the reason through.
assert_full finally_rej  'Promise.reject("r").finally(()=>console.log("fin2")).catch(e=>console.log("e",e));' 'fin2|e r'
# Promise.resolve / Promise.reject as chain roots.
assert_full static_res   'Promise.resolve("ok").then(v=>console.log(v));' 'ok'
assert_full static_rej   'Promise.reject("nope").then(()=>console.log("NO"),e=>console.log(e));' 'nope'
# Promise.all fulfills with the array of values (non-promises pass through).
assert_full all          'Promise.all([Promise.resolve(1),Promise.resolve(2),3]).then(a=>console.log(a[0],a[1],a[2]));' '1 2 3'
# Promise.all rejects on the first rejection.
assert_full all_rej      'Promise.all([Promise.resolve(1),Promise.reject("no")]).then(()=>console.log("F"),e=>console.log("rej",e));' 'rej no'
# Promise.race settles with the first settlement.
assert_full race         'Promise.race([Promise.resolve("first"),Promise.reject("second")]).then(v=>console.log("race",v));' 'race first'
# Promise.allSettled reports every outcome.
assert_full allsettled   'Promise.allSettled([Promise.resolve(1),Promise.reject("e")]).then(a=>console.log(a[0].status,a[1].status,a[1].reason));' 'fulfilled rejected e'
# thenable assimilation: a .then returning a Promise adopts its resolution.
assert_full thenable     'Promise.resolve().then(()=>Promise.resolve(5)).then(x=>console.log(x));' '5'
# new Promise executor: synchronous resolve settles the promise.
assert_full executor     'new Promise((res,rej)=>res(42)).then(v=>console.log("exec",v));' 'exec 42'
# new Promise executor: a throw rejects the promise.
assert_full exec_throw   'new Promise(()=>{throw "T"}).catch(e=>console.log("thrown",e));' 'thrown T'

if [ "$fail" -eq 0 ]; then
    echo "[js-promise] RESULT: PASS"
    exit 0
else
    echo "[js-promise] RESULT: FAIL"
    exit 1
fi
