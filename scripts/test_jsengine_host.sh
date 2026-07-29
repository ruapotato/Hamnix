#!/usr/bin/env bash
# scripts/test_jsengine_host.sh — FAST, QEMU-free gate for the native
# JavaScript engine (lib/jsengine.ad) via the x86_64-linux host driver
# (user/js_host.ad).
#
# The native `js` tool needs a full installer-image boot (~6 min). This gate
# compiles the SAME lexer+parser+evaluator for the host Linux target and runs
# it directly on a suite of local .js fixtures in milliseconds — so the engine
# can be regression-tested without QEMU. It asserts the EXACT console.log
# output of each fixture (arithmetic, closures, arrays/objects, JSON round-trip,
# string methods, control flow, recursive fib).
#
# Builds with the frozen Python seed compiler (compiles 100% of the tree; no
# self-host bootstrap needed) so this gate is dependency-light.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
FIXDIR="tests/fixtures/js"
EXPDIR="$FIXDIR/expected"
mkdir -p "$OUT"

echo "[js-host] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/js_host.ad -o "$BIN" 2>"$OUT/js_compile.log"; then
    echo "[js-host] FAIL: host driver did not compile"; cat "$OUT/js_compile.log"; exit 1
fi
echo "[js-host] PASS host driver compiled -> $BIN"

# Confirm the NATIVE tool still compiles from the same engine (no regress).
echo "[js-host] compiling native js tool for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/js.ad -o "$OUT/js_native.elf" 2>"$OUT/js_native.log"; then
    echo "[js-host] FAIL: native js tool did not compile"; cat "$OUT/js_native.log"; exit 1
fi
echo "[js-host] PASS native js tool still compiles"

fail=0
run_case() {
    local name="$1"
    local js="$FIXDIR/$name.js"
    local exp="$EXPDIR/$name.txt"
    local got="$OUT/js_$name.out"
    if ! "$BIN" "$js" >"$got" 2>&1; then
        echo "[js-host] FAIL $name: driver exited non-zero"; cat "$got"; fail=1; return
    fi
    if diff -u "$exp" "$got" >"$OUT/js_$name.diff" 2>&1; then
        echo "[js-host] PASS $name (exact output match)"
    else
        echo "[js-host] FAIL $name: output mismatch"; cat "$OUT/js_$name.diff"; fail=1
    fi
}

for c in arithmetic closures arrays_objects json strings controlflow fib \
         templates arrows exceptions classes spread_destructure regex \
         webcompat largeeval builtin_tostring; do
    run_case "$c"
done

# Inline sanity assertions (independent of the .txt oracles) so the gate still
# catches a total-breakage regression even if an oracle drifted.
echo 'console.log("SPINE " + (function f(n){return n<2?n:f(n-1)+f(n-2);})(12));' > "$OUT/js_spine.js"
"$BIN" "$OUT/js_spine.js" > "$OUT/js_spine.out" 2>&1
if grep -q '^SPINE 144$' "$OUT/js_spine.out"; then
    echo "[js-host] PASS spine (recursive fib via IIFE = 144)"
else
    echo "[js-host] FAIL spine (expected 'SPINE 144')"; cat "$OUT/js_spine.out"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[js-host] RESULT: PASS"
    exit 0
else
    echo "[js-host] RESULT: FAIL"
    exit 1
fi
