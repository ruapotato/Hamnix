#!/usr/bin/env bash
# scripts/test_jsengine_gc_unblocks_host.sh — FAST, QEMU-free gate that the
# value-cell + env-scope garbage collectors UNBLOCK the loop class of scripts
# that used to exhaust the bump-only arenas.
#
# Before GC: a plain numeric loop leaked one boxed value per temporary and
# exhausted the value arena (MAX_VAL=1,000,000) at ~400-500k allocs; a
# call-in-loop kernel hit a hard cliff in the bump-only env arena at a few tens
# of thousands of frames. The value-cell mark-sweep (Phase 1) and env-scope
# mark-sweep (Phase 3) now reclaim dead cells/scopes, so multi-million-iteration
# loops run to completion. This gate proves BOTH complete AND produce the exact
# checksum V8 does (correctness, not just "did not crash").
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
FIXDIR="tests/fixtures/jsbench_gc"
mkdir -p "$OUT"

echo "[js-gc] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_gc_compile.log"; then
    echo "[js-gc] FAIL: host driver did not compile"; cat "$OUT/js_gc_compile.log"; exit 1
fi

# Expected checksums (independently reproducible via `node <fixture>`).
declare -A WANT=(
    [value-arena-5m]="RESULT: 12499997500000"
    [env-frames-1m]="RESULT: 2000000"
)

fail=0
for name in value-arena-5m env-frames-1m; do
    got="$(timeout 60 "$BIN" "$FIXDIR/$name.js" 2>&1)"
    if [ "$got" = "${WANT[$name]}" ]; then
        echo "[js-gc] PASS $name completes + matches V8 ($got)"
    else
        echo "[js-gc] FAIL $name: want '${WANT[$name]}' got '$got'"
        fail=1
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "[js-gc] RESULT: PASS"; exit 0
else
    echo "[js-gc] RESULT: FAIL"; exit 1
fi
