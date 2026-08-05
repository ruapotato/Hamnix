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
        # The per-survivor detail the kernel prints BEFORE the tallies
        # (kernel/sched/core.ad), capped there at 64 frames. `detail` is a list
        # of (site, va, unrecorded) triples; omitting it reproduces a log in
        # which the detail was never captured, which is itself a case.
        for i, (site, va, unrec) in enumerate(e.get('detail', ())):
            L.append("[orgl] org=%d live[%d] phys=0x%x" % (a, i, 0xb100000 + i * 0x1000))
            L.append("[orgl] live[%d] va=0x%016x site=%d" % (i, va, site))
            L.append("[orgl] live[%d] cow_refcount=1" % i)
            if unrec:
                L.append("[orgl] live[%d] owner: NOT RECORDED" % i)
            else:
                L.append("[orgl] live[%d] owner slot=%d live=1" % (i, 3))
                L.append("[orgl] live[%d] owner pid=%d" % (i, 6))
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


LABELS = 'ABCDEFGH'


def write_n(name, per_sample, gaps):
    """An N-sample log (leak pass 21). `per_sample` is a list of overrides,
    one per sample; `gaps` is the N-1 inter-sample gaps in seconds."""
    d = os.path.join(work, name)
    os.makedirs(d, exist_ok=True)
    base = dict(sites=SITES_A, arms=ARMS_A, orgl=ORGL, tasks=TASKS,
                statm=STATM_A, **CLEAN)
    t = 1000000
    stamps = []
    with open(os.path.join(d, 'serial.log'), 'w') as f:
        for i, over in enumerate(per_sample):
            k = dict(base)
            k.update(over)
            f.write(sample(LABELS[i], **k))
            f.write("HC_ALIVE %d\n" % (i + 1))
            stamps.append((LABELS[i], t))
            if i < len(gaps):
                t += gaps[i]
    with open(os.path.join(d, 'stamps'), 'w') as f:
        for lb, ts in stamps:
            f.write("%s %d\n" % (lb, ts))


# name -> (expected exit code, extra adjudicator args, description)
CASES = {}


def merged(base, extra):
    # dict(base, **extra) is unavailable here: these dicts are keyed by INT
    # (pid / site), and ** requires string keys.
    d = dict(base)
    d.update(extra)
    return d


def case(name, a, b, rc, why, gap=7200, boot_armed=False):
    write(name, a, b, gap)
    if boot_armed:
        prepend_boot_arm(name)
    CASES[name] = (rc, '2', why)


def prepend_boot_arm(name):
    """Put pass 22's bringup marker at the top of a case's log.

    This is the ONLY difference between `arm_unrec_prearming` and
    `arm_unrec_prearming_boot_armed`, and it has to flip the verdict: the
    per-frame evidence is byte-identical and it means the opposite thing
    depending on whether a pre-arming population could exist at all.
    """
    p = os.path.join(work, name, 'serial.log')
    with open(p) as f:
        body = f.read()
    with open(p, 'w') as f:
        f.write("[000196] [trk] boot-arm mode=2 frames=261632\n"
                "[000197] [trk] boot-arm bytes=3401216 site0=0\n")
        f.write(body)


def ncase(name, per_sample, rc, why, gaps=None, min_samples=2):
    """A pass-21 N-sample case. Default cadence: 2 h between samples."""
    if gaps is None:
        gaps = [7200] * (len(per_sample) - 1)
    write_n(name, per_sample, gaps)
    CASES[name] = (rc, str(min_samples), why)


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
# Leak pass 20. The pass-19 adjudicator's ONLY growth assertion was on the
# TOTAL, and a total is cancellable: site 9 (pgtable, a KERNEL site the orphan
# census explicitly does not judge) takes 900 pages while site 6 returns 900,
# and the machine's page count is unchanged. Every word of the pass-19 verdict
# stayed true and the report said PASS — over a run in which a kernel site grew
# 900 pages in a gap where nothing was launched. That is exactly the
# "per-site attribution, not just a global total" rule this campaign keeps
# writing down, missing from the instrument that enforces it.
case('site_swap_nets_zero', {},
     dict(sites={6: 1100, 9: 1200, 13: 500, 20: 64}), 1,
     'a kernel site grew 900 pages; the TOTAL is unchanged and cancels it')
