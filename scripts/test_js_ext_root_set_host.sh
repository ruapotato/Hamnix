#!/usr/bin/env bash
# scripts/test_js_ext_root_set_host.sh — QEMU-FREE gate on the DOM's EXTERNAL
# GC ROOT SET (_dom_gc_ext_roots in lib/web/dom/canvas.ad).
#
# WHY THIS GATE EXISTS
# ====================
# Until 2026-08-05 the engine kept every JS handle the DOM held alive by
# PINNING FOREVER anything that crossed the js_* boundary (lib/web/js/api.ad,
# ext_pin). That was safe by construction and it was the WPT object-arena wall:
# the immortal set grew linearly with what a page DID, because a native
# constructor builds its result with js_new_object_v(). 20,000 dropped
# AbortControllers made 40,600 objects immortal out of a 48,000-slot arena.
#
# The pin is now SCOPED to a host-native dispatch, and what the DOM actually
# RETAINS is kept alive instead by an enumerated root hook. That trade is only
# sound if the hook is COMPLETE. A table missing from it is not a leak, it is a
# use-after-free — the one failure mode this collector must not have.
#
# WHAT IT ENFORCES
# ================
# PART A — the TARGETED PROBE, tests/fixtures/hambrowse_extroots.html. For each
# table in the hook it makes the DOM store a handle, drops every JS-side
# reference, churns until a collection fires, and then reads the handle BACK
# THROUGH THE DOM and compares it. A missing root does not crash; it hands back
# a recycled cell, so only a before/after comparison can see it.
#
# PART B — differential execution over every scripted fixture, rendered once
# normally and once with HAMNIX_JS_GC_STRESS=1 (which collapses the collector's
# water marks so a collection fires every few allocations). The two renders must
# be BYTE-IDENTICAL.
#
# Part B alone is NOT sufficient and was measured saying so: with the root hook
# DELIBERATELY UNREGISTERED, all 83 scripted fixtures still rendered identically
# — they are too small to collect anything the DOM alone holds (31 objects freed
# on the busiest one). The same negative control turns Part A red on
# "listener survived churn". A sweep that cannot fail is not evidence.
#
# This is the only instrument that can see the failure. A normal page never
# collects at all — the water marks sit at 80% of arenas it does not fill — so
# a missing root is invisible in ordinary runs and in the WPT score, and would
# surface later as a corrupted render on some long page nobody is testing. Under
# stress it surfaces on the first fixture that touches the forgotten table.
#
# A DIFFERENCE HERE IS A REAL BUG, NOT NOISE: the collector is required to be
# semantically invisible. If this goes red, find the table the render lost and
# add it to _dom_gc_ext_roots.
#
# NOT SOFT-GREEN: 0 PASS, 1 FAIL, 125 INCONCLUSIVE. If nothing compiled, or the
# corpus is missing, or no fixture actually produced output, it reports 125.
#
# ~3 min.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TAG="[ext-root-set]"
OUT="build/host"
BIN="$OUT/hambrowse_host"
WORK="$OUT/extroot"
mkdir -p "$WORK"

echo "$TAG compiling hambrowse_host for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$WORK/compile.log"; then
    echo "$TAG INCONCLUSIVE: hambrowse_host did not compile; nothing was measured."
    cat "$WORK/compile.log"; exit 125
fi

# The instrument must actually be wired up. If HAMNIX_JS_GC_STRESS is ignored
# (a stale binary, a dropped env hook) both runs are the same run and this gate
# would be a guaranteed, meaningless green.
grep -q 'HAMNIX_JS_GC_STRESS' user/hambrowse_host.ad || {
    echo "$TAG INCONCLUSIVE: hambrowse_host has no HAMNIX_JS_GC_STRESS hook, so"
    echo "$TAG   the stressed run is not stressed and this gate proves nothing."
    exit 125; }
grep -q '_dom_gc_ext_roots' lib/web/dom/canvas.ad || {
    echo "$TAG INCONCLUSIVE: the DOM registers no external root hook."; exit 125; }

# ---- PART A: the targeted probe -------------------------------------------
PROBE=tests/fixtures/hambrowse_extroots.html
[ -f "$PROBE" ] || { echo "$TAG INCONCLUSIVE: $PROBE is missing."; exit 125; }

