#!/usr/bin/env bash
# scripts/test_leak_hours_report_mutations.sh — MUTATION-TEST the hours-scale
# census adjudicator (scripts/leak_hours_census_report.py).
#
# WHY THIS EXISTS
# ===============
# scripts/test_leak_hours_census.sh needs a TWO-HOUR KVM boot to produce a log.
# Nobody re-runs that to check that its verdict logic still catches anything,
# which is exactly how a gate rots into a green that means nothing. Three
# separate passes of this campaign caught a FALSE GREEN inside their own
# tooling — a survivor walk that stopped at 64 over a population of 101, arms
# whose zero meant "nobody recorded an owner", a gate carrying
# `[ -e /dev/kvm ] || exit 0`. A green from a blind instrument is worse than a
# red.
#
# So the adjudicator is a separate file, and this gate feeds it SYNTHETIC logs:
# one clean, then one per failure mode, each differing from the clean one in
# exactly one respect. Every mutation must change the verdict. A mutation that
# still reports PASS is a hole in the instrument, and this gate FAILS on it.
#
# It needs no QEMU, no KVM and no image — so it runs everywhere, including on
# the KVM-less CI runners where the real gate correctly reports INCONCLUSIVE.
# That is the point: the expensive gate proves the machine, this cheap gate
# proves the expensive gate can still say no.
#
# Verdict codes under test (scripts/_verdict.sh): 0 PASS, 1 FAIL, 125 INCONCLUSIVE.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
TAG="[hourscens-mut]"

REPORT="$PROJ_ROOT/scripts/leak_hours_census_report.py"
[ -f "$REPORT" ] || {
    echo "$TAG INCONCLUSIVE: $REPORT absent — nothing to mutate" >&2; exit 125; }

WORK=$(mktemp -d --tmpdir hamnix-hcmut.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]

def sample(s, sites, arms, orgl, tasks, statm, plant, unacc, inrun,
           trunc=(), pos=True, neg=True, cens3=True, plant_line=True):
    L = ["HC_SAMPLE %s" % s]
    for k, v in sorted(sites.items()):
        L.append("[trk] site=%d live=%d allocs=%d" % (k, v, v * 3))
    L.append("HC_TRK_%s" % s)
    for a, (b, d) in sorted(arms.items()):
        L.append("[origin] org=%d born=%d died=%d" % (a, b, d))
    L.append("HC_ORG_%s" % s)
    for a, e in sorted(orgl.items()):
        L.append("[orgl] org=%d TOTAL=%d owner-live=%d"
                 % (a, e['total'], e['total'] - e['dead']))
        L.append("[orgl] org=%d owner-dead=%d owner-unrecorded=%d"
                 % (a, e['dead'], e['unrec']))
        L.append("[orgl] org=%d owner-stray=%d owner-untagged=%d"
                 % (a, e['stray'], e.get('untagged', 0)))
        L.append("HC_ORGL_%s_%d" % (s, a))
    L.append("PID\tSTATE\tCOMM\tUTIME\tSTIME")
    for p, c in sorted(tasks.items()):
        L.append("%d\tRUN\t%s\t10\t3" % (p, c))
    L.append("HC_TASKS_%s" % s)
    for p, r in sorted(statm.items()):
        L.append("HC_STATM %s %d" % (s, p))
        L.append("%d %d 0 1 0 %d 0" % (r + 20, r, r))
        L.append("HC_STATMEND_%s_%d" % (s, p))
    if plant_line:
        L.append("[census] planted control orphan phys=0x%x tag=0xc0ffee00" % plant)
    L.append("HC_PLANT_%s" % s)
    L.append("[census] planted MAPPED control phys=0x22222000 va=0x7f0000000000")
    L.append("HC_MPLANT_%s" % s)
    n_unacc = sum(unacc.values())
    n_inrun = sum(ir for _, ir in inrun.values())
    L.append("[census] orphaned frames: %d (of 100000 live)" % (n_unacc + n_inrun))
    if pos:
        L.append("[census] control OK: planted orphan detected (%d orphan(s) "
                 "total, control included)" % (n_unacc + n_inrun))
    if neg:
        L.append("[census] negative control OK: mapped frame at "
                 "va=0x7f0000000000 (slot 3) marked reachable, not counted.")
    if cens3:
        for site, n in sorted(unacc.items()):
            # The plant is the FIRST orphan of its site, printed by phys, which
            # is what lets the adjudicator discount it.
            if plant_line and site == 6:
                L.append("[cens3] site %d orphan[0] phys=0x%x" % (site, plant))
            for k in range(1, n):
                L.append("[cens3] site %d orphan[%d] phys=0x%x"
                         % (site, k, 0x30000000 + k * 0x1000))
            L.append("[cens3] site %d: %d orphan(s) collected, 0 inside a live "
                     "task's wholesale run" % (site, n))
            L.append("[cens3] site %d: %d UNACCOUNTED (in no live run)" % (site, n))
        for site, (n, ir) in sorted(inrun.items()):
            L.append("[cens3] site %d: %d orphan(s) collected, %d inside a live "
                     "task's wholesale run" % (site, n, ir))
        for site in trunc:
            L.append("[cens3] site %d: TRUNCATED - tallied 200, collected only "
                     "64; this run-check covered a PREFIX and is INCONCLUSIVE "
                     "for this site" % site)
    L.append("HC_CENSUS_%s" % s)
    L += ["HC_UNPL_%s" % s, "HC_UNMP_%s" % s, "HC_KM_%s" % s]
    L.append("HC_SAMPLE_END %s" % s)
    return "\n".join(L) + "\n"