# The negative control for that rule, and it is the one that matters: pass 19's
# REAL run moved -151/+31/+2/+2 across four sites, i.e. frames returned by the
# un-attributed population and re-allocated WITH attribution. Per-site motion
# well under the bar must stay green, or the rule above turns every honest run
# red and gets deleted.
case('site_motion_under_bar', {},
     dict(sites={6: 2031, 9: 302, 13: 500, 20: 64, 0: 0}), 0,
     'pass 19\'s real per-site motion (+31/+2) is not a leak')
# The RE-ATTRIBUTION CREDIT. Site 0 holds the population that was already live
# when the tracker was armed; it can only shrink, and its frames reappear at
# real sites as they are recycled. Pass 19 measured exactly this (-151 against
# +31/+2/+2) and the effect grows with the gap. Frames are counted, not
# identity-tracked, so "site 0 recycled into pgtable" and "pgtable leaked while
# unrelated unknown frames were freed" are the same numbers: INCONCLUSIVE is
# the only honest verdict, and calling it PASS would be the false green this
# whole gate exists to avoid.
case('site_grew_from_unknown',
     dict(sites={0: 5000, 6: 2000, 9: 300, 13: 500, 20: 64}),
     dict(sites={0: 4100, 6: 2000, 9: 1200, 13: 500, 20: 64}), 125,
     'site 9 +900 fully covered by site 0 -900: unadjudicated, not clean')
# Partial credit must NOT launder the residual: 100 pages of the 900 are
# explainable and 800 are not, so this is a FAIL on the 800.
case('site_grew_partial_credit',
     dict(sites={0: 5000, 6: 2000, 9: 300, 13: 500, 20: 64}),
     dict(sites={0: 4900, 6: 2000, 9: 1200, 13: 500, 20: 64}), 1,
     'only 100 of 900 is re-attribution; the residual 800 is a leak')
# Site 0 itself growing is condemned by the TOTAL bar, not exempted: an
# untagged allocation path is the one bucket whose growth cannot be acted on.
case('unknown_site_grew',
     dict(sites={0: 5000, 6: 2000, 9: 300, 13: 500, 20: 64}),
     dict(sites={0: 5900, 6: 2000, 9: 300, 13: 500, 20: 64}), 1,
     'the unattributed bucket itself grew 900 pages')

# =========================================================================
# LEAK PASS 21 — THE TREND ARM. N >= 3 samples on one boot.
# =========================================================================
# Everything above is an ENDPOINT rule against an absolute page bar, and pass
# 20 proved out both of its blind spots on real data:
#
#   * an absolute bar cannot see a slow LINEAR leak — 90 pages over 6 hours is
#     96 MiB/year of unbounded accumulation and sails under a 256-page bar;
#   * a SETTLE and a LEAK print the SAME endpoint delta. Pass 20 measured site 6
#     going 1 -> 38 and could say nothing about which it was.
#
# These cases are the discrimination. Every one of them keeps the ENDPOINT
# verdict at PASS and differs only in the shape of the curve, which is the
# whole point: if the trend arm regresses, these go green and the endpoint arm
# will not notice.
def sites_series(site, vals, base=None):
    """Per-sample override list putting `vals` at `site`, everything else flat."""
    out = []
    for v in vals:
        s = dict(base or SITES_A)
        s[site] = v
        out.append(dict(sites=s))
    return out


def with_site(per_sample, site, vals):
    out = []
    for i, over in enumerate(per_sample):
        s = dict(over.get('sites', SITES_A))
        s[site] = vals[i]
        o = dict(over)
        o['sites'] = s
        out.append(o)
    return out


