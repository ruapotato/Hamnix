#!/usr/bin/env bash
# scripts/test_jsengine_gc_retain_host.sh — QEMU-free gate proving the Phase-1
# garbage collector NEVER frees a still-reachable value (a GC that frees a live
# value is worse than a leak).
#
# It builds a large RETAINED graph (an array of objects, each holding nested
# arrays/objects), forces a collection with the test-only gc() builtin, then
# reads back EVERY element and asserts exact correctness. If the collector's
# root set were incomplete, gc() would reclaim reachable cells and the read-back
# would mismatch. Sizes stay within the object/property bump arenas (Phase 1
# reclaims only the value arena), so the graph is fully live throughout.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-gc-retain] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_gc_retain_compile.log"; then
    echo "[js-gc-retain] FAIL: host driver did not compile"; cat "$OUT/js_gc_retain_compile.log"; exit 1
fi

js="$OUT/js_gc_retain.js"
cat > "$js" <<'EOF'
// Each node is 4 objects (node + pair[] + meta{} + nested{}); keep the total
// under the 40k object bump arena (Phase 1 reclaims only the value arena).
var N = 8000;
var a = [];
for (var i = 0; i < N; i++)
  a.push({ id: i, tag: "k" + i, pair: [i, i * 2], meta: { sq: i * i, nested: { z: i - 1 } } });
// Force collections repeatedly; the whole graph is reachable via `a`.
gc(); gc(); gc();
var ok = 1, checked = 0;
for (var i = 0; i < a.length; i++) {
  var o = a[i];
  if (o.id !== i) ok = 0;
  if (o.tag !== "k" + i) ok = 0;
  if (o.pair[0] !== i || o.pair[1] !== i * 2) ok = 0;
  if (o.meta.sq !== i * i) ok = 0;
  if (o.meta.nested.z !== i - 1) ok = 0;
  checked++;
}
// Allocate a lot of GARBAGE after building (braceless: no per-iteration env),
// forcing many collections, then re-verify the retained graph survived.
var gsum = 0;
for (var j = 0; j < 2000000; j++) gsum = gsum + j;
gc();
for (var i = 0; i < a.length; i++) if (a[i].meta.sq !== i * i) ok = 0;
console.log("RETAIN ok=" + ok + " checked=" + checked + " len=" + a.length + " g=" + (gsum > 0 ? 1 : 0));
EOF

got="$OUT/js_gc_retain.out"
"$BIN" "$js" > "$got" 2>&1
rc=$?

fail=0
if [ "$rc" -ne 0 ]; then
    echo "[js-gc-retain] FAIL: engine exited $rc"; echo "  out: $(tail -1 "$got")"; fail=1
fi
if ! grep -q "^RETAIN ok=1 checked=8000 len=8000 g=1\$" "$got"; then
    echo "[js-gc-retain] FAIL: retained graph mismatch after gc()"; echo "  got: '$(tail -1 "$got")'"; fail=1
else
    echo "[js-gc-retain] PASS: 8000-node graph fully intact across forced GC + 2M-alloc garbage churn"
fi

if [ "$fail" -eq 0 ]; then
    echo "[js-gc-retain] RESULT: PASS"; exit 0
else
    echo "[js-gc-retain] RESULT: FAIL"; exit 1
fi
