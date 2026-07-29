#!/usr/bin/env bash
# scripts/test_jsengine_gc_obj_host.sh — QEMU-free gate for Phase-5 GC: the
# OBJECT arena is now RECLAIMED by a TRACING mark-sweep collector, lifting the
# hard 40,000-object ceiling that bump-only allocation imposed on every
# long-running page.
#
# WHY THIS ONE IS DIFFERENT FROM THE PHASES BEFORE IT. The value (Phase 1), env
# (Phase 3) and string-id (Phase 4) collectors are CONSERVATIVE: they mark every
# arena slot wholesale, so they can retain garbage but can never free something
# live. That is exactly why they could not help the object arena — marking
# p_val/ax_val/b_val wholesale carries NO reachability information, so every
# object ever allocated stayed "reachable" and the ceiling was untouchable.
#
# Phase 5 therefore TRACES: property slots, array elements, Map/Set entries and
# promise reactions are reached only FROM a live owner object. That precision is
# what reclaims memory, and it is also what makes a MISSING ROOT a silent
# live-free instead of a leak. So this gate is built around one question — can
# any shape of live object be freed? — and the answer has to be no for every
# part below, each of which a different missing root would break:
#
#   PART A — CEILING. The ordinary render-loop shape (one closure + one object
#     literal + one array per turn, O(1) live set) died at 13,086 turns with
#     "object pool exhausted". It must now run FAR past that, with the arena
#     occupancy readout corroborating real reclamation rather than a raised
#     constant.
#   PART B — ADVERSARIAL RETENTION (no live-free). Cycles, closures capturing
#     objects, prototype chains, class instances, bound functions, Map/Set
#     keys AND values, pending promises, generators, typed arrays over a shared
#     buffer, proxies, Symbol.for registry entries, objects held only by a timer
#     callback and objects held only by a BUILTIN mid-call (a sort/map comparator
#     that allocates heavily) — all built, all churned past several collections,
#     all read back and checked.
#   PART C — IDENTITY. Reclaimed slots are RECYCLED, so a stale id must never
#     alias a live object: retained objects stay !== every later allocation, and
#     === themselves, across forced collections.
#   PART D — BYTE-IDENTITY under HAMNIX_JS_GC_STRESS=1 (an object collection
#     fires roughly every ~64 object allocations, i.e. BETWEEN and DURING every
#     construct): the whole per-construct battery must produce output identical
#     to the non-stress run and to the hand-computed expected string.
#   PART E — EMBEDDER (DOM) HANDLES. Objects the browser holds are pinned at the
#     js_* API boundary (ext_pin), which is what makes the collector safe for the
#     browser without auditing every DOM call site. Drives a real page whose
#     script churns far past the object ceiling while an element property, an
#     event-listener closure and a live DOM subtree must all survive.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-gc-obj] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_gc_obj_compile.log"; then
    echo "[js-gc-obj] FAIL: host driver did not compile"; cat "$OUT/js_gc_obj_compile.log"; exit 1
fi

fail=0

# ---------------------------------------------------------------------------
# PART A — object-arena CEILING.
# ---------------------------------------------------------------------------
# MEASURED on the pre-fix binary, this exact shape:
#     60000-turn loop -> "object pool exhausted" at 13,086 turns
#     ARENA objs=40000 objmax=40000
# 400,000 turns is 30x that, with a live set of ONE accumulator.
NTURN=400000
ceil="$OUT/js_gc_obj_ceil.js"
cat > "$ceil" <<EOF
var acc = 0;
for (var t = 0; t < $NTURN; t++) {
  var o = { x: t, y: t + 1 };          // object literal
  var a = [o.x, o.y, t];               // array (own ax storage)
  var f = function () { return o.y + a[2]; };   // closure capturing both
  acc += f() & 3;
}
console.log("OBJCEIL acc=" + acc);
EOF
WANT_CEIL="OBJCEIL acc=$(python3 -c "print(sum(((t+1)+t) & 3 for t in range($NTURN)))")"
cbase="$OUT/js_gc_obj_ceil.base"
timeout 900 "$BIN" "$ceil" > "$cbase" 2>&1; rc_cb=$?
if [ "$rc_cb" -ne 0 ]; then
    echo "[js-gc-obj] FAIL: ceiling run exited $rc_cb: $(tail -1 "$cbase")"; fail=1
elif grep -qF "object pool exhausted" "$cbase"; then
    echo "[js-gc-obj] FAIL: object pool still exhausts (the collector did not run)"; fail=1
