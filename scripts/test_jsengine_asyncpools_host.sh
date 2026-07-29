#!/usr/bin/env bash
# scripts/test_jsengine_asyncpools_host.sh — FAST, QEMU-free gate over the three
# ASYNC pools of the JS engine: the deferred-callback (timer/microtask/rAF)
# queue, the promise-reaction records, and the Map/Set entry pool.
#
# WHY THIS GATE EXISTS
# ====================
# All three pools were BUMP-ONLY, so "how many did this page ever make" was the
# ceiling — and every one of them crossed it in SILENCE:
#
#   * A self-rescheduling setTimeout chain — the shape of every async SPA render
#     loop — stopped dead at exactly TIMER_CAP = 4,096 turns. timer_schedule just
#     `return`ed 0. No error, no note: the page simply stopped updating.
#   * A Promise.then chain stopped the same way at PROM_REACT_CAP, handing the
#     page a promise that could never settle.
#   * A Map-per-turn loop exhausted MS_CAP, after which m.set(k, v) was a silent
#     no-op and the next m.get(k) read undefined.
#
# That is the DOM_MAX / emit_c / argv-64 bug class: a ceiling that cannot report
# itself. The user's bar for this engine is "months or even years without a
# reboot", so a page that stops repainting after a few thousand ticks with
# nothing said is the single worst failure shape available.
#
# WHAT IT ASSERTS
# ===============
#  1. TURN CEILINGS, measured: a setTimeout loop, a .then chain and a
#     Map-per-turn loop each run FAR past their old caps (4,096 / 4,096 /
#     65,536 for the 2-entry Map used here).
#  2. OCCUPANCY: the loops run with a handful of slots LIVE and hundreds of
#     thousands RECYCLED, and zero overflow — i.e. reuse, not a bigger pool.
#  3. LOUDNESS: with every slot genuinely occupied at once, each of the three
#     pools emits its CEILING note and a catchable engine error, where the
#     pre-fix engine reported success while dropping the work.
#  4. RETENTION, adversarially: an interval that re-arms its own slot and then
#     cancels itself from inside; a stale id that must NOT cancel the
#     registration that inherited its slot; a reaction id living inside a
#     timer's args across 5,000 slot recycles; a promise resolved after its
#     reaction was queued; nested then-chains; a cancelled rAF.
#  5. NO LIVE-FREE: a live Map, a live pending timer and a 200-link live promise
#     chain all survive heavy churn of their dead peers plus a forced gc(), and
#     the whole suite is byte-identical under HAMNIX_JS_GC_STRESS=1.
#  6. An abandoned pending promise carrying a .then is COLLECTABLE (it used to
#     be immortal: the record rooted the promise that rooted the record).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-asyncpools] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_asyncpools_compile.log"; then
    echo "[js-asyncpools] FAIL: host driver did not compile"; cat "$OUT/js_asyncpools_compile.log"; exit 1
fi

fail=0
D="$OUT/asyncpools"
rm -rf "$D"; mkdir -p "$D"

ok() { echo "[js-asyncpools] PASS $1"; }
bad() { echo "[js-asyncpools] FAIL $1"; fail=1; }

# ---------------------------------------------------------------- 1 + 2 -------
# TURN CEILINGS. Each loop is bounded by its own counter (N), so reaching N is
# the proof that the POOL is no longer the bound. HAMNIX_JS_DRAIN_CAP=0 lifts the
# per-drain fairness budget (which is not a capacity limit: it leaves its tasks
# queued for the next drain) so the measurement sees the slot ceiling itself.
N=200000

cat > "$D/timerloop.js" <<EOF
var n = 0;
function tick() { n = n + 1; if (n < $N) setTimeout(tick, 0); else console.log("TIMERTURNS=" + n); }
setTimeout(tick, 0);
EOF
HAMNIX_JS_ARENA_STATS=1 HAMNIX_JS_DRAIN_CAP=0 timeout 300 "$BIN" "$D/timerloop.js" \
    >"$D/timerloop.out" 2>"$D/timerloop.stat"
