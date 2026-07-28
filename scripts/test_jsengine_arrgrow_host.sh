#!/usr/bin/env bash
# scripts/test_jsengine_arrgrow_host.sh — FAST, QEMU-free gate proving a JS
# array keeps ALL its elements no matter how much it (or a re-entrant callback)
# grows the bump allocator.
#
# Regression for the leaky array bump allocator: arr_grow abandoned the old
# backing chunk on every doubling (~2x waste that is never reclaimed until
# js_init), so a single array of ~90k elements — or the many small arrays a DOM
# build / re-entrant callback churns — overran ax_val and silently corrupted or
# dropped a later array's tail element (the "length 5 -> 4 after a callback
# returns" the DOM work hit), here segfaulting outright. The fix grows the array
# IN PLACE when its chunk is on top of the bump (no copy, no leak) and guards the
# ceiling. Two cases: (1) one large array's integrity; (2) re-entrant callbacks
# building arrays while a big array also grows.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-arrgrow] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_arrgrow_compile.log"; then
    echo "[js-arrgrow] FAIL: host driver did not compile"; cat "$OUT/js_arrgrow_compile.log"; exit 1
fi

fail=0

# --- case 1: one large array must retain every element -------------------
cat > "$OUT/arrgrow1.js" <<'EOF'
var a = [];
for (var i = 0; i < 90000; i++) a.push(i);
var ok = (a.length === 90000) && (a[0] === 0) && (a[45000] === 45000) && (a[89999] === 89999);
console.log("BIG " + (ok ? "OK" : "BAD") + " " + a.length + " " + a[89999]);
EOF
if ! "$BIN" "$OUT/arrgrow1.js" > "$OUT/arrgrow1.out" 2>&1; then
    echo "[js-arrgrow] FAIL case1: driver crashed (bump overrun)"; cat "$OUT/arrgrow1.out"; fail=1
elif grep -q '^BIG OK 90000 89999$' "$OUT/arrgrow1.out"; then
    echo "[js-arrgrow] PASS case1 (90000-element array intact)"
else
    echo "[js-arrgrow] FAIL case1: $(cat "$OUT/arrgrow1.out")"; fail=1
fi

# --- case 2: two INTERLEAVED arrays (each grow forces the other off the top of
# the bump -> the copy/leak slow path) must both stay intact. This is the
# allocator-level shape of "an array grown while another is also being built"
# (a callback allocating mid-build); the leaky allocator overran ax_val here and
# corrupted a tail. Stays under the value-pool ceiling so it isolates the array
# growth path.
cat > "$OUT/arrgrow2.js" <<'EOF'
var a = [], b = [];
for (var i = 0; i < 50000; i++) { a.push(i); b.push(0 - i); }
var ok = (a.length === 50000) && (b.length === 50000) &&
         (a[0] === 0) && (a[49999] === 49999) && (a[25000] === 25000) &&
         (b[0] === 0) && (b[49999] === -49999) && (b[25000] === -25000);
console.log("INTERLEAVED " + (ok ? "OK" : "BAD") + " " + a[49999] + " " + b[49999]);
EOF
if ! "$BIN" "$OUT/arrgrow2.js" > "$OUT/arrgrow2.out" 2>&1; then
    echo "[js-arrgrow] FAIL case2: driver crashed (interleaved bump overrun)"; cat "$OUT/arrgrow2.out"; fail=1
elif grep -q '^INTERLEAVED OK 49999 -49999$' "$OUT/arrgrow2.out"; then
    echo "[js-arrgrow] PASS case2 (two interleaved 50000-element arrays intact)"
else
    echo "[js-arrgrow] FAIL case2: $(cat "$OUT/arrgrow2.out")"; fail=1
fi

# --- case 3: a genuine re-entrant callback building a 5-element array must not
# lose its tail element (the "length 5 -> 4 after a callback returns" symptom).
cat > "$OUT/arrgrow3.js" <<'EOF'
var scaffold = [];
for (var i = 0; i < 1200; i++) scaffold.push(i);
var results = [];
scaffold.forEach(function (n) {
  var a = [];
  a.push(n * 10);
  a.push(n * 10 + 1);
  var churn = []; churn.push(n); churn.push(n + 1); churn.push(n + 2);
  a.push(n * 10 + 2);
  a.push(n * 10 + 3);
  a.push(n * 10 + 4);
  if (n % 200 === 0) results.push(a.length === 5 ? a[4] : -1);
});
console.log("REENTRANT " + results.join(","));
EOF
if ! "$BIN" "$OUT/arrgrow3.js" > "$OUT/arrgrow3.out" 2>&1; then
    echo "[js-arrgrow] FAIL case3: driver crashed"; cat "$OUT/arrgrow3.out"; fail=1
elif grep -q '^REENTRANT 4,2004,4004,6004,8004,10004$' "$OUT/arrgrow3.out"; then
    echo "[js-arrgrow] PASS case3 (re-entrant 5-element arrays kept the tail)"
else
    echo "[js-arrgrow] FAIL case3: $(cat "$OUT/arrgrow3.out")"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[js-arrgrow] RESULT: PASS"; exit 0
else
    echo "[js-arrgrow] RESULT: FAIL"; exit 1
fi