FLAT4 = [{}, {}, {}, {}]

ncase('n4_clean', FLAT4, 0,
      'four samples, nothing moves: the negative control for the whole arm')
# THE MONEY CASE. Site 9 takes 30 pages every two hours and never stops. Total
# span growth is +90 — well UNDER the 256-page bar, so every endpoint rule in
# this file says PASS. Only the shape convicts it.
ncase('n4_linear_leak_under_bar', sites_series(9, [300, 330, 360, 390]), 1,
      'a 15 pg/h linear leak whose span growth (+90) is UNDER the absolute bar')
# Its twin, and the reason the rule is not just "did it grow": same +90 at the
# endpoints, decaying rates. A warm-up reaching steady state.
ncase('n4_settle_decaying', sites_series(6, [2000, 2024, 2032, 2036]), 0,
      'the SAME endpoint growth as a leak, but the rate decays 12->4->2: settle')
ncase('n4_leaks_then_stops', sites_series(9, [300, 340, 380, 380]), 0,
      'it leaked 20 pg/h for four hours and then stopped: not a slope')
ncase('n4_noise_zero_trend', sites_series(9, [300, 306, 298, 303]), 0,
      'oscillation with no trend stays under the resolution floor')
# A shrinking site 0 is not an alibi — but a STILL-shrinking one is not
# distinguishable from re-attribution either, so this is 125 and not 1. Same
# polarity as the endpoint credit (`site_grew_from_unknown`), expressed as a
# rate: only a bucket still being DRAINED at the end of the span can be feeding
# anything.
ncase('n4_leak_masked_by_shrinking_site0',
      with_site(sites_series(9, [300, 330, 360, 390]), 0,
                [5000, 4970, 4940, 4910]), 125,
      'site 0 is still draining at 15 pg/h, exactly covering the leak')
ncase('n4_leak_site0_already_settled',
      with_site(sites_series(9, [300, 330, 360, 390]), 0,
                [5000, 4900, 4890, 4885]), 1,
      'site 0 FINISHED draining (-2.5 pg/h): it cannot be feeding a 15 pg/h site')
# The harness spawns its own `cat` per statm read, and a `born` process
# DOWNGRADES every growth rule to a note. Pass 20's real 8-hour run reported
# "processes that appeared during the gap: 62/cat" — i.e. the instrument was
# suppressing its own assertions with a process it spawned itself. It must not.
ncase('n4_leak_with_harness_cat',
      sites_series(9, [300, 330, 360, 390])[:3]
      + [dict(sites=merged(SITES_A, {9: 390}),
              tasks=merged(TASKS, {62: 'cat'}),
              statm=merged(STATM_A, {62: 5}))], 1,
      'a harness `cat` in the last sweep must NOT buy the leak an amnesty')
# ...and its negative control: a REAL app starting still does.
ncase('n4_leak_with_real_app_started',
      sites_series(9, [300, 330, 360, 390])[:3]
      + [dict(sites=merged(SITES_A, {9: 390}),
              tasks=merged(TASKS, {31: 'hamwrite'}),
              statm=merged(STATM_A, {31: 900}))], 0,
      'a real process STARTED: the growth is not attributable to steady state')
# Three samples is the minimum that has a curve at all, and it must work.
ncase('n3_settle', sites_series(6, [2000, 2029, 2033])[:3], 0,
      'the minimum N: rates 14.5 -> 2.0 is a settle')
ncase('n3_linear_leak', sites_series(9, [300, 345, 390])[:3], 1,
      'the minimum N: rates 22.5 -> 22.5 does not decay')
# Long-lived processes. Sustained is 125 and not 1 on purpose: the one process
# this gate grows is the serial shell IT DRIVES, and convicting the
# instrument's own scaffolding is the false red this campaign keeps catching.
ncase('n4_process_sustained',
      [dict(statm=merged(STATM_A, {7: v})) for v in (120, 160, 200, 240)], 125,
      'the panel resident set climbs 20 pg/h and is still climbing at the end')
