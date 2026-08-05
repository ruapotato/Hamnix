#!/usr/bin/env bash
# scripts/test_js_task_reentry_host.sh — FAST, QEMU-free gate: a task that is
# ALREADY ON THE STACK must never be selected and run a second time.
#
# WHY THIS GATE EXISTS
# ====================
# `await` in this engine is not a suspension; it is a synchronous nested drain
# (do_await -> drain_until_settled -> run_one_task), and that drain runs INSIDE
# the invoke() of whatever task is currently executing. run_one_task's selection
# loop used to test only timer_active, but timer_active was cleared -- and the
# slot retired -- AFTER invoke() returned. So the nested scan looked at the very
# slot whose callback it was standing inside, saw active == 1, and ran that
# callback again. Two writers for one piece of state ("has this task been
# taken?"), only one of them on the readers' path.
#
# Every `await` inside a task therefore recursed one level deeper on the SAME
# task, forever: the awaited promise could never settle, because the drain never
# got past the task that was waiting on it. It ended when the interpreter had
# ~14,300 frames live and the GC root stack hit its 4096 cap. The engine
# reported "gc root stack overflow", which is why this was catalogued for a long
# time as a leaked root -- it was not one. It was runaway recursion touching the
# root stack on the way down.
#
# 20 of 706 vendored WPT files died this way (12 of them dom/nodes/moveBefore/*,
# and 10 MORE died on "string pool exhausted" that the same recursion had
# burned). The whole class is invisible to every other timer gate, because they
# all test tasks that do not await.
#
# WHAT IT ASSERTS -- three shapes of the same rule:
#   1. a setTimeout callback that awaits a promise resolved by a LATER timer
#      runs exactly once, and resumes
#   2. the same for an INTERVAL callback (a slot that deliberately stays
#      active == 1 across its own firing, so it cannot rely on retirement)
#   3. a callback that awaits an ALREADY-RESOLVED promise still runs once
#
# Each asserts an exact output string, so an engine that merely stops crashing
# but runs the callback twice fails here.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TAG="[task-reentry]"
OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "$TAG compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/task_reentry_compile.log"; then
    echo "$TAG FAIL: host driver did not compile"; cat "$OUT/task_reentry_compile.log"; exit 1
fi
echo "$TAG PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-file-body> <expected-full-output-joined-by-|>
assert_full() {
    local name="$1" js="$2" exp="$3"
    printf '%s\n' "$js" > "$OUT/task_reentry_case.js"
    local got rc
    got="$(timeout 30 "$BIN" "$OUT/task_reentry_case.js" 2>&1 | paste -sd'|' -)"
    rc=$?
    if [ "$got" = "$exp" ]; then
        echo "$TAG PASS $name"
    else
        echo "$TAG FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# 1. one-shot task awaiting a promise a LATER task resolves.
#    Before the fix: "gc root stack overflow".
assert_full timeout_await '
var log = [];
setTimeout(function () {
    log.push("outer-enter");
    (async function () {
        await new Promise(function (r) { setTimeout(r, 0); });
        log.push("inner-resumed");
    })();
    log.push("outer-exit");
}, 0);
setTimeout(function () { console.log(log.join(",")); }, 5);
' 'outer-enter,inner-resumed,outer-exit'

# 2. an INTERVAL callback that awaits. An interval slot stays active == 1 across
#    its own firing by design, so nothing about retirement can save it: the busy
#    count is the only thing that keeps the nested drain off it. n must reach
#    exactly 2 -- not thousands, and not a crash.
assert_full interval_await '
var n = 0;
var id = setInterval(function () {
    n = n + 1;
    (async function () { await new Promise(function (r) { setTimeout(r, 0); }); })();
    if (n >= 2) { clearInterval(id); console.log("ticks " + n); }
}, 0);
' 'ticks 2'

# 3. awaiting an already-resolved promise inside a task: the drain has nothing
#    to do, so the task must simply finish once.
assert_full resolved_await '
var log = [];
setTimeout(function () {
    log.push("enter");
    (async function () { await Promise.resolve(1); log.push("resumed"); })();
    log.push("exit");
}, 0);
setTimeout(function () { console.log(log.join(",")); }, 5);
' 'enter,resumed,exit'

# 4. microtask checkpoint shape: a promise reaction that awaits a promise
#    resolved by another reaction. Same rule, macrotask-free.
assert_full micro_await '
var log = [];
Promise.resolve().then(function () {
    log.push("r1");
    (async function () { await Promise.resolve(); log.push("r1-resumed"); })();
});
Promise.resolve().then(function () { log.push("r2"); });
setTimeout(function () { console.log(log.join(",")); }, 0);
' 'r1,r1-resumed,r2'

if [ "$fail" -eq 0 ]; then
    echo "$TAG RESULT: PASS"
    exit 0
fi
echo "$TAG RESULT: FAIL"
exit 1
