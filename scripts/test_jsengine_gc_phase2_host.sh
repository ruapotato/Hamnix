#!/usr/bin/env bash
# scripts/test_jsengine_gc_phase2_host.sh — QEMU-free gate for Phase-2 GC:
# the higher-order Array builtins (map/filter/reduce/reduceRight/forEach/some/
# every/find/findIndex/findLast/findLastIndex/flatMap/sort/toSorted) were rooted
# with explicit gc_push/gc_popto pins and had their gc_disabled SUPPRESSION
# removed, so the collector can now reclaim dead value-cells MID-CALLBACK.
#
# This gate proves two things a mis-rooting or a leak would each fail:
#   1. CORRECTNESS + BYTE-IDENTITY. Every un-suppressed builtin, run under
#      HAMNIX_JS_GC_STRESS=1 (a collection fires roughly every ~64 allocations,
#      i.e. BETWEEN and DURING callbacks), produces output byte-identical to the
#      non-stress run and to the hand-computed expected string. A missing pin
#      would free a handle still held in a native local (accumulator, result
#      array, sort pivot) and corrupt the result.
#   2. RECLAMATION PAST THE ARENA. A reduce / map / sort whose callbacks allocate
#      MORE than the whole 1,000,000-cell value arena (with only a bounded live
#      set) COMPLETES with the correct result and reports gc() > 0. Completing at
#      all is impossible without the collector reclaiming dead cells inside the
#      builtin — which, before Phase-2, the gc_disabled suppression forbade
#      (the run would have died with "value pool exhausted").
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-gc-p2] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_gc_p2_compile.log"; then
    echo "[js-gc-p2] FAIL: host driver did not compile"; cat "$OUT/js_gc_p2_compile.log"; exit 1
fi

fail=0

# ---------------------------------------------------------------------------
# PART 1 — correctness + byte-identity across every un-suppressed builtin.
# ---------------------------------------------------------------------------
corr="$OUT/js_gc_p2_corr.js"
cat > "$corr" <<'EOF'
var a = [];
for (var i = 0; i < 2000; i++) a.push(i);
var out = [];
out.push("filter=" + a.filter(function (x) { return x % 3 === 0; }).length);
out.push("some=" + a.some(function (x) { return x === 1999; }));
out.push("every=" + a.every(function (x) { return x < 2000; }));
out.push("find=" + a.find(function (x) { return x > 1500; }));
out.push("findIndex=" + a.findIndex(function (x) { return x > 1500; }));
out.push("findLast=" + a.findLast(function (x) { return x < 50; }));
out.push("findLastIndex=" + a.findLastIndex(function (x) { return x < 50; }));
out.push("flatMap=" + a.slice(0, 5).flatMap(function (x) { return [x, x * 10]; }).join(","));
out.push("reduce=" + a.reduce(function (s, x) { return s + x; }, 0));
out.push("reduceRight=" + [1, 2, 3, 4].reduceRight(function (p, q) { return p + "-" + q; }));
var fe = 0; a.forEach(function (x) { fe += x; }); out.push("forEach=" + fe);
out.push("map3=" + a.slice(0, 3).map(function (x) { return x * x; }).join(","));
// sort + toSorted with an ALLOCATING comparator (garbage per comparison)
var u = [5, 3, 9, 1, 7, 2, 8, 4, 6, 0];
var srt = u.slice(0).sort(function (p, q) { var g = (p * 3 + q * 5) % 11; return p - q; });
out.push("sort=" + srt.join(","));
out.push("toSorted=" + u.toSorted(function (p, q) { var g = p + q; return q - p; }).join(","));
console.log(out.join(" | "));
EOF

WANT_CORR="filter=667 | some=true | every=true | find=1501 | findIndex=1501 | findLast=49 | findLastIndex=49 | flatMap=0,0,1,10,2,20,3,30,4,40 | reduce=1999000 | reduceRight=4-3-2-1 | forEach=1999000 | map3=0,1,4 | sort=0,1,2,3,4,5,6,7,8,9 | toSorted=9,8,7,6,5,4,3,2,1,0"
cbase="$OUT/js_gc_p2_corr.base"; cstr="$OUT/js_gc_p2_corr.stress"
"$BIN" "$corr" > "$cbase" 2>&1;                      rc_cb=$?
HAMNIX_JS_GC_STRESS=1 "$BIN" "$corr" > "$cstr" 2>&1; rc_cs=$?
if [ "$rc_cb" -ne 0 ]; then echo "[js-gc-p2] FAIL: correctness non-stress run exited $rc_cb: $(tail -1 "$cbase")"; fail=1; fi
if [ "$rc_cs" -ne 0 ]; then echo "[js-gc-p2] FAIL: correctness stress run exited $rc_cs: $(tail -1 "$cstr")"; fail=1; fi
if [ "$(cat "$cbase")" != "$WANT_CORR" ]; then
    echo "[js-gc-p2] FAIL: correctness output unexpected"; echo "  got:  $(cat "$cbase")"; echo "  want: $WANT_CORR"; fail=1
fi
if ! diff -q "$cbase" "$cstr" >/dev/null; then
    echo "[js-gc-p2] FAIL: builtin output DIFFERS under GC stress (a root pin is missing)"
    echo "  base:   $(cat "$cbase")"; echo "  stress: $(cat "$cstr")"; fail=1
else
    echo "[js-gc-p2] PASS: all un-suppressed builtins byte-identical under GC stress + match expected"