if grep -q "^TIMERTURNS=$N\$" "$D/timerloop.out"; then
    ok "setTimeout chain reached $N turns (was capped at 4096 = TIMER_CAP)"
else
    bad "setTimeout chain did not reach $N turns: $(tail -2 "$D/timerloop.out" | tr '\n' ' ')"
fi
# Occupancy: a self-rescheduling chain holds ~1 slot at a time, so the run must
# be almost entirely RECYCLED, with nothing dropped.
tstat=$(tr ' ' '\n' <"$D/timerloop.stat" | grep -E "^(timerhi|timerrecyc|timerovf)=" | tr '\n' ' ')
thi=$(tr ' ' '\n' <"$D/timerloop.stat" | sed -n 's/^timerhi=//p')
trec=$(tr ' ' '\n' <"$D/timerloop.stat" | sed -n 's/^timerrecyc=//p')
tovf=$(tr ' ' '\n' <"$D/timerloop.stat" | sed -n 's/^timerovf=//p')
if [ -n "$thi" ] && [ "$thi" -le 16 ] && [ "$trec" -ge $((N - 100)) ] && [ "$tovf" = "0" ]; then
    ok "timer occupancy is reuse not capacity ($tstat)"
else
    bad "timer occupancy unexpected (want timerhi<=16, timerrecyc>=$((N - 100)), timerovf=0): $tstat"
fi

# A .then chain. The reaction pool no longer bounds it; what bounds it now is the
# OBJECT arena, because every native call (including the microtask body that runs
# a reaction) still runs with the Phase-1 GC suppressed — a separate, LOUD
# ceiling ("object pool exhausted") owned by the GC-rooting track. So assert past
# PROM_REACT_CAP rather than to N, and assert the recycling directly.
cat > "$D/thenchain.js" <<'EOF'
var n = 0;
function step() { n = n + 1; if (n % 512 === 0) console.log("P=" + n); Promise.resolve().then(step); }
Promise.resolve().then(step);
EOF
HAMNIX_JS_ARENA_STATS=1 HAMNIX_JS_DRAIN_CAP=0 timeout 300 "$BIN" "$D/thenchain.js" \
    >"$D/thenchain.out" 2>"$D/thenchain.stat"
pturns=$(sed -n 's/^P=//p' "$D/thenchain.out" | tail -1)
prec=$(tr ' ' '\n' <"$D/thenchain.stat" | sed -n 's/^prrecyc=//p')
phi=$(tr ' ' '\n' <"$D/thenchain.stat" | sed -n 's/^prhi=//p')
povf=$(tr ' ' '\n' <"$D/thenchain.stat" | sed -n 's/^provf=//p')
if [ -n "$pturns" ] && [ "$pturns" -gt 16384 ]; then
    ok ".then chain reached $pturns turns, past PROM_REACT_CAP=16384 (was capped at 4096)"
else
    bad ".then chain stopped at '$pturns' turns (want > 16384): $(tail -2 "$D/thenchain.out" | tr '\n' ' ')"
fi
if [ -n "$prec" ] && [ "$prec" -gt 16384 ] && [ "$phi" -le 16 ] && [ "$povf" = "0" ]; then
    ok "reaction records recycle (prrecyc=$prec, prhi=$phi, provf=$povf)"
else
    bad "reaction occupancy unexpected (want prrecyc>16384, prhi<=16, provf=0): prrecyc=$prec prhi=$phi provf=$povf"
fi

# A Map per turn (2 entries each): 65,536 turns before, the loop bound after.
cat > "$D/maploop.js" <<EOF
var n = 0;
for (var i = 0; i < $N; i++) {
  var m = new Map();
  m.set("a", i); m.set("b", i + 1);
  if (m.get("a") !== i || m.get("b") !== i + 1 || m.size !== 2) throw new Error("map lost data at turn " + i);
  n = n + 1;
}
console.log("MAPTURNS=" + n);
EOF
HAMNIX_JS_ARENA_STATS=1 timeout 300 "$BIN" "$D/maploop.js" >"$D/maploop.out" 2>"$D/maploop.stat"
if grep -q "^MAPTURNS=$N\$" "$D/maploop.out"; then
    ok "Map-per-turn loop reached $N turns (was capped at 65536 = MS_CAP/2)"