timeout 300 "$BIN" "$PROBE" 800 > "$WORK/probe.base" 2>&1
HAMNIX_JS_GC_STRESS=1 timeout 900 "$BIN" "$PROBE" 800 > "$WORK/probe.strs" 2>&1

# The probe must reach its own verdict line in BOTH runs, or it measured nothing
# and its silence must not read as success.
for f in base strs; do
    grep -q 'EXTROOTS ' "$WORK/probe.$f" || {
        echo "$TAG INCONCLUSIVE: the probe never printed a verdict in the $f run;"
        echo "$TAG   it died before it could check anything."
        sed -n '1,15p' "$WORK/probe.$f"; exit 125; }
done
# Un-stressed it must be OK, or the probe is asserting something the engine does
# not do and the stressed result would mean nothing.
grep -q 'EXTROOTS OK' "$WORK/probe.base" || {
    echo "$TAG INCONCLUSIVE: the probe fails WITHOUT the collector running, so"
    echo "$TAG   it is not measuring the root set. Fix the probe first."
    grep 'EXTROOTS' "$WORK/probe.base"; exit 125; }

probe_rc=0
if ! grep -q 'EXTROOTS OK' "$WORK/probe.strs"; then
    probe_rc=1
    echo "$TAG FAIL: the DOM lost a handle the collector freed underneath it."
    grep 'EXTROOTS' "$WORK/probe.strs"
    echo "$TAG   Each name is a table missing from _dom_gc_ext_roots"
    echo "$TAG   (lib/web/dom/canvas.ad)."
else
    echo "$TAG probe: every DOM-held handle survived a forced collection."
fi

# ---- PART B: differential sweep -------------------------------------------
# Scripted fixtures only: a fixture with no <script> never builds a DOM wrapper
# through the js_* boundary and so cannot exercise the root set.
mapfile -t FIX < <(grep -ril '<script' tests/fixtures/hambrowse_*.html 2>/dev/null | sort)
[ "${#FIX[@]}" -gt 0 ] || {
    echo "$TAG INCONCLUSIVE: no scripted fixtures found under tests/fixtures/."
    exit 125; }

ran=0; empty=0; diffs=0; timeouts=0
FAILED=""
for f in "${FIX[@]}"; do
    b="$(basename "$f" .html)"
    timeout 120 "$BIN" "$f" 800 > "$WORK/$b.base" 2>&1; rcb=$?
    HAMNIX_JS_GC_STRESS=1 timeout 600 "$BIN" "$f" 800 > "$WORK/$b.strs" 2>&1; rcs=$?
    if [ "$rcb" = 124 ] || [ "$rcs" = 124 ]; then
        timeouts=$((timeouts + 1)); FAILED="$FAILED $b(timeout)"; continue
    fi
    if [ ! -s "$WORK/$b.base" ]; then empty=$((empty + 1)); continue; fi
    ran=$((ran + 1))
    if ! cmp -s "$WORK/$b.base" "$WORK/$b.strs"; then
        diffs=$((diffs + 1)); FAILED="$FAILED $b"
    fi
done

echo "$TAG ${#FIX[@]} scripted fixtures; $ran compared, $empty produced no output"
if [ "$ran" -lt 20 ]; then
    echo "$TAG INCONCLUSIVE: only $ran fixtures produced comparable output; that"
    echo "$TAG   is not enough coverage to call the root set complete."
    exit 125
fi

if [ "$timeouts" != 0 ]; then
    echo "$TAG FAIL: $timeouts fixture(s) timed out under GC stress."
    echo "$TAG   A collector that cannot finish a fixture is its own defect."
fi
if [ "$diffs" != 0 ]; then
    echo "$TAG FAIL: $diffs fixture(s) rendered DIFFERENTLY with the collector"
    echo "$TAG   running. The DOM lost a handle the GC freed underneath it —"
    echo "$TAG   find the table and add it to _dom_gc_ext_roots"
    echo "$TAG   (lib/web/dom/canvas.ad). Diff: $WORK/<name>.base vs .strs"
fi
if [ "$diffs" != 0 ] || [ "$timeouts" != 0 ] || [ "$probe_rc" != 0 ]; then
    [ -n "$FAILED" ] && echo "$TAG  offenders:$FAILED"
    echo "$TAG RESULT: FAIL"
    exit 1
fi

echo "$TAG every render was byte-identical with the collector running."
echo "$TAG RESULT: PASS"
exit 0
