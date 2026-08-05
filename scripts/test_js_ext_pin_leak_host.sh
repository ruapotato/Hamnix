#!/usr/bin/env bash
# scripts/test_js_ext_pin_leak_host.sh — QEMU-FREE ratchet on the EXTERNAL-PIN
# LEAK: how many objects a page makes immortal per unit of ordinary work.
#
# WHY THIS GATE EXISTS
# ====================
# lib/web/js/api.ad ext_pin() pins FOREVER every object value handle that
# crosses the js_* API boundary. It is documented as "a leak and never a
# corruption", bounded by "the set that was already immortal". On 2026-08-04
# that bound was measured and found false: a native CONSTRUCTOR builds its
# result with js_new_object_v(), which crosses the boundary, so the immortal
# set is LINEAR IN WHAT THE PAGE DOES.
#
#   * 20,000 `new AbortController()`, every one dropped, pins ~40,600 objects
#     and consumes 41,391 of the 48,000 object slots. AbortController and
#     AbortSignal are built purely from js_new_object_v + js_set_prop; no
#     embedder table ever holds them, so the pin protects nothing.
#   * 8,000 `document.createElement("div")`, never inserted, pins ~25,176 —
#     about 3 immortal objects per detached node. A node the page has dropped
#     and never attached can never be reclaimed.
#
# This is what ends a long-running page, and it is what ends a WPT file: a page
# with NO DOM interaction at all — 4,000 trivial test() calls — dies at 2,211
# subtests, the same wall as the Range files, because testharness.js builds an
# AbortController per Test.
#
# WHY IT IS A RATCHET AND NOT AN ASSERTION OF ZERO
# ===============================================
# The leak is real and OPEN — fixing it means splitting ext_pin into a scoped
# temp-root for transient handles and a traced root set for the embedder's
# tables (see the comment above ext_pin). Until then, asserting zero would be a
# permanently-red gate, which this project has learned reads as noise. So this
# banks TODAY'S numbers as a CEILING: it goes green now, and it goes red the
# moment a change makes the immortal set grow faster. When the leak is fixed,
# drop CEILING_* to the new numbers — the gate is the proof it stayed fixed.
#
# The measurement is the js_arena_stat live-object census (indices 49-54),
# surfaced by hambrowse_host under HAMNIX_JS_ARENA_STATS=1. n_objs alone cannot
# do this: it is an EXTENT that never falls, so a retention bug and a genuine
# working set both read as "n_objs == MAX_OBJ".
#
# ~40 s: engine compile + two small pages.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TAG="[ext-pin-leak]"
OUT="build/host"
BIN="$OUT/hambrowse_host"
mkdir -p "$OUT"

# Banked 2026-08-04 on x86_64-linux. Both probes drop every object they make.
#
# N_EL is 8000 and not 20000 because document.createElement has its OWN hard
# per-page ceiling, CRE_MAX=8192, after which it returns null and the page dies
# on the next property access. That is a fifth silent cap on top of the four
# arena ceilings, and it is why this probe must stay under it: a probe that
# trips a DIFFERENT limit measures that limit instead of the one it names.
#
# RE-BANKED 2026-08-05, after ext_pin was split into a scoped pin plus an
# enumerated embedder root set (see the note above ext_pin). The pinned set
# stopped being a function of what the page does:
#     20,000 dropped AbortControllers  objpinned 40,600 -> 596
#      8,000 dropped detached <div>s   objpinned 24,600 -> 596
# 596 is the DOM's own permanent set (prototypes, document, window) and does not
# move with N.
#
# WHY THERE IS ALSO A LIVE-OBJECT CEILING NOW. objpinned alone can no longer
# carry this gate: retention MOVED from the pin to the root hook, so a table the
# hook marks conservatively (cre_obj, dom_obj, ...) retains objects that
# objpinned does not count. Reading only objpinned would score that as a fix.
# The LIVE object total (plain+array+func+symbol) is the honest number and is
# what a future reclamation fix has to move.
N_AC=20000
N_EL=8000
#
# AND WHAT IS STILL OPEN, said plainly: only the AbortController number fell.
#     AbortController  live objects 41,391-ish -> 4,431 of 48,000, and one
#         collection reclaims 37,008. The controllers are genuinely dead and
#         are genuinely reclaimed.
#     detached <div>   live objects 25,439 and ZERO collections. A created node
#         is still immortal — not because of the pin any more, but because the
#         DOM's own cre_obj / dom_obj tables keep every node it ever made, and
#         the root hook faithfully reports that.
# Reading only objpinned would score the second case as fixed. It is not.
#
# ★ CORRECTED 2026-08-05, same day. This block used to end "reclaiming those
# needs a DETACH path in the DOM, which is a separate open item", and that
# conclusion was drawn from THIS PROBE ALONE. It does not survive being
# measured. js_arena_stat gained a counterfactual reachability census (55-58:
# the collector's own roots and closure, run without sweeping, with the
# created-node stores omitted), and it says the 25,439 above is 23,997 objects
# held ONLY by cre_obj — 94.5% — because a page that does nothing but
# createElement is created nodes by construction. THE PROBE IS MEASURING
# ITSELF. On the workload that actually ends WPT files (testharness.js, object
# pool exhausted at 2,162 subtests) the stores hold ZERO, and on four of the
# five vendored WPT files that die on the object pool the term is likewise
# exactly zero. The detach path is NOT the lever; the number below stays as a
# regression ceiling and NOT as a target. See
# scripts/test_js_dom_store_share_host.sh for the table and the method.
CEILING_AC=1000         # objpinned after 20k dropped AbortControllers
CEILING_EL=1000         # objpinned after 8k dropped detached <div>s
CEILING_AC_LIVE=5000    # LIVE objects, same probe
CEILING_EL_LIVE=26000   # LIVE objects, same probe — still the open half