ncase('n4_process_settles',
      [dict(statm=merged(STATM_A, {7: v})) for v in (120, 160, 175, 180)], 0,
      'the same +60, but decaying 20 -> 7.5 -> 2.5: a bounded high-water')
# "Too few" and "too close" are INCONCLUSIVE, never PASS — a three-sample run
# asked for four has not measured what it claims, and four samples five minutes
# apart are two samples with extra steps.
ncase('n3_but_four_asked', FLAT4[:3], 125,
      'three samples when four were required', min_samples=4)
ncase('n4_one_gap_too_close', FLAT4, 125,
      'the C->D interval is four minutes: that pair measured nothing',
      gaps=[7200, 7200, 240])
# THE FLOOR, stated as a case rather than left implicit. 12 pages over 6 hours
# is 2 pg/h = 68 MiB/year and this instrument CANNOT see it: at a 6-hour span
# the smallest resolvable rate is about one page per span. This case documents
# the hole; it is not a bug to be fixed by lowering the threshold, it is fixed
# by a LONGER SPAN.
ncase('n4_leak_below_resolution_floor',
      sites_series(9, [300, 304, 308, 312]), 0,
      'a 2 pg/h leak is UNDER the resolution floor of a 6-hour span: PASS, '
      'and the doc says so')

# THE EXACT BLINDNESS A PER-DELTA BAR WOULD HAVE. Site 9 takes 200 pages in
# every one of three intervals. NOT ONE of those deltas reaches the 256-page
# bar, and an adjudicator that had been "generalised" to N samples by applying
# the bar to each consecutive pair would report three clean intervals and PASS.
# The span is +600. The bar belongs on the SPAN, and this case is what pins it
# there. (Named explicitly in the pass-21 brief; it is the difference between
# differencing consecutive pairs and adjudicating on them.)
ncase('n4_deltas_under_bar_sum_over', sites_series(9, [300, 500, 700, 900]), 1,
      'three deltas of +200 each under the 256 bar, +600 over the span')
# The interaction between the two arms, pinned rather than left implicit: SHAPE
# DOES NOT WAIVE THE ABSOLUTE BAR. This curve decays (200 -> 100 -> 50, a
# textbook settle) and still puts 350 pages on the machine in six hours after a
# 15-minute settle window had already run. Pass 20's per-site bar convicts it
# and pass 21 does not soften that: a settle large enough to blow the bar is
# still 1.4 MiB the machine did not have, and the trend arm was added to catch
# MORE leaks, not to excuse the ones already caught.
ncase('n4_big_settle_still_over_bar', sites_series(9, [300, 500, 600, 650]), 1,
      'a decaying curve that still puts 350 pages past the absolute bar')

# =========================================================================
# LEAK PASS 21 — THE OWNER-UNRECORDED POPULATION (pass 20's third residual).
# =========================================================================
# Pass 20 ended with arm 23 at net +18 over 29 survivors, 9 of them
# `owner-unrecorded`, and the rule "an unrecorded owner is not an alibi" —
# stated, not enforced, because the tally line is only a count. These cases
# enforce it, and they distinguish the two populations that count conflates.
ARM_NET = {1: (100, 100), 5: (40, 30), 23: (30, 12)}   # arm 23 nets +18


def orgl_with(arm, total, unrec, detail):
    o = dict(ORGL)
    o[arm] = dict(total=total, dead=0, unrec=unrec, stray=0, untagged=0,
                  detail=detail)
    return o


