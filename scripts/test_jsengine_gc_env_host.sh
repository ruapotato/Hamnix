#!/usr/bin/env bash
# scripts/test_jsengine_gc_env_host.sh — QEMU-free gate for Phase-3 GC: the
# ENV (scope) arena is now RECLAIMED by a mark-sweep collector (mirroring the
# Phase-1/2 value collector's soundness model), lifting the hard 80,000-env
# ceiling that bump-only allocation imposed on env-heavy / deeply-recursive JS.
#
# Every active call/block/loop/catch/switch env is pinned on an env_root stack
# at its env_new site (env_push/env_popto), so the collector can free a dead
# scope but NEVER a live one — a live-free would corrupt execution (worse than a
# leak). This gate proves three things a missed pin or an incomplete root set
# would each fail:
#
#   PART A — CEILING. A callback loop invokes a function 300,000 times (300,000
#     distinct call scopes — FAR past the old 80,000-env cap, with a bounded
#     live set). Before Phase-3 this died with "environment pool exhausted";
#     now it COMPLETES with the exact correct result. Ditto a for-of driving a
#     large iteration (one block scope per element).
#   PART B — RETAINED CLOSURES (no live-free). Build many closures that CAPTURE
#     a live per-iteration variable, force gc() (which now sweeps envs too),
#     then invoke EVERY closure and assert each still sees its captured value.
#     If the collector freed a still-referenced scope, the read-back mismatches.
#   PART C — PER-CONSTRUCT BYTE-IDENTITY under HAMNIX_JS_GC_STRESS=1 (an env
#     collection fires roughly every ~16 env allocations, i.e. BETWEEN and
#     DURING scopes): deep recursion, let-per-iteration for-loops, generators,
#     async, try/catch, and switch each produce output byte-identical to the
#     non-stress run and to the hand-computed expected string.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-gc-env] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_gc_env_compile.log"; then
    echo "[js-gc-env] FAIL: host driver did not compile"; cat "$OUT/js_gc_env_compile.log"; exit 1
fi

fail=0

# ---------------------------------------------------------------------------
# PART A — env-arena CEILING: >80,000 distinct scopes must now complete.
# ---------------------------------------------------------------------------
# 300,000 function calls = 300,000 distinct call scopes (each dead after return,
# only one live at a time). sum over step() of s->s+1 from 0 is 300000.
# A braceless for-loop over a `var` induction adds no per-iteration block scope,
# so the pressure is purely the per-call callenv the collector must reclaim.
NCALL=300000
ceil="$OUT/js_gc_env_ceil.js"
cat > "$ceil" <<EOF
function step(x) { var y = x + 1; return y; }
var s = 0;
for (var i = 0; i < $NCALL; i++) s = step(s);
// for-of over a large array: one block scope per element (also >80k).
var arr = [];
for (var k = 0; k < 120000; k++) arr.push(k);
var t = 0;
for (var v of arr) { t = t + (v & 1); }
console.log("ENVCEIL s=" + s + " t=" + t);
EOF
WANT_CEIL="ENVCEIL s=$NCALL t=$(python3 -c 'print(sum(k & 1 for k in range(120000)))')"
cbase="$OUT/js_gc_env_ceil.base"; cstr="$OUT/js_gc_env_ceil.stress"
"$BIN" "$ceil" > "$cbase" 2>&1;                      rc_cb=$?
HAMNIX_JS_GC_STRESS=1 "$BIN" "$ceil" > "$cstr" 2>&1; rc_cs=$?
if [ "$rc_cb" -ne 0 ]; then echo "[js-gc-env] FAIL: ceiling run exited $rc_cb (env exhaustion?): $(tail -1 "$cbase")"; fail=1; fi
if [ "$rc_cs" -ne 0 ]; then echo "[js-gc-env] FAIL: ceiling stress run exited $rc_cs: $(tail -1 "$cstr")"; fail=1; fi
if ! grep -qF "$WANT_CEIL" "$cbase"; then
    echo "[js-gc-env] FAIL: ceiling output wrong"; echo "  got:  $(tail -1 "$cbase")"; echo "  want: $WANT_CEIL"; fail=1
elif ! diff -q "$cbase" "$cstr" >/dev/null; then
    echo "[js-gc-env] FAIL: ceiling output DIFFERS under env-GC stress (a scope pin is missing)"; fail=1
else
    echo "[js-gc-env] PASS: $NCALL-scope callback loop + 120k for-of scopes completed (>80k env ceiling lifted)"
fi

