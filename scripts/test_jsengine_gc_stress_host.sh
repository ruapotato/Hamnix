#!/usr/bin/env bash
# scripts/test_jsengine_gc_stress_host.sh — QEMU-free gate that forces the
# Phase-1 collector to run VERY frequently (HAMNIX_JS_GC_STRESS=1 lowers the
# high-water mark so a collection fires roughly every ~64 allocations, i.e.
# BETWEEN operand evaluations, mid array/object-literal builds, inside call
# argument evaluation, and across loop bodies). It then asserts that every
# rooted core-site construct produces the SAME correct result as a normal run.
#
# This is the adversarial check for the explicit gc_push/gc_popto root pins:
# a missing pin would let a collection free a handle still held in an Adder
# native local, corrupting the result. The gate passes only if the stress run
# is BYTE-IDENTICAL to the non-stress run (and both match the expected output).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-gc-stress] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_gc_stress_compile.log"; then
    echo "[js-gc-stress] FAIL: host driver did not compile"; cat "$OUT/js_gc_stress_compile.log"; exit 1
fi

js="$OUT/js_gc_stress.js"
cat > "$js" <<'EOF'
var out = [];
// binop operand pinning (lhs held across rhs eval) + string concat coercion
var acc = 0;
for (var i = 0; i < 3000; i++) acc = acc + (i * 2 - 1) + 0;
out.push("acc=" + acc);
// nested array + object literals: partial result + evaluated elements pinned
var built = [];
for (var i = 0; i < 1500; i++) built.push({ id: i, pair: [i, i + 1], meta: { sq: i * i } });
var s1 = 0, s2 = 0, s3 = 0;
for (var i = 0; i < built.length; i++) { s1 += built[i].id; s2 += built[i].pair[1]; s3 += built[i].meta.sq; }
out.push("s=" + s1 + "," + s2 + "," + s3);
// call site: thisv + fnv + partial args pinned across arg eval and invoke
function mk(a, b) { return { sum: a + b, prod: a * b }; }
var t = 0;
for (var i = 0; i < 2000; i++) { var r = mk(i, i + 1); t += r.sum + r.prod; }
out.push("t=" + t);
// compound assignment: base pinned across RHS eval
var box = { n: 0 };
for (var i = 0; i < 2500; i++) box.n += i;
out.push("box=" + box.n);
// index base pinning
var grid = [];
for (var i = 0; i < 50; i++) { grid.push([]); for (var j = 0; j < 50; j++) grid[i].push(i * j); }
var g = 0;
for (var i = 0; i < 50; i++) for (var j = 0; j < 50; j++) g += grid[i][j];
out.push("g=" + g);
// template literal accumulator pinning
var tpl = "";
for (var i = 0; i < 6; i++) tpl = `${tpl}[${i}:${i * i}]`;
out.push("tpl=" + tpl);
// for-of iterator + element pinning, switch discriminant pinning
var arr = [1, 2, 3, 4, 5, 6, 7, 8, 9];
var sw = 0;
for (var k = 0; k < 300; k++) {
  for (var v of arr) {
    switch (v % 3) { case 0: sw += 100; break; case 1: sw += v; break; default: sw += v * 2; }
  }
}
out.push("sw=" + sw);
// recursion holding live values across allocating calls (kept shallow so the
// bump-only env arena — not reclaimed in Phase 1 — is not exhausted)
function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }
out.push("fib=" + fib(18));
console.log(out.join(" | "));
EOF

base="$OUT/js_gc_stress.base"
strs="$OUT/js_gc_stress.stress"
"$BIN" "$js" > "$base" 2>&1;                      rc_base=$?
HAMNIX_JS_GC_STRESS=1 "$BIN" "$js" > "$strs" 2>&1; rc_str=$?

fail=0
if [ "$rc_base" -ne 0 ]; then echo "[js-gc-stress] FAIL: non-stress run exited $rc_base: $(tail -1 "$base")"; fail=1; fi
if [ "$rc_str" -ne 0 ]; then echo "[js-gc-stress] FAIL: stress run exited $rc_str: $(tail -1 "$strs")"; fail=1; fi

WANT="acc=8994000 | s=1124250,1125750,1123875250 | t=2670666000 | box=3123750 | g=1500625 | tpl=[0:0][1:1][2:4][3:9][4:16][5:25] | sw=102600 | fib=2584"
if [ "$(cat "$base")" != "$WANT" ]; then
    echo "[js-gc-stress] FAIL: non-stress output unexpected"; echo "  got:  $(cat "$base")"; echo "  want: $WANT"; fail=1
fi
if ! diff -q "$base" "$strs" >/dev/null; then
    echo "[js-gc-stress] FAIL: stress output DIFFERS from non-stress (a root pin is missing)"
    echo "  base:   $(cat "$base")"; echo "  stress: $(cat "$strs")"; fail=1
else
    echo "[js-gc-stress] PASS: stress run byte-identical to non-stress and matches expected"
fi

if [ "$fail" -eq 0 ]; then
    echo "[js-gc-stress] RESULT: PASS"; exit 0
else
    echo "[js-gc-stress] RESULT: FAIL"; exit 1
fi
