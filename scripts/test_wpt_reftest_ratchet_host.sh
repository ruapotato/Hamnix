#!/usr/bin/env bash
# scripts/test_wpt_reftest_ratchet_host.sh — QEMU-FREE ratchet gate on the WPT
# REFTEST score: CSS PIXEL conformance.
#
# WHY THIS GATE EXISTS
# ====================
# The WPT import (scripts/wpt_import.py) took only testharness.js tests and
# skipped every reftest, on the grounds that pixel comparison was
# "framediff_gfx_all.sh's job". It was not. framediff_gfx_all.sh renders TEN
# corpus pages and scores them against Chromium/Firefox screenshots — a PARITY
# instrument. css/CSS2 alone holds ~6,265 reftests, and they are the largest
# body of external evidence that exists about whether a layout engine is
# correct. Skipping them meant the CSS box model had no external gate at all.
#
# A reftest is a test document plus a <link rel="match"> (or "mismatch")
# reference. The pass condition is that the two render IDENTICALLY (or
# differently). Both go through OUR renderer, so — unlike the framediff lane —
# there is no cross-engine font or anti-aliasing question, and the comparison is
# EXACT: zero fuzz. See scripts/wpt_reftest_run.py for the measurement behind
# that choice.
#
# WHAT IT ENFORCES
# ================
# A RATCHET, not a threshold. scripts/wpt_reftest_baseline.txt records every
# reftest the engine does not pass today, plus the set that DOES pass. This gate
# re-runs the lane and fails if:
#
#   * a reftest that PASSED at baseline no longer passes, or
#   * the total PASS count drops below the baseline's #!PASS_FLOOR.
#
# The floor guards an ABSOLUTE count, never a ratio. The scored denominator is
# PASS+FAIL and it MOVES: a pair excluded as NONDISCRIMINATING (a null engine
# with no CSS would also satisfy it) becomes discriminating the moment the
# engine starts honouring the property, entering the denominator — usually as a
# FAIL at first. A real fix can therefore LOWER the ratio. An absolute floor
# only ever asks "are we still passing at least as many real tests as before".
#
#   bash scripts/test_wpt_reftest_ratchet_host.sh            # gate
#   bash scripts/test_wpt_reftest_ratchet_host.sh --regen    # bank fixes
#
# NOT SOFT-GREEN
# ==============
# Three outcomes (scripts/_verdict.sh): 0 PASS, 1 FAIL, 125 INCONCLUSIVE. If the
# vendored reftests are missing, python3/PIL is absent, the pixel backend does
# not build, or the harness cannot prove it still reports failure as failure,
# this reports 125 — never PASS.
#
# The self-test is load-bearing in a way specific to a PIXEL lane. Two ways this
# instrument could go quietly always-green:
#   (a) the comparator stops distinguishing images, so every pair "matches";
#   (b) the renderer becomes non-deterministic, so exact equality stops being a
#       valid pass condition at all.
# scripts/wpt_reftest_run.py --selftest drives synthetic positive, negative,
# mismatch-holds, mismatch-violated, nondiscriminating and DETERMINISM controls
# through the real pipeline and fails unless every one lands on its expected
# verdict.
#
# ~40 s: pixel-backend compile (~21 s) + ~300 renders at ~13 ms each.
#
# RUN SERIALLY with the other pixel gates. This gate rebuilds
# build/host/hambrowse_gfx, the SAME artifact every test_hambrowse_*_host.sh /
# scripts/framediff_gfx_*.sh uses. Two of them at once race on that path.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TAG="[wpt-reftest]"
OUT="build/host"
BIN="$OUT/hambrowse_gfx"
BASELINE="scripts/wpt_reftest_baseline.txt"
JSONL="$OUT/wpt_reftest.jsonl"
REGEN=0
[ "${1:-}" = "--regen" ] && REGEN=1
mkdir -p "$OUT"