# PRE-ARMING, and provably so: pa_set_owner is a no-op while _pa_trk_mode == 0
# (mm/page_alloc.ad), exactly as pa_set_site is — so a frame allocated before
# `track full` has site 0 AND va 0 AND owner 0, necessarily and together. This
# is the shape pass 20's REAL log has: all 9 unrecorded survivors on
# site=0 va=0x0. Explained, named, and PASS.
case('arm_unrec_prearming', {},
     dict(arms=ARM_NET,
          orgl=orgl_with(23, 29, 9,
                         [(0, 0, True)] * 9 + [(6, 0x7f0000, False)] * 20)), 0,
     'unrecorded owners on site=0/va=0 are the PRE-ARMING population')
# LEAK PASS 23. THE SAME EVIDENCE, ONE LINE OF BRINGUP LOG DIFFERENT. Pass 22
# armed the tracker in mem_init before the first buddy allocation, and this
# log says so. There is then no pre-arming population for these frames to
# belong to, so site=0 + va=0 + owner-unrecorded stops being structural and
# becomes an allocation path that ran ARMED and called neither pa_set_site nor
# pa_set_owner. Without this case, landing the pass-22 fix silently converted
# pass 21's excuse into a false green — a green bought BY a fix, which is the
# worst kind because nothing in the campaign would have flagged it.
case('arm_unrec_prearming_boot_armed', {},
     dict(arms=ARM_NET,
          orgl=orgl_with(23, 29, 9,
                         [(0, 0, True)] * 9 + [(6, 0x7f0000, False)] * 20)), 125,
     'boot-armed: site=0/va=0 unrecorded owners have no pre-arming population '
     'to belong to any more', boot_armed=True)
# The opposite finding from the same count: those frames were allocated with
# the tracker ARMED (they carry a named site) and that path never called
# pa_set_owner. A hole in the discriminator, with an address.
case('arm_unrec_named_site', {},
     dict(arms=ARM_NET,
          orgl=orgl_with(23, 29, 9,
                         [(9, 0, True)] * 9 + [(6, 0x7f0000, False)] * 20)), 125,
     'unrecorded owners at a NAMED site: pa_set_owner missing on that path')
# No per-frame detail at all: nothing can be attributed, so nothing is
# exonerated. An unattributed unrecorded owner is not even an argument.
case('arm_unrec_no_detail', {},
     dict(arms=ARM_NET, orgl=orgl_with(23, 29, 9, [])), 125,
     'owner-unrecorded survivors with no per-frame detail to attribute them')
# The kernel caps the per-frame detail at 64 while the tallies cover every
# survivor. A run whose unrecorded count exceeds what the detail reached is a
# PREFIX attribution — the exact shape leak pass 16 caught in a survivor walk.
case('arm_unrec_detail_prefix', {},
     dict(arms=ARM_NET,
          orgl=orgl_with(23, 29, 9, [(0, 0, True)] * 4)), 125,
     'the detail covers 4 of 9 unrecorded survivors: a prefix, not a clean set')

# `no_sample_B` needs its B half deleted after the fact.
p = os.path.join(work, 'no_sample_B', 'serial.log')
txt = open(p).read()
open(p, 'w').write(txt.split('HC_SAMPLE B')[0])

with open(os.path.join(work, 'cases.txt'), 'w') as f:
    for n, (rc, minsamp, why) in CASES.items():
        f.write('%s %d %s %s\n' % (n, rc, minsamp, why))
PY

[ -f "$WORK/cases.txt" ] || {
    echo "$TAG INCONCLUSIVE: synthetic log generation produced nothing" >&2
    exit 125; }

ncase=0
nfail=0
while read -r name want minsamp why; do
    ncase=$((ncase + 1))
    out="$WORK/$name/report.txt"
    # min_gap 3600, growth bar 256, min_samples per case, trend floor 16 pages,
    # settle fraction 0.5. The two-sample cases pass min_samples=2, which is the
    # adjudicator's default and leaves them adjudicating exactly as in pass 20.
    python3 "$REPORT" "$WORK/$name/serial.log" "$WORK/$name/stamps" 3600 256 \
        "$minsamp" 16 0.5 > "$out" 2>&1
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
if [ "$ncase" -lt 44 ]; then
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
