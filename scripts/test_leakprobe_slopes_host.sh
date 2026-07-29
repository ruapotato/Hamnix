#!/usr/bin/env bash
# scripts/test_leakprobe_slopes_host.sh — QEMU-FREE gate on the soak slope
# estimator, scripts/leakprobe_slopes.py.
#
# WHY THIS GATE EXISTS
# ====================
# The number a leak hunt reports to the user is a SLOPE, and two phantom
# findings have already been reported from a wrong one:
#
#   * A series with a true flat +10 pg/cycle and ONE 16 MiB level shift
#     read as least-squares +104 / Theil-Sen +86. The pass concluded there
#     was "a second mechanism accelerating late". There was no second
#     mechanism. There was one step.
#   * The follow-up "robust" estimator was contaminated by the same step:
#     with 42 pre / 26 post samples, ~47% of Theil-Sen's pairs straddled it.
#
# A wrong slope is worse than no slope: it sends the next pass hunting a
# mechanism that does not exist. So the estimator itself is gated, on
# synthetic series whose true rate is known by construction:
#
#   1. +10/cycle with one 4096-page step   -> steady MUST recover +10,
#                                             least-squares MUST NOT, and
#                                             the tool MUST warn.
#   2. +10/cycle with two steps            -> Theil-Sen MUST also break
#                                             (one step straddles at most
#                                             50% of its pairs and survives
#                                             by a hair; two straddle ~2/3).
#   3. +10/cycle, no step                  -> all three MUST converge and
#                                             the tool MUST NOT warn. That
#                                             agreement is the signature of
#                                             an uncontaminated series.
#   4. sub-1.5/cycle drift                 -> MUST report NOISE, never a
#                                             rate (run-to-run spread on
#                                             IDENTICAL code is >= 1.5).
#   5. a pure step with no trend           -> steady MUST read ~0.
#
# Plus an end-to-end parse of a soak-shaped log, including the allocation
# tracker's `PgSite<N>: live allocs frees` lines, so the format contract
# between mm/page_alloc.ad, sys/src/9/port/devmeminfo.ad and this tool is
# gated rather than assumed.
#
# Runs in well under a second and needs no guest.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TAG="[leakprobe_slopes]"
TOOL=scripts/leakprobe_slopes.py
fail=0

[ -f "$TOOL" ] || { echo "$TAG FAIL: $TOOL missing" >&2; exit 1; }

echo "$TAG (1/3) estimator selftest"
if python3 "$TOOL" --selftest; then
    echo "$TAG   selftest PASS"
else
    echo "$TAG FAIL: estimator selftest reported failures" >&2
    fail=1
fi

# ---------------------------------------------------------------------
# (2) End-to-end on a synthetic soak log: the tool must find the leaking
#     site and must NOT invent a leak at the quiet ones.
# ---------------------------------------------------------------------
echo "$TAG (2/3) end-to-end on a synthetic soak log"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
python3 - "$LOG" <<'PY'
import sys, random
rng = random.Random(11)
out = []
for c in range(60):
    lbl = "c%dclosed" % c
    out.append("echo SOAKSMP_%s_B; cat /proc/meminfo; echo SOAKSMP_%s_E" % (lbl, lbl))
    out.append("SOAKSMP_%s_B" % lbl)
    out.append("MemTotal: 873959 kB")
    # cow_resolve_pte leaks +9/cycle; the anon-fault site is flat; a
    # 16 MiB (4096-page) step lands on the total at cycle 38.
    out.append("PgSite11: %d %d %d" % (200 + 9 * c + rng.randint(-2, 2),
                                       900 + 40 * c, 700 + 31 * c))
    out.append("PgSite6: %d %d %d" % (500 + rng.randint(-2, 2),
                                      4000 + 120 * c, 4000 + 120 * c))
    out.append("PagesInUse: %d" % (50000 + 10 * c + (4096 if c >= 38 else 0)))
    out.append("SOAKSMP_%s_E" % lbl)
open(sys.argv[1], "w").write("\n".join(out) + "\n")
PY

OUT="$(python3 "$TOOL" "$LOG" --json)"
py_get() { python3 -c "
import json,sys
d=json.loads(sys.stdin.read())['counters']
print(d.get('$1',{}).get('$2','MISSING'))
" <<<"$OUT"; }

check() {  # check <desc> <python-bool-expr-over-value> <value>
    local desc="$1" ok="$2" detail="$3"
    if [ "$ok" = "True" ]; then
        echo "$TAG   ok   $desc ($detail)"
    else
        echo "$TAG FAIL $desc ($detail)" >&2
        fail=1
    fi
}

COW_KEY='PgSite11:cow_resolve_pte.live'
ANON_KEY='PgSite6:vma_anon.live'

v="$(py_get "$COW_KEY" steady)"
check "cow_resolve_pte.live slopes to +9" \
      "$(python3 -c "print(abs(float('$v')-9)<0.6)")" "steady=$v"

v="$(py_get "$COW_KEY" noise)"
check "cow_resolve_pte.live is above the noise floor" \
      "$(python3 -c "print('$v'=='False')")" "noise=$v"

v="$(py_get "$ANON_KEY" noise)"
check "vma_anon.live is correctly reported as NOISE" \
      "$(python3 -c "print('$v'=='True')")" "noise=$v"

v="$(py_get PagesInUse steady)"
check "PagesInUse steady survives the 4096-page step" \
      "$(python3 -c "print(abs(float('$v')-10)<1.0)")" "steady=$v"

v="$(py_get PagesInUse ls)"
check "PagesInUse least-squares is visibly contaminated by the step" \
      "$(python3 -c "print(float('$v')>40)")" "ls=$v"

v="$(py_get PagesInUse contaminated)"
check "PagesInUse is FLAGGED as estimator-disagreement" \
      "$(python3 -c "print('$v'=='True')")" "contaminated=$v"

v="$(py_get PagesInUse steps)"
check "the step is located" \
      "$(python3 -c "print(len($v)==1)")" "steps=$v"

# ---------------------------------------------------------------------
# (3) The human-readable report must SAY which estimator to believe, and
#     must carry the short-soak caution when the series is too short.
# ---------------------------------------------------------------------
echo "$TAG (3/3) report wording"
TXT="$(python3 "$TOOL" "$LOG")"
grep -q "BELIEVE \`steady\` ONLY" <<<"$TXT" \
    || { echo "$TAG FAIL: report does not name the trustworthy estimator" >&2; fail=1; }
grep -q "agree (uncontaminated)" <<<"$TXT" \
    || { echo "$TAG FAIL: report never marks a clean series as agreeing" >&2; fail=1; }

head -12 "$LOG" > "${LOG}.short"
SHORT="$(python3 "$TOOL" "${LOG}.short" 2>&1)"
rm -f "${LOG}.short"
grep -q "SHORT SOAK" <<<"$SHORT" \
    || { echo "$TAG FAIL: no short-soak caution on a 1-cycle log" >&2; fail=1; }

if [ "$fail" = 0 ]; then
    echo "$TAG PASS"
else
    echo "$TAG FAIL"
fi
exit "$fail"
