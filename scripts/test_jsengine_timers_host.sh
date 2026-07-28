#!/usr/bin/env bash
# scripts/test_jsengine_timers_host.sh — FAST, QEMU-free gate for the JS
# engine's deferred-callback task queue (lib/jsengine.ad) via the x86_64-linux
# host driver (user/js_host.ad).
#
# Real interactive pages defer work through timers — deferred init, "run after
# load", polling loops. The engine now models setTimeout/setInterval/
# clearTimeout/clearInterval/queueMicrotask as a BOUNDED queue of pending
# callbacks that js_eval DRAINS after the top-level script finishes (NOT a
# wall-clock async runtime): callbacks pop in (microtask-first, delay,
# insertion) order, capped at 10000 total invocations so a self-re-enqueuing
# setInterval cannot spin forever.
#
# This gate asserts, against node/browser semantics:
#   - setTimeout(f,0) actually runs f by drain time
#   - two timers ordered by delay (5ms before 10ms)
#   - clearTimeout cancels a pending callback (never runs)
#   - setInterval self-clearing stops at N
#   - an un-cleared setInterval hits the cap and TERMINATES (no hang)
#   - queueMicrotask runs before macrotasks
#   - captured extra args are forwarded to the callback
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-timers] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_timers_compile.log"; then
    echo "[js-timers] FAIL: host driver did not compile"; cat "$OUT/js_timers_compile.log"; exit 1
fi
echo "[js-timers] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-src> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_timers_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/js_timers_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-timers] PASS $name"
    else
        echo "[js-timers] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}
# assert_full <name> <js-src> <expected-full-output-joined-by-|>
assert_full() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_timers_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/js_timers_case.js" 2>&1 | paste -sd'|' -)"
    if [ "$got" = "$exp" ]; then
        echo "[js-timers] PASS $name"
    else
        echo "[js-timers] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# setTimeout(f,0) actually runs f by the time the drain happens.
assert setTimeout_runs   'let x=0; setTimeout(()=>{x=5; console.log(x)},0);'                       '5'
# a callback mutating a closure var is observable after the drain (log it there).
assert setTimeout_mutate 'let x=0; setTimeout(()=>{x=5},0); setTimeout(()=>console.log(x),1);'      '5'
# ordering: the 5ms timer fires before the 10ms timer regardless of insertion.
assert_full ordering     'setTimeout(()=>console.log("b"),10); setTimeout(()=>console.log("a"),5);' 'a|b'
# clearTimeout cancels — the callback must never run.
assert clear_cancels     'let id=setTimeout(()=>console.log("NO"),0); clearTimeout(id); console.log("done");' 'done'
# setInterval that clears itself after N runs stops at N.
assert interval_selfclear 'let n=0; let id=setInterval(()=>{n++; if(n>=3){clearInterval(id); console.log("stopped",n)}},0);' 'stopped 3'
# an un-cleared setInterval hits the cap (10000) and TERMINATES (no hang).
assert interval_capped   'let n=0; setInterval(()=>{n++; if(n==10000)console.log("cap",n)},0); console.log("ok");' 'ok'
# microtasks run before macrotasks in the drain.
assert_full micro_first  'setTimeout(()=>console.log("macro"),0); queueMicrotask(()=>console.log("micro"));' 'micro|macro'
# a microtask queued during a macrotask still precedes the next macrotask.
assert_full micro_nested 'setTimeout(()=>{console.log("m1"); queueMicrotask(()=>console.log("mt")); setTimeout(()=>console.log("m2"),0);},0);' 'm1|mt|m2'
# captured extra args are forwarded to the callback.
assert extra_args        'setTimeout((a,b)=>console.log(a+b),0,40,2);'                               '42'
# clearInterval before any fire cancels every occurrence.
assert clear_interval    'let id=setInterval(()=>console.log("NO"),0); clearInterval(id); console.log("cleared");' 'cleared'

if [ "$fail" -eq 0 ]; then
    echo "[js-timers] RESULT: PASS"
    exit 0
else
    echo "[js-timers] RESULT: FAIL"
    exit 1
fi