PLANT = 0x14e13000
TASKS = {1: 'init', 4: 'hamUId', 7: 'hampanel', 9: 'hamsh'}
STATM_A = {1: 30, 4: 400, 7: 120, 9: 542}
SITES_A = {6: 2000, 9: 300, 13: 500, 20: 64}
ARMS_A = {1: (100, 100), 5: (40, 30), 23: (12, 12)}
ORGL = {1: dict(total=101, dead=0, unrec=0, stray=0, untagged=101),
        5: dict(total=10, dead=0, unrec=0, stray=0, untagged=0),
        23: dict(total=44, dead=0, unrec=0, stray=0, untagged=0)}
# The clean pair: only the plant is unaccounted, one execve frame lies inside a
# live run, and the machine is quiet.
CLEAN = dict(plant=PLANT, unacc={6: 1}, inrun={20: (1, 1)})


def write(name, a_kw, b_kw, gap=7200):
    d = os.path.join(work, name)
    os.makedirs(d, exist_ok=True)
    ka = dict(sites=SITES_A, arms=ARMS_A, orgl=ORGL, tasks=TASKS,
              statm=STATM_A, **CLEAN)
    ka.update(a_kw)
    kb = dict(ka)
    kb.update(b_kw)
    with open(os.path.join(d, 'serial.log'), 'w') as f:
        f.write(sample('A', **ka))
        f.write("HC_ALIVE 1\nHC_ALIVE 2\n")
        f.write(sample('B', **kb))
    with open(os.path.join(d, 'stamps'), 'w') as f:
        f.write("A 1000000\nB %d\n" % (1000000 + gap))


# name -> (expected exit code, description)
CASES = {}


def merged(base, extra):
    # dict(base, **extra) is unavailable here: these dicts are keyed by INT
    # (pid / site), and ** requires string keys.
    d = dict(base)
    d.update(extra)
    return d


def case(name, a, b, rc, why, gap=7200):
    write(name, a, b, gap)
    CASES[name] = (rc, why)


case('clean', {}, {}, 0, 'a quiet pair: only the plant is unaccounted')
case('gap_too_short', {}, {}, 125,
     'four minutes is not "hours apart"', gap=240)
case('no_pos_control_B', {}, dict(pos=False), 125,
     'a census with no positive control cannot tell blind from clean')
case('no_neg_control_A', dict(neg=False), {}, 125,
     'a census with no negative control cannot tell over-reporting from real')
case('no_cens3', {}, dict(cens3=False), 125,
     'no run predicate: unreachable frames are unadjudicated')
case('no_plant_phys', {}, dict(plant_line=False), 125,
     'a plant you cannot identify cannot be discounted')
case('predicate_overclaims', {}, dict(unacc={}), 1,
     'zero UNACCOUNTED while a plant is outstanding = over-claiming')
case('real_orphan_in_B', {}, dict(unacc={6: 1, 20: 3}), 1,
     'three frames at site 20 lie in no live run')
