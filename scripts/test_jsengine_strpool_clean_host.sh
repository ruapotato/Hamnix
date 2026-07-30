#!/usr/bin/env bash
# scripts/test_jsengine_strpool_clean_host.sh — FAST, QEMU-free gate that the
# STRING-POOL ceiling fails CLEANLY.
#
# The string pool (sp_buf / st_off / st_len, MAX_STR ids) is bump-only and is
# NOT garbage-collected (unlike the value + env arenas, which now are). A loop
# that manufactures a fresh string every iteration ("item-"+i+"-tail") therefore
# eventually exhausts it. That is expected. What is NOT acceptable is the way it
# USED to fail: bld_end() (the string-builder used by `+` concatenation) wrote
# st_off/st_len[n_strs] with n_strs >= MAX_STR — out of bounds into adjacent BSS
# (the intern table / globals) — which surfaced as a spurious, misleading
# "ReferenceError: console is not defined" instead of a clean, catchable
# "string pool exhausted". str_new() already guarded this; bld_end() did not.
#
# This gate asserts the failure is now reported as "string pool exhausted" and
# NOT as the corruption artifact "console is not defined".
#
# SELF-CALIBRATING (2026-07-29). The iteration count used to be the literal
# 500000, which is not a property of the engine — it is a property of SP_CAP
# being 8 MiB. When SP_CAP was right-sized to 16 MiB the loop simply finished
# and the gate went red without anything being broken. String IDs are reclaimed
# by gc_collect_strings, so BYTES are the only binding constraint: the trip
# point is SP_CAP / ~16 B per iteration. The count is now read from
# lib/web/js/state.ad with 2x margin, so the gate keeps testing the CEILING
# rather than one historical number.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-strpool] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_strpool_compile.log"; then
    echo "[js-strpool] FAIL: host driver did not compile"; cat "$OUT/js_strpool_compile.log"; exit 1
fi

SP_CAP="$(sed -n 's/^SP_CAP: *int32 *= *\([0-9]*\).*/\1/p' lib/web/js/state.ad | head -1)"
if [ -z "$SP_CAP" ]; then
    echo "[js-strpool] INCONCLUSIVE: could not read SP_CAP from lib/web/js/state.ad;"
    echo "[js-strpool]   the loop size below would not be calibrated to the ceiling."
    exit 125
fi
# ~16 leaked bytes per iteration (measured), x2 margin.
ITERS=$(( SP_CAP / 8 ))
echo "[js-strpool] SP_CAP=$SP_CAP -> $ITERS iterations to reach the ceiling"

js="$OUT/js_strpool.js"
cat > "$js" <<EOF
// Manufacture ~2 fresh strings per iteration until the byte pool is exhausted.
var n = 0, junk;
for (var i = 0; i < $ITERS; i++) { junk = "item-" + i + "-tail"; n += junk.length; }
console.log("RESULT: " + n);
EOF

got="$("$BIN" "$js" 2>&1)"

fail=0
if echo "$got" | grep -qi "console is not defined"; then
    echo "[js-strpool] FAIL: BSS-corruption artifact 'console is not defined' returned"
    echo "  got: '$got'"
    fail=1
fi
if echo "$got" | grep -qi "string pool exhausted"; then
    echo "[js-strpool] PASS clean error: 'string pool exhausted'"
else
    echo "[js-strpool] FAIL: expected 'string pool exhausted', got: '$got'"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[js-strpool] RESULT: PASS"; exit 0
else
    echo "[js-strpool] RESULT: FAIL"; exit 1
fi
