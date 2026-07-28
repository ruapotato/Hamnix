#!/usr/bin/env bash
# scripts/test_jsengine_performance_host.sh — FAST, QEMU-free gate for the JS
# engine's `performance` global (High Resolution Time + User Timing), via the
# x86_64-linux host driver (user/js_host.ad).
#
# WHY THIS MATTERS: real sites' framework bootstraps read `performance.now()` and
# call the User Timing no-ops (`performance.mark`/`measure`/`clearMarks`)
# UNCONDITIONALLY during init. A missing `performance` global threw a
# ReferenceError that aborted the ENTIRE bootstrap script — on google.com this is
# exactly what stranded `google.c.maft` ("maft is not a function" downstream)
# because the timing script that also wires google.c.* bailed on `performance.mark`.
#
# Asserts the spec surface directly (no external oracle): now() is a number and
# monotonic-nondecreasing; the User Timing side-effects are callable no-ops;
# getEntriesByType returns an (empty) array; and the legacy PerformanceTiming
# sub-object exposes numeric navigation fields sites read for deltas.
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-perf] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_perf_compile.log"; then
    echo "[js-perf] FAIL: host driver did not compile"; cat "$OUT/js_perf_compile.log"; exit 1
fi
echo "[js-perf] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_perf_case.js"
    local got
    got="$("$BIN" "$OUT/js_perf_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-perf] PASS $name"
    else
        echo "[js-perf] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- the global exists (this is the ReferenceError that aborted bootstraps) ----
assert exists         'console.log(typeof performance)'                        'object'

# ---- performance.now(): a number, non-negative, monotonic-nondecreasing ----
assert now_type       'console.log(typeof performance.now())'                  'number'
assert now_nonneg     'console.log(performance.now() >= 0)'                     'true'
assert now_monotonic  'var a=performance.now(),b=performance.now();console.log(b>=a)' 'true'

# ---- User Timing no-ops are CALLABLE (frameworks call them unconditionally) --
assert mark           'console.log(performance.mark("t0"))'                     'undefined'
assert measure        'console.log(performance.measure("m","t0"))'             'undefined'
assert clearmarks     'console.log(performance.clearMarks())'                   'undefined'
assert clearmeasures  'console.log(performance.clearMeasures())'               'undefined'
# the `performance.mark && performance.mark(...)` guard idiom must see a function
assert mark_is_fn     'console.log(typeof performance.mark)'                    'function'

# ---- getEntriesByType / getEntries -> an (empty) array ----
assert entries_isarr  'console.log(Array.isArray(performance.getEntriesByType("resource")))' 'true'
assert entries_len    'console.log(performance.getEntriesByType("resource").length)' '0'
assert getentries     'console.log(Array.isArray(performance.getEntries()))'    'true'

# ---- legacy PerformanceTiming sub-object (sites read fields for deltas) ----
assert timing_type    'console.log(typeof performance.timing)'                  'object'
assert timing_navstart 'console.log(typeof performance.timing.navigationStart)' 'number'
assert timing_respstart 'console.log(typeof performance.timing.responseStart)'  'number'
assert timeorigin     'console.log(typeof performance.timeOrigin)'              'number'

# ---- the exact google idiom: guarded mark call runs without throwing ----
assert google_idiom   'performance.mark&&performance.mark("frt");console.log("OK")' 'OK'

if [ "$fail" -eq 0 ]; then
    echo "[js-perf] RESULT: PASS"
    exit 0
else
    echo "[js-perf] RESULT: FAIL"
    exit 1
fi