case('orphans_grew', dict(unacc={6: 1, 20: 2}), dict(unacc={6: 1, 20: 5}), 1,
     'unaccounted frames grew across the gap')
case('truncated_site', {}, dict(trunc=(6,)), 125,
     'a run-check that covered a prefix is not clean')
case('arm_owner_dead', {},
     dict(arms={1: (100, 100), 5: (60, 30), 23: (12, 12)},
          orgl={1: ORGL[1],
                5: dict(total=40, dead=7, unrec=0, stray=0, untagged=0),
                23: ORGL[23]}), 1,
     'arm 5 grew and 7 survivors are owned by DEAD tasks')
case('arm_owner_vacuous', {},
     dict(arms={1: (100, 100), 5: (60, 30), 23: (12, 12)},
          orgl={1: ORGL[1],
                5: dict(total=40, dead=0, unrec=40, stray=0, untagged=0),
                23: ORGL[23]}), 125,
     'owner-dead=0 over a population with NO recorded owner is vacuous')
case('growth_past_bar', {}, dict(sites={6: 2000, 9: 300, 13: 500, 20: 964}), 1,
     '900 pages in two idle hours with an unchanged task set')
case('growth_but_new_process', {},
     dict(sites={6: 2000, 9: 300, 13: 500, 20: 964},
          tasks=merged(TASKS, {31: 'hamwrite'}),
          statm=merged(STATM_A, {31: 900})), 0,
     'the same growth, but a process STARTED — not attributable to steady state')
case('statm_blind', dict(statm={}), dict(statm={}), 125,
     'no long-lived process yielded a resident reading: a blind arm')
case('no_sample_B', {}, {}, 125, 'only one sample was taken')
case('longlived_grew_under_bar', {},
     dict(statm=merged(STATM_A, {7: 190})), 0,
     'the panel grew 70 pages: named in the report, under the bar')

# `no_sample_B` needs its B half deleted after the fact.
p = os.path.join(work, 'no_sample_B', 'serial.log')
txt = open(p).read()
open(p, 'w').write(txt.split('HC_SAMPLE B')[0])

with open(os.path.join(work, 'cases.txt'), 'w') as f:
    for n, (rc, why) in CASES.items():
        f.write('%s %d %s\n' % (n, rc, why))
PY

[ -f "$WORK/cases.txt" ] || {
    echo "$TAG INCONCLUSIVE: synthetic log generation produced nothing" >&2
    exit 125; }

ncase=0
nfail=0
while read -r name want why; do
    ncase=$((ncase + 1))
    out="$WORK/$name/report.txt"
    python3 "$REPORT" "$WORK/$name/serial.log" "$WORK/$name/stamps" 3600 256 \
        > "$out" 2>&1
    got=$?
    lbl() { case "$1" in 0) echo PASS;; 1) echo FAIL;; 125) echo INCONCLUSIVE;;
                         *) echo "rc=$1";; esac; }
    if [ "$got" -eq "$want" ]; then
        printf '%s   ok   %-26s -> %-12s (%s)\n' "$TAG" "$name" "$(lbl "$got")" "$why"
    else
        printf '%s   BAD  %-26s -> %-12s, expected %-12s (%s)\n' \
            "$TAG" "$name" "$(lbl "$got")" "$(lbl "$want")" "$why" >&2
        sed -n '/^OK:\|^INCON:\|^BAD:\|^VERDICT/p' "$out" | head -20 >&2
        nfail=$((nfail + 1))
    fi
done < "$WORK/cases.txt"

# A mutation table that shrank to nothing would pass vacuously — the failure
# mode this whole gate is about. Assert its own population.
if [ "$ncase" -lt 15 ]; then
    echo "$TAG INCONCLUSIVE: only $ncase mutation(s) ran; the table has been" >&2
    echo "$TAG   gutted and a green from it means nothing" >&2
    exit 125
fi
if [ "$nfail" -ne 0 ]; then
    echo "$TAG FAIL: $nfail of $ncase mutations did not change the verdict —" >&2
    echo "$TAG   the hours-scale adjudicator is blind to them" >&2
    exit 1
fi
echo "$TAG PASS — all $ncase mutations were caught by"
echo "$TAG   scripts/leak_hours_census_report.py"
exit 0