# ---------------------------------------------------------------------------
# PART B — RETAINED CLOSURES: forced gc() must not free a captured scope.
# ---------------------------------------------------------------------------
ret="$OUT/js_gc_env_ret.js"
cat > "$ret" <<'EOF'
// Each closure captures its own per-iteration `k` in a fresh call scope.
var fns = [];
for (var i = 0; i < 6000; i++) { (function (k) { fns.push(function () { return k * 3 + 1; }); })(i); }
// let-per-iteration also captures a distinct binding per turn.
var lets = [];
for (let j = 0; j < 500; j++) lets.push(function () { return j; });
// Force collections: the env sweep must retain every scope a live closure holds.
gc(); gc(); gc();
var ok = 1, checked = 0;
for (var i = 0; i < fns.length; i++) { if (fns[i]() !== i * 3 + 1) ok = 0; checked++; }
// Per-iteration `let` captures j as 0..N-1, which is what node prints for the
// same loop (verified: `for (let j=0;j<500;j++) …` sums to 124750, not 125250).
// The engine used to be off by one here and the gate's constant was pinned to
// that quirk; the binding was fixed without the constant following, leaving a
// stale red. The POINT of this gate is still that the value is base==stress and
// survives GC — it just now agrees with a real engine as well.
var lsum = 0; for (var i = 0; i < lets.length; i++) lsum += lets[i]();
// Churn a lot of throwaway scopes, force gc() again, re-verify the retained set.
function churn(n) { var a = n; if (n > 0) return churn(n - 1); return a; }
for (var i = 0; i < 40000; i++) churn(2);
gc();
for (var i = 0; i < fns.length; i++) if (fns[i]() !== i * 3 + 1) ok = 0;
console.log("RETAIN ok=" + ok + " checked=" + checked + " lsum=" + lsum);
EOF
WANT_RET="RETAIN ok=1 checked=6000 lsum=$(python3 -c 'print(sum(range(0,500)))')"
rbase="$OUT/js_gc_env_ret.base"; rstr="$OUT/js_gc_env_ret.stress"
"$BIN" "$ret" > "$rbase" 2>&1;                      rc_rb=$?
HAMNIX_JS_GC_STRESS=1 "$BIN" "$ret" > "$rstr" 2>&1; rc_rs=$?
if [ "$rc_rb" -ne 0 ] || [ "$rc_rs" -ne 0 ]; then echo "[js-gc-env] FAIL: retain run exited ($rc_rb/$rc_rs): $(tail -1 "$rbase")"; fail=1; fi
if ! grep -qF "$WANT_RET" "$rbase"; then
    echo "[js-gc-env] FAIL: retained-closure mismatch (a live scope was freed)"; echo "  got:  $(tail -1 "$rbase")"; echo "  want: $WANT_RET"; fail=1
elif ! diff -q "$rbase" "$rstr" >/dev/null; then
    echo "[js-gc-env] FAIL: retained-closure output DIFFERS under env-GC stress"; fail=1
else
    echo "[js-gc-env] PASS: 6000 captured closures + 500 let-bindings intact across forced GC + 40k-scope churn"
fi

# ---------------------------------------------------------------------------
# PART C — PER-CONSTRUCT byte-identity under env-GC stress.
# Recursion depth stays well under the Phase-1 VALUE pin-stack cap (GC_ROOT_CAP,
# unrelated to the env arena); this gate targets env reclamation, not that cap.
# ---------------------------------------------------------------------------
constructs="$OUT/js_gc_env_constructs.js"
cat > "$constructs" <<'EOF'
var out = [];
// deep-ish recursion: 1200 nested call scopes (all live simultaneously, pinned).
function tri(n) { if (n === 0) return 0; var local = n; return local + tri(n - 1); }
out.push("rec=" + tri(1200));
// let-per-iteration for-loops (fresh block scope per turn, captured).
var g = []; for (let j = 0; j < 200; j++) g.push(function () { return j * j; });
var gs = 0; for (var i = 0; i < g.length; i++) gs += g[i]();
out.push("let=" + gs);
// generators (eager body runs in its own call scope).
function* seq() { for (var i = 0; i < 6; i++) yield i * 2; }
var acc = ""; for (var v of seq()) acc += v + ","; out.push("gen=" + acc);
// async/await drains the microtask queue synchronously.
async function af(x) { return x + 1; }
var apr = 0; af(41).then(function (r) { apr = r; }); out.push("async=" + apr);
// try/catch/switch churn: many catch + switch scopes.
var cnt = 0;
for (var i = 0; i < 3000; i++) {
  try { if (i % 5 === 0) throw i; } catch (e) { cnt++; }
  switch (i % 4) { case 0: cnt += 1; break; case 1: cnt += 2; break; default: break; }
}
out.push("cs=" + cnt);
// nested blocks with let (block scopes stacked).
var bsum = 0; { let a = 1; { let b = 2; { let c = 3; bsum = a + b + c; } } }
out.push("blk=" + bsum);
console.log(out.join(" | "));
EOF
# async resolves on the NEXT microtask turn, so `apr` is still 0 at the log point
# (deterministic in this engine) — asserted as-is to lock the exact behavior.
WANT_C="rec=720600 | let=$(python3 -c 'print(sum(j*j for j in range(0,200)))') | gen=0,2,4,6,8,10, | async=0 | cs=$(python3 -c '
cnt=0
for i in range(3000):
  if i%5==0: cnt+=1
  m=i%4
  if m==0: cnt+=1
  elif m==1: cnt+=2
print(cnt)') | blk=6"
xbase="$OUT/js_gc_env_c.base"; xstr="$OUT/js_gc_env_c.stress"
"$BIN" "$constructs" > "$xbase" 2>&1;                      rc_xb=$?
HAMNIX_JS_GC_STRESS=1 "$BIN" "$constructs" > "$xstr" 2>&1; rc_xs=$?
if [ "$rc_xb" -ne 0 ] || [ "$rc_xs" -ne 0 ]; then echo "[js-gc-env] FAIL: constructs run exited ($rc_xb/$rc_xs): $(tail -1 "$xbase")"; fail=1; fi
if [ "$(cat "$xbase")" != "$WANT_C" ]; then
    echo "[js-gc-env] FAIL: constructs output wrong"; echo "  got:  $(cat "$xbase")"; echo "  want: $WANT_C"; fail=1
elif ! diff -q "$xbase" "$xstr" >/dev/null; then
    echo "[js-gc-env] FAIL: per-construct output DIFFERS under env-GC stress (a scope pin is missing)"
    echo "  base:   $(cat "$xbase")"; echo "  stress: $(cat "$xstr")"; fail=1
else
    echo "[js-gc-env] PASS: recursion/let-loops/generators/async/try-catch/switch/blocks byte-identical under env-GC stress"
fi

if [ "$fail" -eq 0 ]; then
    echo "[js-gc-env] RESULT: PASS"; exit 0
else
    echo "[js-gc-env] RESULT: FAIL"; exit 1
fi
