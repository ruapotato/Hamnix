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
#   * a reftest that PASSED at baseline no longer passes,
#   * the PASS count drops below #!PASS_FLOOR,
#   * the NONDISCRIMINATING count rises above #!ND_CEILING,
#   * a test in the baseline produces no record at all (coverage shrank), or
#   * #!TREE_SHA256 stops matching -- a vendored test/reference was edited, or a
#     row was deleted from the manifest to launder a failure out of the lane.
#
# and reports INCONCLUSIVE (125), not FAIL, when a document that used to RENDER
# no longer does (#!ERROR_CEILING): that is the absence of an observation, not a
# conformance result.
#
# #!ND_CEILING is the clause that actually has teeth while #!PASS_FLOOR is 0. A
# pair goes NONDISCRIMINATING when an engine with NO CSS at all would satisfy it
# too. So if the engine stops applying float placement or margin collapsing,
# those pairs LEAVE the scored denominator, the pass floor is still met (0 >= 0)
# and the error ceiling is still met -- a total loss of the tranche's subject
# matter would otherwise exit 0.
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
#   ... --regen --allow-loosen   # ONLY when the lane itself changed (a new area
#                                # imported, an exclusion lifted). Without it,
#                                # regeneration REFUSES to relax any marker, so
#                                # the documented way to bank a fix cannot also
#                                # bank a regression.
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
ALLOW_LOOSEN=""
for a in "$@"; do
    case "$a" in
        --regen)        REGEN=1 ;;
        --allow-loosen) ALLOW_LOOSEN=1 ;;
    esac
done
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

# Count manifest rows with the SAME parser the runner uses. `grep -vc '^#'`
# counted blank lines, indented comments and malformed rows that load_manifest()
# drops, so a single stray newline in the manifest wedged the gate at
# INCONCLUSIVE with a misleading "did not cover the lane" forever.
expected="$(python3 -c '
import sys; sys.path.insert(0, "scripts")
import wpt_reftest_run as R; print(len(R.load_manifest()))' 2>/dev/null)"
lines="$(wc -l < "$JSONL")"
if [ -z "$expected" ] || [ "$lines" -ne "$expected" ]; then
    echo "$TAG INCONCLUSIVE: $lines records produced but the manifest lists"
    echo "$TAG   ${expected:-?} reftests; the run did not cover the lane, so the"
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
    python3 scripts/wpt_reftest_score.py "$JSONL" --baseline "$BASELINE" \
        ${ALLOW_LOOSEN:+--allow-loosen} || exit 1
    echo "$TAG regenerated $BASELINE"
    grep '^#!' "$BASELINE"
    exit 0
fi

[ -f "$BASELINE" ] || {
    echo "$TAG INCONCLUSIVE: $BASELINE absent; run --regen to establish it."
    exit 125; }

python3 scripts/wpt_reftest_score.py "$JSONL" --check-baseline "$BASELINE"
src=$?
if [ "$src" = 125 ]; then
    # An un-observation is not a conformance verdict. A document that stopped
    # rendering, or an unreadable baseline, means the assertion could not be
    # evaluated -- report the absence of evidence, do not call it a regression.
    echo "$TAG INCONCLUSIVE: the lane could not be scored against the baseline."
    exit 125
elif [ "$src" != 0 ]; then
    echo "$TAG RESULT: FAIL — CSS reftest conformance regressed."
    echo "$TAG   The score may only go up. Do NOT edit a vendored test or"
    echo "$TAG   reference, and do NOT append to the baseline to silence a"
    echo "$TAG   failure: fix the engine. Exclusions belong in"
    echo "$TAG   tests/wpt/REFTEST_EXCLUSIONS.md and may never be 'it fails'."
    exit 1
fi
echo "$TAG RESULT: PASS"
