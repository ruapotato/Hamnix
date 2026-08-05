#!/usr/bin/env bash
# scripts/test_js_dom_store_share_host.sh — QEMU-FREE measurement gate that
# answers ONE question with a number instead of a story:
#
#     of the objects the collector cannot free, how many are held up by the
#     DOM's own node stores (cre_obj / stx_obj / dom_obj) AND NOTHING ELSE?
#
# WHY THIS GATE EXISTS
# ====================
# After ext_pin was split (2026-08-05) the remaining WPT object-arena wall was
# attributed to those stores: "cre_obj / dom_obj keep every node the DOM ever
# made", banked as a CEILING in scripts/test_js_ext_pin_leak_host.sh with a DOM
# detach path named as the open fix. The evidence was a live-object total of
# 25,439 after 8,000 dropped createElement calls.
#
# A live-object total cannot support that claim. It says an object SURVIVED; it
# cannot say WHY. A node the page still reaches through the document tree, a JS
# variable or an event handler reads exactly like one only a store remembers,
# and "the stores retain everything" is a statement about REACHABILITY.
#
# So js_arena_stat gained a counterfactual: indices 55-58 run the collector's
# OWN root set and transitive closure WITHOUT SWEEPING, with a named subset of
# the embedder's tables omitted (lib/web/js/gc.ad js_obj_reachable_census,
# lib/web/dom/canvas.ad _dom_gc_ext_roots). 55 minus 56 is exactly the set a
# perfect detach path could reclaim: objects nothing but the created-node stores
# is holding up.
#
# WHAT IT MEASURED — THE DETACH PATH IS NOT THE LEVER
# ===================================================
# Measured 2026-08-05 on x86_64-linux, engine at this commit:
#
#   probe                                    reachable   store-only   share
#   -----------------------------------------------------------------------
#   8,000 bare createElement, dropped           25,391       23,997   94.5%
#   4,000 trivial test(), NO DOM at all         47,606            0    0.0%
#   4,000 test() + create/append/remove each    47,417        5,679   12.0%
#
# and on the FIVE vendored WPT files that actually die with "object pool
# exhausted" (the ratchet's own truncation list; the other 37 truncations are
# the string pool and the gc root stack, which this term cannot touch at all):
#
#   dom/ranges/Range-comparePoint         24,388    5,805   23.8%   (2,113 subtests)
#   dom/ranges/Range-isPointInRange       32,046        0    0.0%   (2,163)
#   dom/ranges/Range-mutations-appendData 21,796        0    0.0%   (  162)
#   dom/ranges/Range-set                  45,148        0    0.0%   (  686)
#   dom/traversal/TreeWalker              45,293        0    0.0%   (  577)
#
# HOW TO REPRODUCE THE WPT ROWS (they are not in this gate because a gate that
# runs WPT files is the ratchet's job, and the census is on stderr, which
# scripts/wpt_run.py discards):
#
#     python3 -c "import sys; sys.path.insert(0,'scripts'); import wpt_run; \
#       open('/tmp/p.html','wb').write(wpt_run.preprocess( \
#       'dom/ranges/Range-set.html', mode='separate')[0])"
#     HAMNIX_JS_ARENA_STATS=1 build/host/hambrowse_host /tmp/p.html 800 2>&1 \
#       | tr ' ' '\n' | grep objreach
#
# The file list came from the ratchet's own TRUNCATED report, filtered to
# "object pool exhausted".
#
# (Those five are read POST-MORTEM, at process exit rather than at the instant
# of exhaustion — the census is printed on the way out. Scoped pins have been
# released by then, so the absolute totals are lower than they were at the wall;
# the store-only term is what is being read and it is zero four times out of
# five.)
#
# The bare-createElement row is the number the ceiling was banked from, and it
# is the ONLY row where the stores dominate — because a page that does nothing
# but createElement is 94% created nodes by construction. It is a probe
# measuring itself. On the workload that actually ends WPT files —
# testharness.js, which dies at 2,162 subtests with the object pool exhausted —
# the stores hold ZERO. Every one of those 47,606 objects is reachable from a
# legitimate root, i.e. from testharness.js's own live Test graph. A DOM detach
# path, implemented perfectly, would move that file by nothing.
#
# The DOM-churn row is the honest upper bound for a page that does use the DOM:
# 12%. Note it dies EARLIER than the DOM-free page (1,893 vs 2,162 subtests),
# so reclaiming the whole 12% buys back roughly what the churn cost and lands
# on the same wall. The wall is testharness retention and MAX_OBJ, as
# lib/web/js/api.ad already says.
#
# WHAT THIS GATE ENFORCES
# =======================
# The store-only counts above, as CEILINGS. It goes red if the node stores start
# retaining more than they do today — the regression a detach path would exist
# to prevent — and it is the standing disproof of "the detach path is the lever"
# so that claim cannot be re-briefed from memory. Absolute counts, not shares:
# a share would rise mechanically if testharness's own retention were fixed,
# scoring an unrelated win as a regression here.
#
# Three outcomes: 0 PASS, 1 FAIL, 125 INCONCLUSIVE. A probe that does not run to
# completion measured nothing and reports 125 — never PASS.
#
# ~60 s: engine compile (cached) + three small pages.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TAG="[dom-store-share]"
OUT="build/host"
BIN="$OUT/hambrowse_host"
TH="tests/wpt/tests/resources/testharness.js"
RP="tests/wpt/hamnix_testharnessreport.js"
mkdir -p "$OUT"

N_EL=8000       # bare createElement, every one dropped
N_TH=4000       # trivial test() calls, matching the DOM-free wall probe

