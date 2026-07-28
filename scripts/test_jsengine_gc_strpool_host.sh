#!/usr/bin/env bash
# scripts/test_jsengine_gc_strpool_host.sh — QEMU-free gate proving the Phase-4
# NON-MOVING string-id garbage collector (a) unblocks the string-heavy class of
# scripts that previously EXHAUSTED the string id table at ~200k allocations, and
# (b) NEVER frees a still-reachable string (a GC that frees a live string is
# worse than a leak).
#
# Before Phase 4 a string id was a bare bump-allocated handle with no free list,
# so a loop that manufactures fresh strings permanently consumed an id per
# allocation and died at MAX_STR = 200000 ("string pool exhausted"). This gate:
#
#   PART A (ceiling): a manufacture-and-discard loop makes ~800k throwaway
#     strings — FAR past the old 200k-id ceiling, with a bounded LIVE set — and
#     asserts it COMPLETES with the exact rolling checksum. The collector reclaims
#     the dead per-iteration string ids so n_strs never approaches MAX_STR.
#     (Bytes are non-moving/leaked, so N is kept within the 8 MiB sp_buf budget —
#     byte reclamation is the compaction plan's job, not this gate's.)
#
#   PART B (retained): builds a large array of DISTINCT live strings, forces a
#     collection with gc(), then reads back EVERY element and reconstructs the
#     expected bytes, asserting exact equality. If the root set were incomplete,
#     gc() would reclaim a reachable id and the read-back would mismatch.
#
# Finally it re-runs the whole program under HAMNIX_JS_GC_STRESS=1 (a collection
# every ~64 allocations) and asserts BYTE-IDENTICAL output — the adversarial
# check that no live string id is ever dropped mid-operation.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-strgc] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_strgc_compile.log"; then
    echo "[js-strgc] FAIL: host driver did not compile"; cat "$OUT/js_strgc_compile.log"; exit 1
fi

NA=400000        # part A: manufacture ~2*NA = 800k throwaway string ids (4x MAX_STR)
NB=16000         # part B: distinct live strings kept in an array across gc()
MOD=1000000007

# Expected checksums, computed the same way the JS does (float64-exact integers).
read -r WANT_A WANT_B <<EOF
$(python3 - "$NA" "$NB" "$MOD" <<'PY'
import sys
NA, NB, MOD = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
# PART A: s = "x" + i ; chk += s.length ; s.length == 1 + len(str(i))
a = 0
for i in range(NA):
    a = (a + 1 + len(str(i))) % MOD
# PART B: e = "item#" + i + "@" + (i*i) ; rchk += e.length
b = 0
for i in range(NB):
    e = "item#" + str(i) + "@" + str(i*i)
    b = (b + len(e)) % MOD
print(a, b)
PY
)
EOF

js="$OUT/js_strgc.js"
cat > "$js" <<EOF
var MOD = $MOD;
// PART A — manufacture-and-discard: ~2*$NA throwaway string ids, live set O(1).
var chk = 0;
for (var i = 0; i < $NA; i++) {
  var s = "x" + i;                 // num->str + concat: two fresh ids, discarded
  chk = (chk + s.length) % MOD;
}
console.log("A=" + chk);
// PART B — retained graph: $NB distinct live strings, survive a forced gc().
var keep = [];
for (var i = 0; i < $NB; i++) keep.push("item#" + i + "@" + (i * i));
gc();                              // force value+env+STRING collection
var rchk = 0, ok = 1;
for (var i = 0; i < keep.length; i++) {
  var expect = "item#" + i + "@" + (i * i);   // rebuilt bytes (more allocations)
  if (keep[i] !== expect) { ok = 0; break; }  // live string must be byte-intact
  rchk = (rchk + keep[i].length) % MOD;
}
console.log("B=" + (ok ? rchk : -1));
EOF

base="$OUT/js_strgc.base"
strs="$OUT/js_strgc.stress"
timeout 120 "$BIN" "$js" > "$base" 2>&1;                      rc_base=$?
timeout 180 env HAMNIX_JS_GC_STRESS=1 "$BIN" "$js" > "$strs" 2>&1; rc_str=$?

WANT="A=$WANT_A
B=$WANT_B"

fail=0
if [ "$rc_base" -ne 0 ]; then
    echo "[js-strgc] FAIL: non-stress run exited $rc_base (string-pool exhaustion?)"; echo "  out: $(tail -2 "$base")"; fail=1
fi
if [ "$rc_str" -ne 0 ]; then
    echo "[js-strgc] FAIL: stress run exited $rc_str"; echo "  out: $(tail -2 "$strs")"; fail=1
fi
if [ "$(cat "$base")" != "$WANT" ]; then
    echo "[js-strgc] FAIL: non-stress output unexpected"
    echo "  got:  $(tr '\n' '|' < "$base")"; echo "  want: $(echo "$WANT" | tr '\n' '|')"; fail=1
else
    echo "[js-strgc] PASS: ${NA}-iter manufacture (~$((2*NA)) ids, 4x old MAX_STR ceiling) + retained gc() graph correct"
fi
if ! diff -q "$base" "$strs" >/dev/null; then
    echo "[js-strgc] FAIL: stress output DIFFERS from non-stress (a live string id was dropped)"
    echo "  base:   $(tr '\n' '|' < "$base")"; echo "  stress: $(tr '\n' '|' < "$strs")"; fail=1
else
    echo "[js-strgc] PASS: stress run (collect every ~64 allocs) byte-identical to non-stress"
fi

if [ "$fail" -eq 0 ]; then
    echo "[js-strgc] RESULT: PASS"; exit 0
else
    echo "[js-strgc] RESULT: FAIL"; exit 1
fi