else
    bad "Map-per-turn loop did not reach $N turns: $(tail -2 "$D/maploop.out" | tr '\n' ' ')"
fi
mrec=$(tr ' ' '\n' <"$D/maploop.stat" | sed -n 's/^mserecyc=//p')
movf=$(tr ' ' '\n' <"$D/maploop.stat" | sed -n 's/^mseovf=//p')
if [ -n "$mrec" ] && [ "$mrec" -gt 100000 ] && [ "$movf" = "0" ]; then
    ok "Map/Set entries recycle (mserecyc=$mrec, mseovf=$movf)"
else
    bad "Map/Set entry occupancy unexpected (want mserecyc>100000, mseovf=0): mserecyc=$mrec mseovf=$movf"
fi

# ---------------------------------------------------------------- 3 -----------
# LOUDNESS. Each case occupies a whole pool SIMULTANEOUSLY (nothing to recycle),
# which is the one genuine capacity wall left. Each must name itself and raise a
# catchable error; the pre-fix engine printed a success line instead.
cat > "$D/loud_timer.js" <<'EOF'
var n = 0;
for (var i = 0; i < 5000; i++) { setTimeout(function () {}, 1000); n = n + 1; }
console.log("REGISTERED=" + n);
EOF
cat > "$D/loud_pr.js" <<'EOF'
var p = new Promise(function () {});      // never settles: every record stays outstanding
for (var i = 0; i < 20000; i++) p.then(function () {});
console.log("REGISTERED");
EOF
cat > "$D/loud_mse.js" <<'EOF'
// LIVE maps, 4 entries each, so nothing is reclaimable and ms_find stays cheap.
var keep = [];
for (var i = 0; i < 34000; i++) {
  var m = new Map();
  m.set("a", i); m.set("b", i); m.set("c", i); m.set("d", i);
  keep.push(m);
}
console.log("INSERTED");
EOF
check_loud() {
    local name="$1" js="$2" want="$3"
    timeout 300 "$BIN" "$js" >"$D/$name.out" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        bad "$name: engine exited 0 — the pool filled SILENTLY: $(tail -1 "$D/$name.out")"
    elif ! grep -q "$want" "$D/$name.out"; then
        bad "$name: no CEILING report naming the pool: $(tail -2 "$D/$name.out" | tr '\n' ' ')"
    else
        ok "$name reports its ceiling instead of dropping work silently"
    fi
}
check_loud loud_timer "$D/loud_timer.js" "CEILING timer table full"
check_loud loud_pr    "$D/loud_pr.js"    "CEILING promise reaction pool full"
check_loud loud_mse   "$D/loud_mse.js"   "CEILING Map/Set entry pool full"

# The per-drain fairness budget is a DIFFERENT thing (it loses no work) but it
# was equally silent. It must announce itself too.
cat > "$D/loud_drain.js" <<'EOF'
function tick() { setTimeout(tick, 0); }
setTimeout(tick, 0);
console.log("ARMED");
EOF
timeout 300 "$BIN" "$D/loud_drain.js" >"$D/loud_drain.out" 2>&1
if grep -q "drain hit its per-turn invocation budget" "$D/loud_drain.out"; then
    ok "a truncated drain says so (endless setTimeout chain)"
else
    bad "a truncated drain was SILENT: $(tail -2 "$D/loud_drain.out" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- 4 -----------