fi

# ---------------------------------------------------------------------------
# PART 2 — reclamation past the value arena. Each workload allocates > the whole
# 1,000,000-cell arena in per-callback garbage with a bounded live set; it can
# only complete if the collector reclaims mid-callback (impossible before the
# Phase-2 suppression removal). gc() > 0 confirms a collection actually fired.
#
# The env arena (80k cells) is bump-only in Phase 1 and every callback consumes
# one env, so each workload runs in its OWN process (their callback counts sum
# past the env ceiling; the value arena we DO reclaim is what this gate targets).
# ---------------------------------------------------------------------------

# --- reduce: ~40 numeric sub-expressions/callback * 30000 = ~1.2M garbage cells,
#     bounded live set (one accumulator). ---
reduce_js="$OUT/js_gc_p2_reduce.js"
cat > "$reduce_js" <<'EOF'
var src = [];
for (var i = 0; i < 30000; i++) src.push(i);
var rt = src.reduce(function (acc, x) {
  return acc + ((x*3-1)+(x*5+2)-(x%7)+(x*2-3)+(x%11)+(x*4-5)+(x%13)+(x*6+1)
              +(x*7-2)+(x%17)+(x*8+3)-(x%19)+(x*9-6)+(x%23)+(x*2+7)-(x%29)
              +(x*3-8)+(x%31)+(x*4+9)-(x%37)) % 97;
}, 0);
console.log("RT=" + rt + " COLL=" + (gc() > 0));
EOF

# --- map: 25000 LIVE results + heavy per-callback garbage, total > 1M cells. ---
map_js="$OUT/js_gc_p2_map.js"
cat > "$map_js" <<'EOF'
var src = [];
for (var i = 0; i < 25000; i++) src.push(i);
var mp = src.map(function (x) {
  return ((x*3-1)+(x*5+2)-(x%7)+(x*2-3)+(x%11)+(x*4-5)+(x%13)+(x*6+1)
        +(x*7-2)+(x%17)+(x*8+3)-(x%19)+(x*9-6)+(x%23)+(x*2+7)-(x%29)
        +(x*3-8)+(x%31)+(x*4+9)-(x%37)) % 97;
});
var ms = 0; for (var i = 0; i < mp.length; i++) ms = ms + mp[i];
console.log("MS=" + ms + " LEN=" + mp.length + " COLL=" + (gc() > 0));
EOF

# --- sort: allocating comparator; ~n^2 comparisons each allocating ~40 cells
#     (> 1M total), kept under the env ceiling. Result must be correctly ordered. ---
sort_js="$OUT/js_gc_p2_sort.js"
cat > "$sort_js" <<'EOF'
var sa = [];
for (var i = 0; i < 260; i++) sa.push((i * 7919) % 260);
sa.sort(function (p, q) {
  var g = ((p*3-1)+(q*5+2)-(p%7)+(q*2-3)+(p%11)+(q*4-5)+(p%13)+(q*6+1)
         +(p*7-2)+(q%17)+(p*8+3)-(q%19)+(p*9-6)+(q%23)+(p*2+7)-(q%29)
         +(p*3-8)+(q%31)+(p*4+9)-(q%37));
  return p - q;
});
var ordered = 1;
for (var i = 1; i < sa.length; i++) if (sa[i - 1] > sa[i]) ordered = 0;
console.log("SORTED=" + ordered + " FIRST=" + sa[0] + " LAST=" + sa[sa.length - 1] + " COLL=" + (gc() > 0));
EOF

check_reclaim() {
    local name="$1" js="$2" want="$3"
    local b="$OUT/js_gc_p2_${name}.base" s="$OUT/js_gc_p2_${name}.stress"
    "$BIN" "$js" > "$b" 2>&1;                      local rcb=$?
    HAMNIX_JS_GC_STRESS=1 "$BIN" "$js" > "$s" 2>&1; local rcs=$?
    if [ "$rcb" -ne 0 ]; then echo "[js-gc-p2] FAIL: $name non-stress exited $rcb (arena exhaustion = suppression not removed): $(tail -1 "$b")"; fail=1; fi
    if [ "$rcs" -ne 0 ]; then echo "[js-gc-p2] FAIL: $name stress exited $rcs: $(tail -1 "$s")"; fail=1; fi
    if [ "$(cat "$b")" != "$want" ]; then
        echo "[js-gc-p2] FAIL: $name output unexpected"; echo "  got:  $(cat "$b")"; echo "  want: $want"; fail=1
    elif ! diff -q "$b" "$s" >/dev/null; then
        echo "[js-gc-p2] FAIL: $name output DIFFERS under GC stress"; echo "  base: $(cat "$b")"; echo "  stress: $(cat "$s")"; fail=1
    else
        echo "[js-gc-p2] PASS: $name allocated >1M cells past the arena and COMPLETED (reclamation confirmed, gc()>0)"
    fi
}

check_reclaim reduce "$reduce_js" "RT=1443976 COLL=true"
check_reclaim map    "$map_js"    "MS=1204219 LEN=25000 COLL=true"
check_reclaim sort   "$sort_js"   "SORTED=1 FIRST=0 LAST=259 COLL=true"

if [ "$fail" -eq 0 ]; then
    echo "[js-gc-p2] RESULT: PASS"; exit 0
else
    echo "[js-gc-p2] RESULT: FAIL"; exit 1
fi