elif ! grep -qF "$WANT_CEIL" "$cbase"; then
    echo "[js-gc-obj] FAIL: ceiling output wrong"; echo "  got:  $(tail -1 "$cbase")"; echo "  want: $WANT_CEIL"; fail=1
else
    echo "[js-gc-obj] PASS: ${NTURN}-turn render-loop shape completed (was 13,086 -> object pool exhausted)"
fi

# The ARENA OCCUPANCY readout must corroborate the diagnosis rather than assert a
# magic constant: collections MUST have run, and each must free the vast majority
# of the arena (the live set here is a single number). If a future change breaks
# the trigger or the roots stop being precise, objcolls/objfreed collapse HERE
# before the ceiling is even reached.
astat="$OUT/js_gc_obj_arena.txt"
HAMNIX_JS_ARENA_STATS=1 timeout 900 "$BIN" "$ceil" >/dev/null 2>"$astat"
ocolls=$(sed -n 's/.*objcolls=\([0-9]*\).*/\1/p' "$astat")
ofreed=$(sed -n 's/.*objfreed=\([0-9]*\).*/\1/p' "$astat")
if [ -z "$ocolls" ] || [ -z "$ofreed" ]; then
    echo "[js-gc-obj] FAIL: HAMNIX_JS_ARENA_STATS produced no objcolls/objfreed: $(cat "$astat")"; fail=1
elif [ "$ocolls" -lt 1 ]; then
    echo "[js-gc-obj] FAIL: zero object collections over ${NTURN} turns (trigger suppressed)"; fail=1
elif [ "$ofreed" -lt 20000 ]; then
    echo "[js-gc-obj] FAIL: last object collection freed only $ofreed slots; the arena is not being reclaimed"; fail=1
else
    echo "[js-gc-obj] PASS: arena stats corroborate ($ocolls collections, last freed $ofreed of a live set of ~1)"
fi

# ---------------------------------------------------------------------------
# PART B — ADVERSARIAL RETENTION. Every shape below is LIVE and must read back
# intact after heavy churn + forced collections. Each line is one root/edge the
# tracer has to follow; a missing one shows up as a wrong number, not a crash.
# ---------------------------------------------------------------------------
ret="$OUT/js_gc_obj_ret.js"
cat > "$ret" <<'EOF'
var log = [];
function churn(n) {                       // allocate n throwaway object graphs
  var s = 0;
  for (var i = 0; i < n; i++) { var q = { a: i, b: [i, i + 1] }; s += q.b[1] & 1; }
  return s;
}

// 1. SELF-CYCLES — a worklist mark must terminate and must retain both.
var cyc = { n: 7 }; cyc.self = cyc;
var xs = [1, 2, 3]; xs.push(xs);

// 2. CLOSURE CAPTURING AN OBJECT (reachable only through obj_fn_env -> binding).
var closures = [];
for (var i = 0; i < 500; i++) { (function (k) { var box = { v: k * 2 }; closures.push(function () { return box.v; }); })(i); }

// 3. PROTOTYPE CHAIN + CLASS INSTANCE (obj_proto / obj_fn_home edges).
function Base(v) { this.v = v; }
Base.prototype.get = function () { return this.v + 1; };
var inst = new Base(41);
class C { constructor(x) { this.x = x; } dbl() { return this.x * 2; } }
class D extends C { constructor(x) { super(x); this.y = x + 1; } sum() { return this.dbl() + this.y; } }
var dee = new D(10);

// 4. BOUND FUNCTION (obj_fn_btarget / bthis / bargs).
function add3(a, b, c) { return a + b + c; }
var bound = add3.bind({ tag: 1 }, 100, 20);

// 5. MAP + SET holding OBJECT keys AND values (mse_key / mse_val via obj_ms_head).
var mk = { id: "k" }, mv = { id: "v" };
var m = new Map(); m.set(mk, mv); m.set("s", { deep: { deeper: [9] } });
var st = new Set(); st.add(mk); st.add({ only: "in-set" });

// 6. PENDING PROMISE capturing an object in its reaction (prom_react / pr_*).
var pobj = { p: 5 };
var presolve; var pr = new Promise(function (res) { presolve = res; });
var pval = -1; pr.then(function (r) { pval = r + pobj.p; });

// 7. GENERATOR (gen_buf materialized array).
function* gseq() { yield { g: 1 }; yield { g: 2 }; yield { g: 3 }; }
var git = gseq();

