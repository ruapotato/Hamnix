#!/usr/bin/env bash
# scripts/test_hambrowse_timers_host.sh — FAST, QEMU-free gate for the JS
# engine's HTML EVENT-LOOP ordering across the timer + animation-frame + micro-
# task APIs, via the x86_64-linux host driver (user/js_host.ad).
#
# Frameworks and real sites lean hard on setTimeout/setInterval/clearTimeout/
# clearInterval, queueMicrotask, Promise reactions, and requestAnimationFrame/
# cancelAnimationFrame — and on their RELATIVE ORDER. This gate asserts the exact
# emitted order of an output log, cross-checked against node/browser semantics:
#
#   - microtask before macrotask: queueMicrotask AND Promise.resolve().then both
#     fire before a setTimeout(...,0) scheduled EARLIER
#   - two timers ordered by delay then insertion (setTimeout A@10 / B@5 -> B,A)
#   - clearTimeout / clearInterval cancel a pending callback (never runs)
#   - setInterval fires N times then clearInterval stops it
#   - captured extra args are forwarded to a timer callback
#   - nested scheduling: a timer that queues a microtask + another timer orders
#     microtask-before-the-next-macrotask
#   - requestAnimationFrame callback runs and receives a virtual timestamp;
#     cancelAnimationFrame cancels; a rAF-in-rAF loop advances a VIRTUAL clock
#     (16/32/48 ms — no wall clock, deterministic) frame by frame
#   - a setTimeout(...,0) still runs AFTER an rAF's frame-0 timestamp is 16ms but
#     BEFORE it in virtual time (delay 0 < 16) — timers and frames share one
#     virtual timeline
#
# There is NO wall-clock async: after the top-level script runs, js_eval DRAINS
# microtasks-then-earliest-macrotask deterministically, advancing a simulated
# frame clock, capped so a self-re-enqueuing loop cannot spin forever.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[hb-timers] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/hb_timers_compile.log"; then
    echo "[hb-timers] FAIL: host driver did not compile"; cat "$OUT/hb_timers_compile.log"; exit 1
fi
echo "[hb-timers] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-src> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/hb_timers_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/hb_timers_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[hb-timers] PASS $name"
    else
        echo "[hb-timers] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}
# assert_full <name> <js-src> <expected-full-output-joined-by-|>
assert_full() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/hb_timers_case.js"
    local got
    got="$(timeout 30 "$BIN" "$OUT/hb_timers_case.js" 2>&1 | paste -sd'|' -)"
    if [ "$got" = "$exp" ]; then
        echo "[hb-timers] PASS $name"
    else
        echo "[hb-timers] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- microtask-before-macrotask (the load-bearing ordering guarantee) --------
# queueMicrotask beats a setTimeout(...,0) scheduled FIRST.
assert_full micro_before_macro \
    'setTimeout(()=>console.log("macro"),0); queueMicrotask(()=>console.log("micro"));' \
    'micro|macro'
# Promise.resolve().then is a microtask too — beats an earlier setTimeout(...,0).
assert_full promise_then_before_macro \
    'setTimeout(()=>console.log("macro"),0); Promise.resolve().then(()=>console.log("micro"));' \
    'micro|macro'
# both microtask sources, in registration order, then the macrotask.
assert_full micro_sources_order \
    'setTimeout(()=>console.log("T"),0); Promise.resolve().then(()=>console.log("P")); queueMicrotask(()=>console.log("Q"));' \
    'P|Q|T'

# ---- timer delay + insertion ordering ---------------------------------------
# B at 5ms fires before A at 10ms regardless of insertion order.
assert_full timers_by_delay \
    'setTimeout(()=>console.log("A"),10); setTimeout(()=>console.log("B"),5);' \
    'B|A'
# equal delay -> insertion (FIFO) order.
assert_full timers_by_insertion \
    'setTimeout(()=>console.log("1"),0); setTimeout(()=>console.log("2"),0); setTimeout(()=>console.log("3"),0);' \
    '1|2|3'

# ---- cancellation ------------------------------------------------------------
assert clear_timeout \
    'let id=setTimeout(()=>console.log("NO"),0); clearTimeout(id); console.log("ok");' \
    'ok'
assert clear_interval \
    'let id=setInterval(()=>console.log("NO"),0); clearInterval(id); console.log("ok");' \
    'ok'

# ---- setInterval fires N then clears -----------------------------------------
assert interval_n_then_clear \
    'let n=0; let id=setInterval(()=>{n++; if(n>=4){clearInterval(id); console.log("stopped",n)}},0);' \
    'stopped 4'

# ---- args forwarded ----------------------------------------------------------
assert args_forwarded 'setTimeout((a,b,c)=>console.log(a+b+c),0,10,20,12);' '42'

# ---- nested scheduling: timer queues a microtask + a follow-up timer ---------
# inside macrotask m1: a microtask (mt) must run before the next macrotask (m2).
assert_full nested_micro_in_macro \
    'setTimeout(()=>{console.log("m1"); queueMicrotask(()=>console.log("mt")); setTimeout(()=>console.log("m2"),0);},0);' \
    'm1|mt|m2'

# ---- requestAnimationFrame ---------------------------------------------------
# the callback runs and receives the frame's virtual timestamp (16ms).
assert raf_runs 'requestAnimationFrame(t=>console.log("frame",t));' 'frame 16'
# two rAFs in the same frame fire in registration order.
assert_full raf_same_frame \
    'requestAnimationFrame(()=>console.log("a")); requestAnimationFrame(()=>console.log("b"));' \
    'a|b'
# cancelAnimationFrame cancels a pending frame callback.
assert raf_cancel \
    'let id=requestAnimationFrame(()=>console.log("NO")); cancelAnimationFrame(id); console.log("ok");' \
    'ok'
# a rAF-in-rAF animation loop advances the virtual clock frame by frame and does
# NOT spin the current frame (each re-schedule lands in the NEXT frame).
assert_full raf_loop \
    'let n=0; function f(t){ n++; console.log("f",n,t); if(n<3) requestAnimationFrame(f);} requestAnimationFrame(f);' \
    'f 1 16|f 2 32|f 3 48'
# timers share the virtual timeline with frames: setTimeout(...,0) (t=0) runs
# before the first frame (t=16); a microtask still beats them both.
assert_full timer_micro_raf_timeline \
    'requestAnimationFrame(()=>console.log("raf")); setTimeout(()=>console.log("t0"),0); queueMicrotask(()=>console.log("mt"));' \
    'mt|t0|raf'

if [ "$fail" -eq 0 ]; then
    echo "[hb-timers] RESULT: PASS"
    exit 0
else
    echo "[hb-timers] RESULT: FAIL"
    exit 1
fi
