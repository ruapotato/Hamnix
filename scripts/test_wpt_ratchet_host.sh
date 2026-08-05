#!/usr/bin/env bash
# scripts/test_wpt_ratchet_host.sh — QEMU-FREE ratchet gate on the EXTERNAL
# browser conformance score: Web Platform Tests.
#
# WHY THIS GATE EXISTS
# ====================
# We have 275 hand-written host gates for the browser. Every one of them was
# written by us, which means every one encodes OUR belief about what correct
# is. On 2026-07-28 a single sweep found 16 of 19 gates in one family asserting
# behaviour Chromium does not have — the gates were green and the engine was
# wrong, in the same direction, because the same author wrote both.
#
# Web Platform Tests is the suite Chromium, WebKit and Gecko are actually scored
# against. It was not written by us, it cannot be quietly bent to match what the
# engine already does, and it is the only browser number here that a third party
# would recognise. tests/wpt/ vendors a pinned 708-test subset (see
# scripts/wpt_import.py for the vendored-not-fetched argument).
#
# WHAT IT ENFORCES
# ================
# A RATCHET, not a threshold. scripts/wpt_baseline.txt records every WPT subtest
# the engine does NOT pass today. This gate re-runs the suite and fails if:
#
#   * a subtest that is NOT in the baseline is now failing (a regression), or
#   * the total PASS count drops below the baseline's #!PASS_FLOOR.
#
# Lines LEAVING the baseline is the entire point; the gate says so and asks you
# to regenerate. The score may only go up.
#
#   bash scripts/test_wpt_ratchet_host.sh            # gate
#   bash scripts/test_wpt_ratchet_host.sh --regen    # bank fixes into baseline
#
# NOT SOFT-GREEN
# ==============
# Three outcomes (scripts/_verdict.sh): 0 PASS, 1 FAIL, 125 INCONCLUSIVE. If the
# vendored suite or python3 is missing, or the harness self-test cannot prove it
# still reports failure as failure, this reports 125 — never PASS. The
# self-test is load-bearing: a scraper that silently stops matching its own
# result lines would report zero failures, and zero failures against a baseline
# of 3,600 reads as a spectacular improvement rather than a broken instrument.
#
# ~2 min: engine compile + one pass over 708 tests (the run itself is ~60 s).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TAG="[wpt-ratchet]"
OUT="build/host"
BIN="$OUT/hambrowse_host"
BASELINE="scripts/wpt_baseline.txt"
JSONL="$OUT/wpt_run.jsonl"
REGEN=0
[ "${1:-}" = "--regen" ] && REGEN=1
mkdir -p "$OUT"

command -v python3 >/dev/null 2>&1 || {
    echo "$TAG INCONCLUSIVE: python3 absent; the runner could not execute."; exit 125; }
[ -f tests/wpt/MANIFEST.txt ] || {
    echo "$TAG INCONCLUSIVE: tests/wpt/ not vendored; nothing to measure."; exit 125; }
[ -f tests/wpt/tests/resources/testharness.js ] || {
    echo "$TAG INCONCLUSIVE: tests/wpt/tests/resources/testharness.js absent."; exit 125; }

echo "$TAG compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/wpt_compile.log"; then
    echo "$TAG FAIL: host harness did not compile"; cat "$OUT/wpt_compile.log"; exit 1
fi
echo "$TAG PASS host harness compiled -> $BIN"

# The instrument must be proven honest BEFORE its reading is trusted. Two
# synthetic testharness pages go through the real pipeline: one whose assertions
# hold (must report 2 PASS / 0 FAIL) and one whose assertions do not (must
# report 0 PASS / 2 FAIL). An always-green scraper dies here.
echo "$TAG proving the scraper still reports failure as failure ..."
if ! python3 scripts/wpt_run.py --selftest; then
    echo "$TAG INCONCLUSIVE: the WPT result scraper is not trustworthy;"
    echo "$TAG   its own positive/negative control failed, so any score it"
    echo "$TAG   produces is noise. Fix the harness before reading the number."
    exit 125
fi

echo "$TAG running the vendored WPT subset ..."
if ! python3 scripts/wpt_run.py --all --quiet --jsonl "$JSONL" >"$OUT/wpt_run.log" 2>&1; then
    rc=$?
    if [ "$rc" = 125 ]; then
        echo "$TAG INCONCLUSIVE: runner reported it could not observe anything"
        cat "$OUT/wpt_run.log"; exit 125
    fi
    echo "$TAG FAIL: runner exited $rc"; cat "$OUT/wpt_run.log"; exit 1
fi
tail -3 "$OUT/wpt_run.log"

# ARENA-TRUNCATED FILES. A file the engine ran out of arena part-way through
# still reports every subtest it reached, so its cut-off point lands in the
# score and then in the baseline as if it were conformance. It is not: it is a
# reading of the object arena, and it moves by ~100 subtests when anything
# before the page allocates. That is what reverted D8. `tail -3` above would
# scroll it away, so hoist it -- an instrument that knows it was measuring
# memory has to say so where the number is read.
if grep -q '^\[wpt\] TRUNCATED' "$OUT/wpt_run.log"; then
    echo "$TAG ------------------------------------------------------------"
    sed -n '/^\[wpt\] TRUNCATED/,$p' "$OUT/wpt_run.log" | sed "s|^|$TAG |"
    echo "$TAG WARNING: the subtest counts above are NOT conformance scores."
    echo "$TAG   Do not treat a delta on a truncated file as a regression or"
    echo "$TAG   a fix until the file RUNS TO COMPLETION."
    echo "$TAG ------------------------------------------------------------"
fi

lines="$(wc -l < "$JSONL")"
if [ "$lines" -lt 100 ]; then
    echo "$TAG INCONCLUSIVE: only $lines test records produced (expected ~708);"
    echo "$TAG   the run did not cover the suite, so the score is not comparable."
    exit 125
fi

if [ "$REGEN" = 1 ]; then
    python3 scripts/wpt_score.py "$JSONL" --baseline "$BASELINE" >/dev/null || exit 1
    echo "$TAG regenerated $BASELINE"
    grep '^#!PASS_FLOOR' "$BASELINE"
    exit 0
fi

[ -f "$BASELINE" ] || {
    echo "$TAG INCONCLUSIVE: $BASELINE absent; run --regen to establish it."; exit 125; }

if ! python3 scripts/wpt_score.py "$JSONL" --check-baseline "$BASELINE"; then
    echo "$TAG RESULT: FAIL — WPT conformance regressed."
    echo "$TAG   The score may only go up. If a listed subtest is newly failing"
    echo "$TAG   because of a deliberate change, fix the engine; do NOT edit a"
    echo "$TAG   vendored test and do NOT append to the baseline to silence it."
    exit 1
fi
echo "$TAG RESULT: PASS"