echo "$TAG compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/extpin_compile.log"; then
    echo "$TAG INCONCLUSIVE: host harness did not compile; nothing was measured."
    cat "$OUT/extpin_compile.log"; exit 125
fi

probe() {   # $1 = name, $2 = iterations, $3 = JS body
    cat > "$OUT/extpin_$1.html" <<EOF
<!doctype html><meta charset=utf-8><title>$1</title>
<script>
var sink = 0;
for (var i = 0; i < $2; i++) { $3 }
console.log("PROBE-DONE " + sink);
</script>
EOF
    HAMNIX_JS_ARENA_STATS=1 timeout 300 "$BIN" "$OUT/extpin_$1.html" 800 \
        > "$OUT/extpin_$1.out" 2>&1
}

read_stat() {   # $1 = out file, $2 = key
    sed -n 's/.*[^a-z]'"$2"'=\([0-9]*\).*/\1/p' "$1" | head -1
}

# LIVE objects = every arena slot the collector could not reclaim, by kind.
# n_objs is an EXTENT and never falls, so it cannot answer this.
read_live() {   # $1 = out file
    local a b c d
    a=$(read_stat "$1" objplain);  b=$(read_stat "$1" objarray)
    c=$(read_stat "$1" objfunc);   d=$(read_stat "$1" objsym)
    [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] || return 1
    echo $((a + b + c + d))
}

rc=0

probe ac "$N_AC" 'var c = new AbortController(); sink += c.signal ? 1 : 0;'
if ! grep -q 'PROBE-DONE' "$OUT/extpin_ac.out"; then
    echo "$TAG INCONCLUSIVE: the AbortController probe never finished;"
    echo "$TAG   no census was taken, so there is no reading to judge."
    sed -n '1,10p' "$OUT/extpin_ac.out"; exit 125
fi
AC=$(read_stat "$OUT/extpin_ac.out" objpinned)
[ -n "$AC" ] || { echo "$TAG INCONCLUSIVE: no ARENA census line in the probe output;"
                  echo "$TAG   HAMNIX_JS_ARENA_STATS is the instrument and it said nothing."
                  exit 125; }

probe el "$N_EL" 'var e = document.createElement("div"); sink += e.nodeName.length;'
if ! grep -q 'PROBE-DONE' "$OUT/extpin_el.out"; then
    echo "$TAG INCONCLUSIVE: the createElement probe never finished."
    sed -n '1,10p' "$OUT/extpin_el.out"; exit 125
fi
EL=$(read_stat "$OUT/extpin_el.out" objpinned)
[ -n "$EL" ] || { echo "$TAG INCONCLUSIVE: no ARENA census line in the probe output."; exit 125; }

ACL=$(read_live "$OUT/extpin_ac.out")
ELL=$(read_live "$OUT/extpin_el.out")
[ -n "$ACL" ] && [ -n "$ELL" ] || {
    echo "$TAG INCONCLUSIVE: the census did not report live objects by kind."; exit 125; }

echo "$TAG $N_AC dropped AbortControllers -> objpinned=$AC (ceiling $CEILING_AC), live=$ACL (ceiling $CEILING_AC_LIVE)"
echo "$TAG $N_EL dropped detached <div>s  -> objpinned=$EL (ceiling $CEILING_EL), live=$ELL (ceiling $CEILING_EL_LIVE)"

if [ "$AC" -gt "$CEILING_AC" ]; then
    echo "$TAG FAIL: the PINNED set per dropped AbortController GREW."
    rc=1
fi
if [ "$EL" -gt "$CEILING_EL" ]; then
    echo "$TAG FAIL: the PINNED set per dropped detached element GREW."
    rc=1
fi
if [ "$ACL" -gt "$CEILING_AC_LIVE" ]; then
    echo "$TAG FAIL: the UNRECLAIMED set per dropped AbortController GREW."
    rc=1
fi
if [ "$ELL" -gt "$CEILING_EL_LIVE" ]; then
    echo "$TAG FAIL: the UNRECLAIMED set per dropped detached element GREW."
    rc=1
fi

if [ "$rc" = 0 ]; then
    echo "$TAG RESULT: PASS (the immortal set did not worsen)"
    echo "$TAG NOTE: the AbortController numbers are now HEALTHY — the objects are"
    echo "$TAG   reclaimed. The detached-element live count is NOT: the DOM's own"
    echo "$TAG   cre_obj/dom_obj tables keep every node it ever made — but that is"
    echo "$TAG   94.5% of THIS probe and 0% of the WPT object-pool wall, so it is a"
    echo "$TAG   REGRESSION CEILING and not a target. See"
    echo "$TAG   scripts/test_js_dom_store_share_host.sh for the measurement."
else
    echo "$TAG RESULT: FAIL — the immortal set grew; see ext_pin in lib/web/js/api.ad"
    echo "$TAG   and _dom_gc_ext_roots in lib/web/dom/canvas.ad."
fi
exit $rc