# Banked 2026-08-05. STORE-ONLY = js_arena_stat(55) - js_arena_stat(56), the
# objects a perfect DOM detach path could reclaim and nothing else could.
CEILING_EL_STORE=25000    # bare-createElement probe: 23,997 measured
CEILING_THP_STORE=200       # DOM-free testharness page: 0 measured
CEILING_THC_STORE=7000      # DOM-churn testharness page: 5,679 measured

[ -r "$TH" ] && [ -r "$RP" ] || {
    echo "$TAG INCONCLUSIVE: the vendored WPT harness is missing ($TH);"
    echo "$TAG   the load-bearing probe is the testharness one, so nothing was measured."
    exit 125; }

echo "$TAG compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/domshare_compile.log"; then
    echo "$TAG INCONCLUSIVE: host harness did not compile; nothing was measured."
    cat "$OUT/domshare_compile.log"; exit 125
fi

run_probe() {   # $1 = name
    HAMNIX_JS_ARENA_STATS=1 timeout 600 "$BIN" "$OUT/domshare_$1.html" 800 \
        > "$OUT/domshare_$1.out" 2>&1
}

# A bare page: no harness, just N createElement calls that are all dropped.
mk_bare() {     # $1 = name, $2 = iterations
    cat > "$OUT/domshare_$1.html" <<EOF
<!doctype html><meta charset=utf-8><title>$1</title>
<script>
var sink = 0;
for (var i = 0; i < $2; i++) { var e = document.createElement("div"); sink += e.nodeName.length; }
console.log("PROBE-DONE " + sink);
</script>
EOF
}

# A testharness.js page, assembled the way scripts/wpt_run.py assembles a real
# WPT file (harness inlined, our vendor reporter substituted for the upstream
# stub). This is the workload that ends WPT files, so it is the one that decides.
mk_harness() {  # $1 = name, $2 = iterations, $3 = per-iteration JS
    {
        printf '<!doctype html><meta charset=utf-8><title>%s</title>\n<script>\n' "$1"
        cat "$TH"
        printf '\n</script>\n<script>\n'
        cat "$RP"
        printf '\n</script>\n<body>\n<script>\nfor (var i = 0; i < %s; i++) { %s }\n' "$2" "$3"
        printf 'console.log("PROBE-DONE " + i);\n</script>\n'
    } > "$OUT/domshare_$1.html"
}

read_stat() {   # $1 = out file, $2 = key
    sed -n 's/.*[^a-z]'"$2"'=\([0-9]*\).*/\1/p' "$1" | head -1
}

# STORE-ONLY retention. Both readings come off the SAME arena state in the same
# run, so nothing about page timing can move one and not the other.
store_only() {  # $1 = out file  -> prints "<reach> <storeonly>"
    local r n
    r=$(read_stat "$1" objreach); n=$(read_stat "$1" objreachnocre)
    [ -n "$r" ] && [ -n "$n" ] || return 1
    echo "$r $((r - n))"
}

rc=0
fail() { echo "$TAG FAIL: $1"; rc=1; }

judge() {   # $1 = name, $2 = human label, $3 = ceiling, $4 = require PROBE-DONE
    local out="$OUT/domshare_$1.out" pair reach only
    if [ "$4" = "1" ] && ! grep -q 'PROBE-DONE' "$out"; then
        echo "$TAG INCONCLUSIVE: the $2 probe never finished; no census was taken."
        sed -n '1,10p' "$out"; exit 125
    fi
    pair=$(store_only "$out") || {
        echo "$TAG INCONCLUSIVE: no counterfactual census in the $2 output."
        echo "$TAG   js_arena_stat 55-58 is the instrument and it said nothing."
        exit 125; }
    reach=${pair% *}; only=${pair#* }
    local pct=0
    [ "$reach" -gt 0 ] && pct=$((100 * only / reach))
    echo "$TAG $2: reachable=$reach  held ONLY by cre_obj/stx_obj=$only (${pct}%, ceiling $3)"
    [ "$only" -le "$3" ] || fail "the DOM node stores retain MORE on the $2 probe."
}

mk_bare bare "$N_EL"
run_probe bare
judge bare "$N_EL dropped bare createElement" "$CEILING_EL_STORE" 1

mk_harness thplain "$N_TH" 'test(function(){assert_true(true);}, "t"+i);'
run_probe thplain
# NOT required to finish: this page deliberately runs until the object pool is
# exhausted -- that exhaustion IS the wall under measurement. The census is
# still printed at exit, and it is taken at the worst moment, which is the one
# that matters.
judge thplain "$N_TH trivial test(), no DOM" "$CEILING_THP_STORE" 0

mk_harness thchurn "$N_TH" \
  'var e=document.createElement("div");document.body.appendChild(e);document.body.removeChild(e);test(function(){assert_true(true);}, "t"+i);'
run_probe thchurn
judge thchurn "$N_TH test() + create/append/remove" "$CEILING_THC_STORE" 0

if [ "$rc" = 0 ]; then
    echo "$TAG RESULT: PASS"
    echo "$TAG VERDICT (banked, do not re-brief from memory): a DOM detach path is"
    echo "$TAG   NOT the lever for the WPT object-arena wall. On the workload that"
    echo "$TAG   ends WPT files the node stores hold 0% of the live set; the 94.5%"
    echo "$TAG   that motivated the open item is a probe measuring itself."
else
    echo "$TAG RESULT: FAIL — the DOM node stores retain more than they did;"
    echo "$TAG   see _dom_gc_ext_roots in lib/web/dom/canvas.ad."
fi
exit $rc