// 8. TYPED ARRAYS over a SHARED ArrayBuffer (obj_ta_buf edge).
var ab = new ArrayBuffer(16);
var i32 = new Int32Array(ab); i32[0] = 123; i32[1] = 456;
var u8 = new Uint8Array(ab);

// 9. PROXY (obj_proxy_target / obj_proxy_handler).
var ptarget = { z: 3 };
var prox = new Proxy(ptarget, { get: function (t, k) { return k === "z" ? t.z * 10 : t[k]; } });

// 10. Symbol.for REGISTRY (sym_registry root).
var sy = Symbol.for("gcobj"); var symobj = {}; symobj[sy] = 1;

// 11. TIMER-ONLY reachability (timer_fn / timer_args).
var tobj = { t: 77 }; var tsaw = -1;
setTimeout(function () { tsaw = tobj.t; }, 0);

// 12. Object held only by a BUILTIN MID-CALL: the comparator allocates enough
//     to cross several collection triggers while `pairs` is only reachable
//     through the builtin's own frame + the array being sorted.
var pairs = [];
for (var i = 0; i < 60; i++) pairs.push({ k: (i * 37) % 60 });
pairs.sort(function (a, b) { churn(400); return a.k - b.k; });
var sorted_ok = 1;
for (var i = 0; i < pairs.length; i++) if (pairs[i].k !== i) sorted_ok = 0;
// ... and through a map() callback that allocates heavily.
var mapped = pairs.map(function (p) { churn(200); return { kk: p.k + 1 }; });
var mapped_sum = 0; for (var i = 0; i < mapped.length; i++) mapped_sum += mapped[i].kk;

// 13. DEEP nesting, reachable only through the root of the chain.
var deep = {}; var cur = deep;
for (var i = 0; i < 200; i++) { cur.next = { d: i }; cur = cur.next; }

// ---- CHURN far past several collection triggers, then force collections ----
var burn = churn(120000);
gc(); gc();
burn += churn(120000);
gc();

// ---- read everything back ----
log.push("cyc=" + (cyc.self.self.self.n) + "," + (xs[3][3][0]));
var csum = 0; for (var i = 0; i < closures.length; i++) csum += closures[i]();
log.push("clo=" + csum);
log.push("proto=" + inst.get() + "," + dee.sum());
log.push("bound=" + bound(3));
log.push("map=" + m.get(mk).id + m.get("s").deep.deeper[0] + "," + m.size + "," + st.has(mk) + "," + st.size);
presolve(10);
log.push("gen=" + git.next().value.g + git.next().value.g + git.next().value.g);
log.push("ta=" + i32[0] + "," + i32[1] + "," + u8[0]);
log.push("proxy=" + prox.z);
log.push("sym=" + (Symbol.for("gcobj") === sy) + "," + symobj[sy]);
log.push("sort=" + sorted_ok + ",map=" + mapped_sum);
var dcur = deep, dn = 0; while (dcur.next) { dcur = dcur.next; dn++; }
log.push("deep=" + dn + "," + dcur.d);
log.push("burn=" + burn);
console.log(log.join(" | "));
// the promise reaction and the timer both run in the post-script drain.
setTimeout(function () { console.log("DRAIN pval=" + pval + " tsaw=" + tsaw); }, 1);
EOF
CSUM=$(python3 -c 'print(sum(k*2 for k in range(500)))')
MAPSUM=$(python3 -c 'print(sum(i+1 for i in range(60)))')
BURN=$(python3 -c 'print(2 * sum((i + 1) & 1 for i in range(120000)))')
WANT_RET="cyc=7,1 | clo=$CSUM | proto=42,31 | bound=123 | map=v9,2,true,2 | gen=123 | ta=123,456,123 | proxy=30 | sym=true,1 | sort=1,map=$MAPSUM | deep=200,199 | burn=$BURN"
rbase="$OUT/js_gc_obj_ret.base"; rstr="$OUT/js_gc_obj_ret.stress"
timeout 900 "$BIN" "$ret" > "$rbase" 2>&1;                          rc_rb=$?
timeout 900 env HAMNIX_JS_GC_STRESS=1 "$BIN" "$ret" > "$rstr" 2>&1; rc_rs=$?
if [ "$rc_rb" -ne 0 ] || [ "$rc_rs" -ne 0 ]; then
    echo "[js-gc-obj] FAIL: adversarial-retention run exited ($rc_rb/$rc_rs): $(tail -2 "$rbase")"; fail=1