command -v python3 >/dev/null 2>&1 || {
    echo "$TAG INCONCLUSIVE: python3 absent; the runner could not execute."
    exit 125; }
[ -f tests/wpt/REFTEST_MANIFEST.txt ] || {
    echo "$TAG INCONCLUSIVE: tests/wpt/REFTEST_MANIFEST.txt absent;"
    echo "$TAG   the reftests are not vendored, so there is nothing to measure."
    exit 125; }

echo "$TAG compiling the PIXEL backend for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$BIN" \
        >"$OUT/wpt_reftest_compile.log" 2>&1; then
    echo "$TAG FAIL: pixel backend did not compile"
    tail -30 "$OUT/wpt_reftest_compile.log"; exit 1
fi
echo "$TAG PASS pixel backend compiled -> $BIN"

# The instrument must be proven honest BEFORE its reading is trusted.
echo "$TAG proving the comparator still reports failure as failure ..."
if ! python3 scripts/wpt_reftest_run.py --selftest; then
    echo "$TAG INCONCLUSIVE: the reftest comparator is not trustworthy;"
    echo "$TAG   one of its positive / negative / mismatch / nondiscriminating /"
    echo "$TAG   determinism controls landed on the wrong verdict, so any score"
    echo "$TAG   it produces is noise. Fix the harness before reading a number."
    exit 125
fi

echo "$TAG running the vendored reftest lane ..."
python3 scripts/wpt_reftest_run.py --all --quiet --jsonl "$JSONL" \
    >"$OUT/wpt_reftest_run.log" 2>&1
rc=$?
if [ "$rc" = 125 ]; then
    echo "$TAG INCONCLUSIVE: runner reported it could not observe anything"
    cat "$OUT/wpt_reftest_run.log"; exit 125
elif [ "$rc" != 0 ]; then
    echo "$TAG FAIL: runner exited $rc"; cat "$OUT/wpt_reftest_run.log"; exit 1
fi
tail -4 "$OUT/wpt_reftest_run.log"

expected="$(grep -vc '^#' tests/wpt/REFTEST_MANIFEST.txt)"
lines="$(wc -l < "$JSONL")"
if [ "$lines" -lt "$expected" ]; then
    echo "$TAG INCONCLUSIVE: $lines records produced but the manifest lists"
    echo "$TAG   $expected reftests; the run did not cover the lane, so the"
    echo "$TAG   score is not comparable to the baseline."
    exit 125
fi

# An all-ERROR run means the renderer produced nothing at all: zero failures
# against a baseline reads as a spectacular improvement rather than a broken
# instrument, so refuse to score it.
if ! python3 - "$JSONL" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
err = sum(1 for r in recs if r["verdict"] == "ERROR")
sys.exit(1 if recs and err == len(recs) else 0)
PY
then
    echo "$TAG INCONCLUSIVE: every reftest reported ERROR — no document rendered."
    exit 125
fi

if [ "$REGEN" = 1 ]; then
    python3 scripts/wpt_reftest_score.py "$JSONL" --baseline "$BASELINE" || exit 1
    echo "$TAG regenerated $BASELINE"
    grep '^#!PASS_FLOOR' "$BASELINE"
    exit 0
fi

[ -f "$BASELINE" ] || {
    echo "$TAG INCONCLUSIVE: $BASELINE absent; run --regen to establish it."
    exit 125; }

if ! python3 scripts/wpt_reftest_score.py "$JSONL" --check-baseline "$BASELINE"; then
    echo "$TAG RESULT: FAIL — CSS reftest conformance regressed."
    echo "$TAG   The score may only go up. Do NOT edit a vendored test or"
    echo "$TAG   reference, and do NOT append to the baseline to silence a"
    echo "$TAG   failure: fix the engine. Exclusions belong in"
    echo "$TAG   tests/wpt/REFTEST_EXCLUSIONS.md and may never be 'it fails'."
    exit 1
fi
echo "$TAG RESULT: PASS"
