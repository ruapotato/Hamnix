#!/usr/bin/env bash
# scripts/test_jsengine_gc_ceiling_host.sh — FAST, QEMU-free gate proving the
# Phase-1 value-arena garbage collector unblocks the numeric-loop class of
# scripts that previously EXHAUSTED the value arena.
#
# Before GC a JS value was a bare bump-allocated handle with no free list, so a
# hot arithmetic loop permanently consumed a value cell per operation and died
# at ~400-500k allocations ("value pool exhausted"). This drives a 3,000,000-
# iteration accumulation — FAR past that old ceiling, with a bounded live set —
# and asserts it now COMPLETES with the exact correct sum. The GC reclaims the
# dead per-iteration temporaries so n_vals never approaches MAX_VAL.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-gc-ceil] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_gc_ceil_compile.log"; then
    echo "[js-gc-ceil] FAIL: host driver did not compile"; cat "$OUT/js_gc_ceil_compile.log"; exit 1
fi

N=3000000
# sum(0..N-1) = N*(N-1)/2, well beyond the old ~400-500k value-cell ceiling.
WANT=$(python3 -c "n=$N; print(n*(n-1)//2)")
js="$OUT/js_gc_ceil.js"
# Braceless body: no per-iteration block env, so the loop is bounded by the
# value arena (what GC reclaims), exactly the class this gate targets.
cat > "$js" <<EOF
var sum = 0;
for (var i = 0; i < $N; i++) sum = sum + i;
console.log("GCSUM=" + sum);
EOF

got="$OUT/js_gc_ceil.out"
"$BIN" "$js" > "$got" 2>&1
rc=$?

fail=0
if [ "$rc" -ne 0 ]; then
    echo "[js-gc-ceil] FAIL: engine exited $rc (arena exhaustion?)"; echo "  out: $(tail -1 "$got")"; fail=1
fi
if ! grep -q "^GCSUM=$WANT\$" "$got"; then
    echo "[js-gc-ceil] FAIL: expected GCSUM=$WANT, got: '$(tail -1 "$got")'"; fail=1
else
    echo "[js-gc-ceil] PASS: $N-iteration loop completed with correct sum ($WANT)"
fi

if [ "$fail" -eq 0 ]; then
    echo "[js-gc-ceil] RESULT: PASS"; exit 0
else
    echo "[js-gc-ceil] RESULT: FAIL"; exit 1
fi