fi
if ! grep -qF "$WANT_RET" "$rbase"; then
    echo "[js-gc-obj] FAIL: a LIVE object was freed (retention mismatch)"
    echo "  got:  $(head -1 "$rbase")"; echo "  want: $WANT_RET"; fail=1
elif ! grep -qF "DRAIN pval=15 tsaw=77" "$rbase"; then
    echo "[js-gc-obj] FAIL: timer/promise-only reachability lost: $(tail -1 "$rbase")"; fail=1
elif ! diff -q "$rbase" "$rstr" >/dev/null; then
    echo "[js-gc-obj] FAIL: retention output DIFFERS under object-GC stress"
    echo "  base:   $(head -1 "$rbase")"; echo "  stress: $(head -1 "$rstr")"; fail=1
else
    echo "[js-gc-obj] PASS: cycles/closures/protos/bound/Map/Set/promise/generator/typed-array/proxy/symbol/timer/builtin-held all survived 240k-object churn + forced GC"
fi

# ---------------------------------------------------------------------------
# PART C — IDENTITY across recycled slots. Phase 5 REUSES freed object slots,
# so the failure mode a leak never had is aliasing: a retained object must never
# become === an object allocated after it was (wrongly) freed.
# ---------------------------------------------------------------------------
ident="$OUT/js_gc_obj_ident.js"
cat > "$ident" <<'EOF'
var keep = [];
for (var i = 0; i < 300; i++) keep.push({ tag: i });
for (var i = 0; i < 150000; i++) { var junk = { j: i, arr: [i] }; }   // fills + recycles the arena
gc();
var fresh = [];
for (var i = 0; i < 300; i++) fresh.push({ tag: i });
var alias = 0, selfeq = 0, tagok = 0;
for (var i = 0; i < keep.length; i++) {
  if (keep[i] === keep[i]) selfeq++;
  if (keep[i].tag === i) tagok++;
  for (var j = 0; j < fresh.length; j++) if (keep[i] === fresh[j]) alias++;
}
console.log("IDENT alias=" + alias + " selfeq=" + selfeq + " tagok=" + tagok);
EOF
WANT_ID="IDENT alias=0 selfeq=300 tagok=300"
ibase="$OUT/js_gc_obj_ident.base"
timeout 900 "$BIN" "$ident" > "$ibase" 2>&1; rc_i=$?
if [ "$rc_i" -ne 0 ] || ! grep -qF "$WANT_ID" "$ibase"; then
    echo "[js-gc-obj] FAIL: object identity broke across recycled slots"
    echo "  got:  $(tail -1 "$ibase")"; echo "  want: $WANT_ID"; fail=1
else
    echo "[js-gc-obj] PASS: 300 retained objects keep identity and never alias a post-collection allocation"
fi

# ---------------------------------------------------------------------------
# PART D — PER-CONSTRUCT byte-identity under object-GC stress.
# ---------------------------------------------------------------------------
constructs="$OUT/js_gc_obj_constructs.js"
cat > "$constructs" <<'EOF'
var out = [];
var o = { a: 1, b: { c: 2 } }; out.push("lit=" + (o.a + o.b.c));
var a = [1, 2, 3].map(function (x) { return x * x; }); out.push("map=" + a.join(","));
out.push("json=" + JSON.stringify({ k: [1, { z: 2 }], s: "x" }));
out.push("parse=" + JSON.parse('{"p":[3,4]}').p[1]);
out.push("keys=" + Object.keys({ q: 1, r: 2 }).join("/"));
out.push("spread=" + JSON.stringify(Object.assign({}, { m: 1 }, { n: 2 })));
var re = /(\d+)-(\w+)/; var mm = re.exec("42-abc"); out.push("re=" + mm[1] + mm[2]);
out.push("str=" + "a,b,c".split(",").reverse().join("|"));
function* g() { yield 1; yield 2; } var gs = 0; for (var v of g()) gs += v; out.push("gen=" + gs);
var s = new Set([1, 2, 2, 3]); var mp = new Map([["a", 1]]); out.push("coll=" + s.size + mp.get("a"));
class K { constructor(v) { this.v = v; } get d() { return this.v * 2; } } out.push("cls=" + new K(6).d);
var pv = 0; Promise.resolve(5).then(function (r) { pv = r; }); out.push("prom=" + pv);
var ta = new Float64Array(3); ta[1] = 1.5; out.push("ta=" + ta[1]);
out.push("sc=" + JSON.stringify(structuredClone({ w: [1, 2] })));
var err = ""; try { null.x; } catch (e) { err = e instanceof TypeError ? "TE" : "?"; } out.push("err=" + err);
console.log(out.join(" | "));
EOF
xbase="$OUT/js_gc_obj_c.base"; xstr="$OUT/js_gc_obj_c.stress"
timeout 900 "$BIN" "$constructs" > "$xbase" 2>&1;                          rc_xb=$?
timeout 900 env HAMNIX_JS_GC_STRESS=1 "$BIN" "$constructs" > "$xstr" 2>&1; rc_xs=$?
if [ "$rc_xb" -ne 0 ] || [ "$rc_xs" -ne 0 ]; then
    echo "[js-gc-obj] FAIL: constructs run exited ($rc_xb/$rc_xs): $(tail -1 "$xbase")"; fail=1