# ADVERSARIAL RETENTION. Slot reuse introduces two hazards a bump-only table
# could not have: an id that outlives its registration (ABA), and a slot whose
# callback is ON THE STACK being handed to a new registration mid-flight.
cat > "$D/adversarial.js" <<'EOF'
// A1 — an interval re-arms its OWN slot, then cancels itself from inside and
//      immediately schedules a new timer: the slot must NOT be handed over
//      while run_one_task is still holding it.
var iv_n = 0, iv_id = setInterval(function () {
  iv_n++;
  if (iv_n === 5) { clearInterval(iv_id); setTimeout(function () { console.log("A1 after-self-clear iv_n=" + iv_n); }, 0); }
}, 1);
// A2 — a stale id must NOT cancel the registration that inherits the slot.
var dead = setTimeout(function () { console.log("A2 FAIL dead timer ran"); }, 0);
clearTimeout(dead);                       // frees the slot immediately
var live = setTimeout(function () { console.log("A2 live ran"); }, 0);
clearTimeout(dead);                       // stale id: must be a no-op
if (dead === live) console.log("A2 FAIL id reused verbatim: " + dead);
// A3 — a one-shot's own, already-retired id must not cancel its successor.
var once = setTimeout(function () {
  var later = setTimeout(function () { console.log("A3 later ran"); }, 0);
  clearTimeout(once);
  if (once === later) console.log("A3 FAIL slot id collision");
}, 0);
// A4 — a reaction id travels inside a timer's args: interleave reactions and
//      timers so both kinds of slot churn together.
var r4 = [];
for (var i = 0; i < 3; i++) (function (k) {
  Promise.resolve(k).then(function (v) { r4.push("p" + v); setTimeout(function () { r4.push("t" + v); }, 0); });
})(i);
setTimeout(function () { console.log("A4 " + r4.join(",")); }, 1);
// A5 — a promise resolved AFTER its reaction was queued (deferred resolver).
var res5; var p5 = new Promise(function (r) { res5 = r; });
p5.then(function (v) { console.log("A5 late-resolve " + v); });
setTimeout(function () { res5("ok"); }, 0);
// A6 — nested then chains, each level registering while the outer one runs.
Promise.resolve(1)
  .then(function (v) { return Promise.resolve(v + 1).then(function (w) { return w + 1; }); })
  .then(function (v) { return new Promise(function (r) { setTimeout(function () { r(v * 10); }, 0); }); })
  .then(function (v) { console.log("A6 nested " + v); });
// A7 — a one-shot cancelled while pending, from another callback.
var victim = setTimeout(function () { console.log("A7 FAIL victim ran"); }, 5);
setTimeout(function () { clearTimeout(victim); console.log("A7 victim cancelled"); }, 0);
// A8 — an INTERVAL cancelled while pending, before it ever fired.
var iv8 = setInterval(function () { console.log("A8 FAIL interval fired"); }, 10);
setTimeout(function () { clearInterval(iv8); console.log("A8 pending interval cancelled"); }, 0);
// A9 — rAF ids share the timer table: cancel one, then reuse the slot.
var f9 = requestAnimationFrame(function () { console.log("A9 FAIL cancelled frame ran"); });
cancelAnimationFrame(f9);
requestAnimationFrame(function () { console.log("A9 frame ran"); });
// A10 — a QUEUED microtask carries its reaction id as a number in a timer arg.
//       Recycle 5,000 timer slots underneath it; the reaction must still run.
var r10; var p10 = new Promise(function (r) { r10 = r; });
p10.then(function (v) { console.log("A10 reaction-after-churn " + v); });
r10("kept");
for (var i = 0; i < 5000; i++) { var d = setTimeout(function () {}, 0); clearTimeout(d); }
EOF
cat > "$D/adversarial.want" <<'EOF'
A10 reaction-after-churn kept
A2 live ran
A5 late-resolve ok
A7 victim cancelled
A8 pending interval cancelled
A6 nested 30
A3 later ran
A4 p0,p1,p2,t0,t1,t2
A1 after-self-clear iv_n=5
A9 frame ran
EOF
timeout 300 "$BIN" "$D/adversarial.js" >"$D/adversarial.out" 2>&1
if diff -u "$D/adversarial.want" "$D/adversarial.out" >"$D/adversarial.diff"; then
    ok "10 adversarial retention cases (self-clearing interval, stale ids, queued reaction across churn)"
else
    bad "adversarial retention output differs:"; sed -n '1,30p' "$D/adversarial.diff"
fi

# ---------------------------------------------------------------- 5 + 6 -------
# NO LIVE-FREE. A collector (or free list) that hands out a slot something still
# refers to corrupts silently, so each pool gets a LIVE holder that must read
# back exactly across heavy churn of its dead peers plus a forced gc().
cat > "$D/liveretain.js" <<'EOF'
// L1 — a LIVE Map's entries survive the recycling of DEAD Maps' entries.
var keep = new Map();
for (var i = 0; i < 64; i++) keep.set("k" + i, i * 3);
for (var j = 0; j < 60000; j++) { var t = new Map(); t.set("x", j); t.set("y", j); }
if (typeof gc === "function") gc();
var ok1 = keep.size === 64;
for (var i = 0; i < 64; i++) if (keep.get("k" + i) !== i * 3) ok1 = false;
console.log("L1 live-map-intact=" + ok1 + " size=" + keep.size);
// L2 — a LIVE pending timer survives 60,000 alloc/free cycles + a forced GC.
var survived = false;
setTimeout(function () { survived = true; }, 100);
for (var j = 0; j < 60000; j++) { var d = setTimeout(function () {}, 0); clearTimeout(d); }
if (typeof gc === "function") gc();
setTimeout(function () { console.log("L2 live-timer-survived=" + survived); }, 200);
// L3 — a 200-link LIVE promise chain resolves correctly while thousands of
//      ABANDONED promises (each with a registered .then whose source can never
//      settle) are collected out from under it.
var chain = Promise.resolve(0);
for (var i = 0; i < 200; i++) chain = chain.then(function (v) {
  for (var k = 0; k < 20; k++) { var junk = new Promise(function () {}); junk.then(function () {}); }
  return v + 1;
});
chain.then(function (v) { console.log("L3 live-chain=" + v); });
EOF
cat > "$D/liveretain.want" <<'EOF'
L1 live-map-intact=true size=64
L3 live-chain=200
L2 live-timer-survived=true
EOF
timeout 300 "$BIN" "$D/liveretain.js" >"$D/liveretain.out" 2>&1
if diff -u "$D/liveretain.want" "$D/liveretain.out" >"$D/liveretain.diff"; then
    ok "live Map / live pending timer / 200-link live chain all survive churn + gc()"
else
    bad "a LIVE holder was corrupted by slot reuse:"; sed -n '1,20p' "$D/liveretain.diff"
fi
# Same run with a collection forced every few allocations: the strongest shakeout
# available for a missing root, and it must be byte-identical.
HAMNIX_JS_GC_STRESS=1 timeout 600 "$BIN" "$D/liveretain.js" >"$D/liveretain.stress" 2>&1
if cmp -s "$D/liveretain.out" "$D/liveretain.stress"; then
    ok "byte-identical under HAMNIX_JS_GC_STRESS=1"
else
    bad "GC stress changed the result (missing root):"; diff -u "$D/liveretain.out" "$D/liveretain.stress" | sed -n '1,20p'
fi

# An abandoned pending promise carrying a .then used to be IMMORTAL: the record
# rooted the promise (pr_source, scanned wholesale) and the promise rooted the
# record (prom_react). 100k of them died at ~4,000 with "object pool exhausted".
cat > "$D/abandoned.js" <<'EOF'
for (var i = 0; i < 100000; i++) { var p = new Promise(function () {}); p.then(function () {}); }
console.log("ABANDONED_OK");
EOF
HAMNIX_JS_ARENA_STATS=1 timeout 300 "$BIN" "$D/abandoned.js" >"$D/abandoned.out" 2>"$D/abandoned.stat"
arec=$(tr ' ' '\n' <"$D/abandoned.stat" | sed -n 's/^prrecyc=//p')
if grep -q "^ABANDONED_OK\$" "$D/abandoned.out" && [ -n "$arec" ] && [ "$arec" -gt 50000 ]; then
    ok "100k abandoned pending promises with .then are collectable (prrecyc=$arec)"
else
    bad "abandoned pending promises still leak: $(tail -1 "$D/abandoned.out") prrecyc=$arec"
fi

if [ "$fail" -eq 0 ]; then
    echo "[js-asyncpools] RESULT: PASS"; exit 0
else
    echo "[js-asyncpools] RESULT: FAIL"; exit 1
fi