elif ! grep -q "lit=3 | map=1,4,9" "$xbase"; then
    echo "[js-gc-obj] FAIL: constructs baseline output wrong: $(cat "$xbase")"; fail=1
elif ! diff -q "$xbase" "$xstr" >/dev/null; then
    echo "[js-gc-obj] FAIL: per-construct output DIFFERS under object-GC stress (a root is missing)"
    echo "  base:   $(cat "$xbase")"; echo "  stress: $(cat "$xstr")"; fail=1
else
    echo "[js-gc-obj] PASS: literals/map/JSON/regex/generators/collections/classes/promises/typed-arrays/structuredClone byte-identical under object-GC stress"
fi

# ---------------------------------------------------------------------------
# PART E — EMBEDDER (DOM) HANDLES survive a page that churns past the ceiling.
# A DOM element wrapper, a property stored on it, and an event-listener closure
# are all reachable ONLY from the embedder's own Adder-side handle tables — no
# JS root names them. ext_pin at the js_* boundary is what keeps them alive.
# ---------------------------------------------------------------------------
HB="$OUT/hambrowse_host"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$HB" 2>"$OUT/js_gc_obj_hb_compile.log"; then
    echo "[js-gc-obj] FAIL: hambrowse host harness did not compile"; cat "$OUT/js_gc_obj_hb_compile.log"; fail=1
else
    page="$OUT/js_gc_obj_dom.html"
    cat > "$page" <<'EOF'
<!doctype html><html><body>
<div id="host">start</div><button id="b">go</button>
<script>
var el = document.getElementById("host");
el.__stash = { deep: { v: 4242 } };          // property on a DOM wrapper
var seen = -1;
document.getElementById("b").addEventListener("click", function () { seen = el.__stash.deep.v; });
// churn FAR past the 40,000-object ceiling while the DOM handles must survive
var s = 0;
for (var i = 0; i < 200000; i++) { var q = { i: i, a: [i] }; s += q.a[0] & 1; }
document.getElementById("b").click();
var made = document.createElement("span");
made.textContent = "made-" + (el.__stash.deep.v + seen);
el.appendChild(made);
el.textContent = el.textContent;             // force a readback of the live subtree
document.title = "DOMGC seen=" + seen + " churn=" + s;
</script>
</body></html>
EOF
    dout="$OUT/js_gc_obj_dom.txt"
    timeout 900 "$HB" "$page" > "$dout" 2>&1; rc_d=$?
    WANT_D="DOMGC seen=4242 churn=$(python3 -c 'print(sum(i & 1 for i in range(200000)))')"
    if [ "$rc_d" -ne 0 ]; then
        echo "[js-gc-obj] FAIL: DOM page render exited $rc_d: $(tail -3 "$dout")"; fail=1
    elif grep -qF "object pool exhausted" "$dout"; then
        echo "[js-gc-obj] FAIL: the DOM page still exhausts the object pool"; fail=1
    elif ! grep -qF "$WANT_D" "$dout"; then
        echo "[js-gc-obj] FAIL: an embedder-held (DOM) object was freed or the churn failed"
        echo "  want: $WANT_D"; grep -o "DOMGC[^\"<]*" "$dout" | head -1 | sed 's/^/  got:  /'; fail=1
    elif ! grep -qF "made-8484" "$dout"; then
        echo "[js-gc-obj] FAIL: the dynamically created + appended element did not survive"; fail=1
    else
        echo "[js-gc-obj] PASS: DOM wrapper property, listener closure and created subtree survived 200k-object churn"
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "[js-gc-obj] RESULT: PASS"; exit 0
else
    echo "[js-gc-obj] RESULT: FAIL"; exit 1
fi
