#!/usr/bin/env python3
"""Adjudicate an hours-apart, one-boot census series (leak passes 19-21).

    leak_hours_census_report.py <serial.log> <stamps> <min_gap_s>
                                <growth_fail_pages>
                                [min_samples] [trend_min_pages] [settle_frac]

Exit status follows scripts/_verdict.sh: 0 PASS, 1 FAIL, 125 INCONCLUSIVE.

THIS FILE IS SEPARATE FROM THE GATE ON PURPOSE. The gate needs a multi-hour KVM
boot to produce a log; the adjudication needs none, so keeping it out of the
heredoc is what makes it mutation-testable in seconds against synthetic and
against real captured logs. Every mutation in the pass-19/20/21 tables was run
against this file, not against a boot.

N SAMPLES, NOT TWO (leak pass 21)
---------------------------------
Samples are labelled A, B, C, ... in the log. TWO samples give a DELTA; three
or more give a CURVE, and the two shapes a delta cannot tell apart are the
whole open question of pass 20:

    a SETTLE  — a warm-up reaching steady state. Its consecutive rates DECAY.
    a LEAK    — unbounded accumulation. Its consecutive rates DO NOT decay.

Both produce the same +37 at the endpoints. So with N >= 3 this file
differences CONSECUTIVE pairs, converts each to pages/hour (gaps need not be
equal), and adjudicates the SHAPE. With N == 2 the trend arm does not engage at
all and the verdict is byte-for-byte what pass 20 produced — the registered
gate does not change meaning.

WHY THE TREND RULE HAS NO RATE BAR
----------------------------------
The absolute bar (<growth_fail_pages> over the whole span) structurally cannot
see a slow linear leak: 90 pages in 8 hours is 96 MiB/year and sails under a
256-page bar. The obvious repair — a pages/hour bar — reintroduces the same
blindness one decimal place down, because a SUSTAINED positive rate is
unbounded by definition and no threshold on it is defensible.

So the trend rule thresholds only on RESOLUTION: a span of T hours cannot
resolve a rate below about one page per T hours, so a site whose whole-span
growth is under <trend_min_pages> is FLAT (noise and signal are the same
numbers there) and everything above it is classified by shape alone. At an
8-hour span that floor is ~4 MiB/year of projected cost, which is inside the
months-and-years target — the instrument is limited by its span, not by an
arbitrary tolerance.

WHAT IT ASSERTS, AND WHY EACH ONE IS HERE
-----------------------------------------
INCONCLUSIVE (125), not PASS, when:
  * fewer than <min_samples> samples appeared, or ANY consecutive gap is below
    <min_gap_s>. A gate named "hours" that ran four minutes is the purest false
    green available here, and three samples five minutes apart are two samples
    with extra steps.
  * any sample is missing a per-site table, either census control, the [cens3]
    run predicate, or its plant's physical address. A plant you cannot identify
    cannot be discounted; a census without both controls is not a measurement;
    a blind census and an empty population print the same zero.
  * any site reports TRUNCATED — it covered a prefix of the population.
  * an arm shows a positive net over a population NONE of whose members has a
    recorded owner (`owner-dead=0` is vacuous there).
  * an arm with a positive net has owner-unrecorded survivors that were
    allocated at a NAMED site, or that the per-frame detail cannot attribute at
    all. See parse_orgl_detail(): an unrecorded owner on site=0/va=0 is the
    PRE-ARMING population and is explained; an unrecorded owner on a named site
    is a hole in the discriminator with an address.
  * a site holds a SUSTAINED positive rate that site 0 (unknown) is still
    shrinking fast enough to cover at the END of the span. Frames are counted,
    not identity-tracked, so re-attribution and a real leak print the same
    numbers; INCONCLUSIVE is the honest verdict, not the prettier one.
  * a long-lived process's resident set holds a SUSTAINED positive slope.
    (Reported at INCONCLUSIVE and not FAIL on purpose — see §PROCESSES below.)

FAIL when:
  * any frame is UNACCOUNTED after discounting the plant, in any sweep;
  * the run predicate reports zero UNACCOUNTED while a plant is outstanding
    (it is over-claiming, and its verdict is void);
  * an arm's net is positive with owner-dead or owner-stray > 0;
  * the total live-page delta over the span exceeds <growth_fail_pages> while
    the live task set was unchanged;
  * a site's delta over the span exceeds <growth_fail_pages> beyond what site 0
    shrank (the pass-20 per-site bar);
  * [N >= 3] a site holds a SUSTAINED positive rate above the resolution floor
    that site 0's terminal shrink does not cover. This is the pass-21 rule and
    the only one that can see a leak whose every individual delta is under the
    absolute bar.

PROCESSES: WHY A SUSTAINED RESIDENT SLOPE IS 125 AND NOT 1
----------------------------------------------------------
The one process that grows in every real run of this gate so far is pid 6, the
serial shell — and it grows because THE HARNESS DRIVES IT with a heartbeat
every five minutes. Convicting it would be the instrument condemning its own
scaffolding, which is the exact false-red shape this campaign keeps catching
(pass 17: a ramp is not a slope). So process trends are classified and
reported, a sustained one blocks PASS, and none of them can turn the gate red.
The sites arm is the one that convicts.
"""
import re
import sys

PGNAME = {0: 'unknown', 1: 'vma_large', 2: 'vma_fixed', 3: 'vma_prefault',
          4: 'vma_file', 5: 'vma_huge', 6: 'vma_anon', 7: 'vma_swapin',
          8: 'vma_grow', 9: 'pgtable', 10: 'fork_copy', 11: 'cow_resolve',
          12: 'kstack', 13: 'ustack', 14: 'pml4', 15: 'selftest', 16: 'slab',
          17: 'uaccess', 18: 'tmpfs', 19: 'wsys', 20: 'execve', 21: 'region'}
USER_SITES = {1, 2, 3, 4, 6, 7, 8, 10, 11, 13, 20}

bad, inconc, notes = [], [], []


def split_samples(log):
    """Return {'A': text, 'B': text, ...} split on the HC_SAMPLE fences.

    hamsh echoes each command line back before running it, so the fence text
    appears twice; the split is on the ANCHORED echo of the bare marker, which
    is the form the shell prints on its own line.

    Labels are A..Z (pass 21). Pass 19/20 emitted exactly A and B, so a
    two-sample log parses identically here.
    """
    out = {}
    cur, buf = None, []
    for ln in log.splitlines():
        m = re.match(r'^HC_SAMPLE ([A-Z])\s*$', ln)
        if m:
            if cur is not None:
                out.setdefault(cur, []).extend(buf)
            cur, buf = m.group(1), []
            continue
        if re.match(r'^HC_SAMPLE_END ([A-Z])\s*$', ln):
            if cur is not None:
                out.setdefault(cur, []).extend(buf)
            cur, buf = None, []
            continue
        if cur is not None:
            buf.append(ln)
    if cur is not None:
        out.setdefault(cur, []).extend(buf)
    return {k: '\n'.join(v) for k, v in out.items()}


def parse_sites(text):
    d = {}
    for m in re.finditer(r'\[trk\] site=(\d+) live=(\d+)', text):
        d[int(m.group(1))] = int(m.group(2))
    return d


def parse_arms(text):
    d = {}
    for m in re.finditer(r'\[origin\] org=(\d+) born=(\d+) died=(\d+)', text):
        d[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
    return d


def parse_owners(text):
    """arm -> dict(total, dead, unrec, stray, untagged)."""
    d = {}
    for m in re.finditer(r'\[orgl\] org=(\d+) TOTAL=(\d+)', text):
        d.setdefault(int(m.group(1)), {})['total'] = int(m.group(2))
    for m in re.finditer(r'\[orgl\] org=(\d+) owner-dead=(\d+) '
                         r'owner-unrecorded=(\d+)', text):
        e = d.setdefault(int(m.group(1)), {})
        e['dead'] = int(m.group(2))
        e['unrec'] = int(m.group(3))
    for m in re.finditer(r'\[orgl\] org=(\d+) owner-stray=(\d+)'
                         r'(?: owner-untagged=(\d+))?', text):
        e = d.setdefault(int(m.group(1)), {})
        e['stray'] = int(m.group(2))
        e['untagged'] = int(m.group(3) or 0)
    return d


def parse_orgl_detail(text):
    """arm -> per-survivor detail, for the OWNER-UNRECORDED adjudication.

    THE PASS-21 ANSWER TO PASS 20'S THIRD RESIDUAL
    ----------------------------------------------
    Pass 20 closed with arm 23 at net +18 over 29 survivors, 9 of them
    `owner-unrecorded`, and wrote down the rule without the evidence: "an
    unrecorded owner is not an alibi." It is not — but it is also not
    necessarily a hole, and until this function nothing could tell the two
    apart, because the tally line prints only a COUNT.

    The kernel already prints what settles it. `track org N`
    (kernel/sched/core.ad) emits, per survivor:

        [orgl] org=23 live[9] phys=0x...
        [orgl] live[9] va=0x0 site=0
        [orgl] live[9] cow_refcount=1
        [orgl] live[9] owner: NOT RECORDED

    and `pa_set_owner` in mm/page_alloc.ad is a NO-OP while the tracker is
    disarmed:

        def pa_set_owner(o: uint64):
            if _pa_trk_mode == 0:
                return

    …exactly as `pa_set_site` is. So a frame allocated BEFORE `track full` has
    site 0 AND owner 0 AND tag 0, necessarily and together. An unrecorded owner
    sitting on site=0/va=0 is therefore PRE-ARMING: the discriminator could not
    have recorded it, and the fix is the same one the re-attribution credit
    wants — arm the tracker at boot.

    An unrecorded owner on a NAMED site is the opposite finding: that
    allocation path ran with the tracker armed, stamped its site, and never
    called pa_set_owner. That is a real hole in the discriminator with an
    address, and it is INCONCLUSIVE, not clean.

    The per-frame detail is capped at 64 by the kernel while the tallies cover
    every survivor (leak pass 16), so the coverage is returned too: an
    attribution that reached fewer frames than the tally counted is partial and
    says so.
    """
    out = {}
    arm = None
    idx = None
    for ln in text.splitlines():
        m = re.search(r'\[orgl\] org=(\d+) live\[(\d+)\] phys=', ln)
        if m:
            arm, idx = int(m.group(1)), int(m.group(2))
            e = out.setdefault(arm, {'frames': {}, 'n': 0})
            e['frames'][idx] = {'site': None, 'va': None, 'unrec': False}
            e['n'] += 1
            continue
        if arm is None:
            continue
        m = re.search(r'\[orgl\] live\[(\d+)\] va=0x0*([0-9a-fA-F]*) '
                      r'site=(\d+)', ln)
        if m and int(m.group(1)) == idx:
            f = out[arm]['frames'].get(idx)
            if f is not None:
                f['va'] = int(m.group(2) or '0', 16)
                f['site'] = int(m.group(3))
            continue
        m = re.search(r'\[orgl\] live\[(\d+)\] owner: NOT RECORDED', ln)
        if m and int(m.group(1)) == idx:
            f = out[arm]['frames'].get(idx)
            if f is not None:
                f['unrec'] = True
    return out


def check_unrecorded_owners(arm, net, e, detail):
    """Adjudicate an arm's `owner-unrecorded` population BY SITE, not by count.

    Called only for arms with a positive inter-sample net — the population the
    campaign actually argues about.
    """
    unrec = e.get('unrec', 0)
    if unrec <= 0:
        return
    d = detail.get(arm)
    if not d or not d['frames']:
        inconc.append('arm %d: net %+d with %d owner-unrecorded survivor(s) and '
                      'NO per-frame [orgl] detail in this sweep, so not one of '
                      'them can be attributed. An unrecorded owner is not an '
                      'alibi; an unattributed one is not even an argument.'
                      % (arm, net, unrec))
        return
    seen = [f for f in d['frames'].values() if f['unrec']]
    prearm = [f for f in seen if f['site'] == 0 and not f['va']]
    named = [f for f in seen if f['site'] not in (0, None) or f['va']]
    if named:
        sites = sorted(set(f['site'] for f in named))
        inconc.append('arm %d: %d of %d owner-unrecorded survivor(s) were '
                      'allocated at NAMED site(s) %s — that path ran with the '
                      'tracker ARMED, stamped its site, and never called '
                      'pa_set_owner. The discriminator has a hole with an '
                      'address there, and owner-dead=0 over those frames says '
                      'nothing.'
                      % (arm, len(named), unrec,
                         ', '.join('%d/%s' % (s, PGNAME.get(s, '?'))
                                   for s in sites)))
    if len(seen) < unrec:
        inconc.append('arm %d: the tally counts %d owner-unrecorded survivor(s) '
                      'but the per-frame detail (capped at 64 by the kernel) '
                      'covers only %d of them — the attribution is a PREFIX, '
                      'which is exactly the shape leak pass 16 caught. Partial, '
                      'not clean.' % (arm, unrec, len(seen)))
        return
    if prearm and not named:
        notes.append('arm %d: all %d owner-unrecorded survivor(s) carry site=0 '
                     'and va=0, i.e. they were allocated BEFORE `track full` '
                     'armed the tracker — pa_set_owner is a no-op while '
                     'disarmed (mm/page_alloc.ad), so no owner COULD have been '
                     'recorded. This is the pre-arming population, not a hole '
                     'in the discriminator; arming at boot removes it.'
                     % (arm, len(prearm)))


def parse_tasks(text):
    """pid -> comm, from /proc/tasks lines '<pid>\\t<state>\\t<comm>\\t...'."""
    d = {}
    for m in re.finditer(r'^(\d+)\t(\S+)\t(\S+)', text, re.M):
        d[int(m.group(1))] = m.group(3)
    return d


def parse_statm(text, sample):
    """pid -> resident pages (field 2 of /proc/<pid>/statm)."""
    d = {}
    cur = None
    for ln in text.splitlines():
        m = re.match(r'^HC_STATM ([A-Z]) (\d+)\s*$', ln)
        if m:
            cur = int(m.group(2)) if m.group(1) == sample else None
            continue
        if re.match(r'^HC_STATMEND_', ln):
            cur = None
            continue
        if cur is not None:
            f = ln.split()
            if len(f) >= 2 and all(x.isdigit() for x in f[:2]):
                d[cur] = int(f[1])
                cur = None
    return d


def parse_census(text):
    """Everything the census sweep asserts on, for ONE sample."""
    c = {}
    c['pos'] = 'control OK: planted orphan detected' in text
    c['neg'] = 'negative control OK' in text
    m = re.search(r'\[census\] planted control orphan phys=0x0*([0-9a-fA-F]+)',
                  text)
    c['plant'] = int(m.group(1), 16) if m else None
    orph = re.findall(r'\[census\].*orphaned frames?[:= ]+(\d+)', text)
    c['orphans'] = int(orph[-1]) if orph else None
    unacc = {}
    for m in re.finditer(r'\[cens3\] site (\d+): (\d+) UNACCOUNTED', text):
        unacc[int(m.group(1))] = int(m.group(2))
    c['unacc'] = unacc
    c['has_cens3'] = '[cens3]' in text
    c['trunc'] = [int(m.group(1))
                  for m in re.finditer(r'\[cens3\] site (\d+): TRUNCATED', text)]
    # Discount the plant from its OWN site, by physical address. `track plant`
    # allocates at a real user-mapped site (PA_SITE_VMA_ANON), so left in it
    # would be re-reported as that site's leak — which is exactly what happened
    # the first time pass 18's gate ran.
    real = dict(unacc)
    if c['plant'] is not None:
        for m in re.finditer(r'\[cens3\] site (\d+) orphan\[\d+\] '
                             r'phys=0x0*([0-9a-fA-F]+)', text):
            if int(m.group(2), 16) == c['plant']:
                s = int(m.group(1))
                if real.get(s, 0) > 0:
                    real[s] -= 1
    c['unacc_real'] = real
    return c


def check_census(name, c):
    if not c['pos'] or not c['neg']:
        inconc.append('sample %s: census controls incomplete (positive=%s '
                      'negative=%s) — an orphan count without BOTH is not a '
                      'measurement' % (name, c['pos'], c['neg']))
        return
    if not c['has_cens3']:
        inconc.append('sample %s: no [cens3] run predicate — this kernel '
                      'predates it or the census never ran, so nothing about '
                      'unreachable frames is settled' % name)
        return
    if c['trunc']:
        inconc.append('sample %s: run-check TRUNCATED at site(s) %s — it '
                      'covered a PREFIX of the population, so those sites are '
                      'inconclusive, not clean'
                      % (name, ', '.join(str(s) for s in c['trunc'])))
    tot = sum(c['unacc'].values())
    if tot == 0:
        bad.append('sample %s: the run predicate reported 0 UNACCOUNTED while '
                   'a planted control (mapped NOWHERE, therefore in NO run) '
                   'was outstanding — it OVER-CLAIMS and its verdict is void'
                   % name)
        return
    if c['plant'] is None:
        inconc.append('sample %s: %d UNACCOUNTED frame(s) but the planted '
                      'control\'s phys was never printed, so the plant cannot '
                      'be told apart from a real one' % (name, tot))
        return
    real = sum(c['unacc_real'].values())
    if real == 0:
        notes.append('sample %s: the ONLY unaccounted frame in the machine is '
                     'the planted control at phys=0x%x' % (name, c['plant']))
    else:
        detail = ', '.join('site %d/%s x%d'
                           % (s, PGNAME.get(s, '?'), c['unacc_real'][s])
                           for s in sorted(c['unacc_real'])
                           if c['unacc_real'][s])
        bad.append('sample %s: %d UNACCOUNTED frame(s) after discounting the '
                   'planted control — they lie in NO live run and nobody will '
                   'ever return them: %s' % (name, real, detail))


YEAR_H = 8766.0        # hours in a Julian year, for projecting a rate


def classify(series, hours, trend_min, settle_frac):
    """Classify a per-sample value series as FLAT / SETTLE / DECAY / SUSTAINED.

    `series` is v_0..v_{N-1}, `hours` is the elapsed hours at each sample
    relative to sample 0. Returns (kind, detail) where detail carries the
    numbers the caller prints. Requires N >= 3; the caller does not call it
    otherwise, which is what keeps N == 2 adjudicating exactly as pass 20 did.

    THE SHAPE, AND WHY IT IS THE TERMINAL RATE THAT DECIDES
    ------------------------------------------------------
    A settle is a bounded process: whatever it was going to take, it has taken,
    and its remaining rate goes to zero. A leak is unbounded: its rate is still
    there at the end of the span. Both integrate to the same endpoint delta,
    which is why pass 20's two-sample verdict could not separate them, and the
    terminal rate is the smallest statistic that can.

    Comparing the terminal rate against the PEAK of the earlier rates (rather
    than against the first) is deliberate: a warm-up need not be monotone, and
    a site that goes 12, 4, 2 pages/hour and one that goes 4, 12, 2 have both
    stopped. Taking the peak makes the settle verdict harder to earn, not
    easier — the failure direction that matters here.
    """
    n = len(series)
    span = series[-1] - series[0]
    rates = []
    for i in range(n - 1):
        dh = hours[i + 1] - hours[i]
        rates.append((series[i + 1] - series[i]) / dh if dh > 0 else 0.0)
    d = {'span': span, 'rates': rates, 'r_term': rates[-1],
         'peak_early': max(rates[:-1]) if len(rates) > 1 else rates[0],
         'span_h': hours[-1] - hours[0]}
    if span <= trend_min:
        return 'FLAT', d
    if d['r_term'] <= 0:
        return 'SETTLE', d
    if d['peak_early'] > 0 and d['r_term'] < settle_frac * d['peak_early']:
        return 'DECAY', d
    return 'SUSTAINED', d


def fmt_rates(d):
    return ' -> '.join('%+.2f' % r for r in d['rates'])


def main():
    log = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
    log = log.replace('\r', '')
    stamps_path, min_gap, growth_bar = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    # Pass-21 knobs. The defaults are chosen so that a two-sample invocation is
    # identical to pass 20's: min_samples 2 disables the "too few" rule, and the
    # trend arm never engages below three samples regardless.
    min_samples = int(sys.argv[5]) if len(sys.argv) > 5 else 2
    trend_min = int(sys.argv[6]) if len(sys.argv) > 6 else 16
    settle_frac = float(sys.argv[7]) if len(sys.argv) > 7 else 0.5

    stamps = {}
    try:
        for ln in open(stamps_path):
            f = ln.split()
            if len(f) == 2:
                stamps[f[0]] = int(f[1])
    except OSError:
        pass

    samples = split_samples(log)
    # The labels this run actually produced, in order. A two-sample log yields
    # exactly ['A', 'B'] and every rule below collapses to the pass-20 one.
    labs = sorted(k for k in samples if k in stamps) or sorted(samples)
    print('=== leak pass 21: N-sample census on ONE boot (%d sample%s) ==='
          % (len(labs), '' if len(labs) == 1 else 's'))
    if len(labs) < 2:
        for s in ('A', 'B'):
            if s not in samples:
                inconc.append('sample %s never appeared in the log — the run '
                              'did not produce a pair to difference' % s)
    if len(labs) < min_samples:
        inconc.append('only %d sample(s) usable (%s); this run was asked for at '
                      'least %d. Two samples give a DELTA, not a curve, and a '
                      'settle and a leak print the same delta — so "fewer than '
                      'asked for" is INCONCLUSIVE, never PASS.'
                      % (len(labs), ','.join(labs) or 'none', min_samples))

    gap = None
    hours = None
    if len(labs) >= 2 and all(s in stamps for s in labs):
        t0 = stamps[labs[0]]
        hours = [(stamps[s] - t0) / 3600.0 for s in labs]
        gap = stamps[labs[-1]] - t0
        for i in range(len(labs) - 1):
            g = stamps[labs[i + 1]] - stamps[labs[i]]
            print('sample %s at %d -> sample %s at %d: gap %ds (%.2f h)'
                  % (labs[i], stamps[labs[i]], labs[i + 1],
                     stamps[labs[i + 1]], g, g / 3600.0))
            if g < min_gap:
                inconc.append('samples %s and %s are only %ds apart (minimum '
                              '%ds). This run did NOT measure hours across that '
                              'interval, and reporting a PASS for it would be '
                              'the exact false green this gate exists to avoid.'
                              % (labs[i], labs[i + 1], g, min_gap))
        if len(labs) > 2:
            print('total span %ds (%.2f h)' % (gap, gap / 3600.0))
    elif len(labs) >= 2:
        inconc.append('no sample timestamps recorded for every sample — the '
                      'elapsed gaps are unknown, so "hours apart" is unverified')

    if len(labs) < 2:
        emit()
        return

    # The endpoint rules below are pass 19's and pass 20's, applied to the FIRST
    # and LAST samples, i.e. across the widest span the run measured. For N == 2
    # first/last ARE A and B.
    first, last = labs[0], labs[-1]
    ta, tb = samples[first], samples[last]
    sa, sb = parse_sites(ta), parse_sites(tb)
    if not sa or not sb:
        inconc.append('a per-site [trk] table is missing (%s=%d sites, '
                      '%s=%d sites) — there is nothing to difference'
                      % (first, len(sa), last, len(sb)))
    # Every sample's per-site table, for the trend arm. A sample that produced
    # no table at all is a hole in the curve, not a zero.
    site_series = {}
    for s in labs:
        site_series[s] = parse_sites(samples[s])
        if not site_series[s]:
            inconc.append('sample %s produced no per-site [trk] table — the '
                          'curve has a HOLE at that point, and a missing '
                          'sample is not a flat one' % s)

    censuses = dict((s, parse_census(samples[s])) for s in labs)
    ca, cb = censuses[first], censuses[last]
    print()
    print('=== census, every sweep ===')
    for nm in labs:
        c = censuses[nm]
        print('sample %s: positive=%s negative=%s orphans=%s plant=%s '
              'UNACCOUNTED=%d (%d after discounting the plant)'
              % (nm, 'OK' if c['pos'] else 'MISSING',
                 'OK' if c['neg'] else 'MISSING',
                 c['orphans'], ('0x%x' % c['plant']) if c['plant'] else 'NONE',
                 sum(c['unacc'].values()), sum(c['unacc_real'].values())))
        check_census(nm, c)
    # The GAP comparison is only meaningful when BOTH sweeps could discount
    # their own plant. If one could not, its `unacc_real` still contains an
    # undiscounted control frame, and differencing the two would report that
    # control as growth — condemning the instrument's own scaffolding as a
    # leak. That sweep is already INCONCLUSIVE above; do not also convict on it.
    if ca['plant'] is not None and cb['plant'] is not None:
        ra, rb = sum(ca['unacc_real'].values()), sum(cb['unacc_real'].values())
        if rb > ra:
            bad.append('unaccounted frames GREW across the gap: %d -> %d. That '
                       'is a leak with a rate, not a residue.' % (ra, rb))

    # ---- per-site live deltas, the headline of this gate --------------------
    print()
    print('=== per-site LIVE page counts, %s apart (plant not in these counts: '
          'the dump is taken BEFORE the plant) ==='
          % ('%.2f h' % (gap / 3600.0) if gap else 'unknown time'))
    total_a = sum(sa.values())
    total_b = sum(sb.values())
    for s in sorted(set(sa) | set(sb)):
        a, b = sa.get(s, 0), sb.get(s, 0)
        if a != b:
            print('  site %-3d %-13s %s=%-7d %s=%-7d delta %+d'
                  % (s, PGNAME.get(s, '?'), first, a, last, b, b - a))
    print('  TOTAL live pages %s=%d %s=%d delta %+d'
          % (first, total_a, last, total_b, total_b - total_a))
    if gap:
        print('  => %.2f pages/hour, i.e. %.1f MiB/year at this rate'
              % ((total_b - total_a) / (gap / 3600.0),
                 (total_b - total_a) / (gap / 3600.0) * YEAR_H * 4 / 1024.0))

    # ---- the long-lived processes: THE thing nothing had ever measured ------
    tka, tkb = parse_tasks(ta), parse_tasks(tb)
    ma, mb = parse_statm(log, first), parse_statm(log, last)
    lived = sorted(set(tka) & set(tkb))
    # HARNESS TRANSIENTS ARE NOT LAUNCHED APPS. The battery itself runs
    # `cat /proc/<pid>/statm` once per live task, so a sample sweep routinely
    # catches one of its OWN `cat` processes in flight — pass 20's real 8-hour
    # run reported "processes that appeared during the gap: 62/cat" for exactly
    # that reason. That matters because a non-empty `born` set DOWNGRADES the
    # growth bar from a FAIL to a note: the instrument was suppressing its own
    # only page-growth assertion because of a process the instrument spawned.
    # Found by reading pass 20's captured summary, not by a mutation.
    #
    # These comms are excluded from born/died and reported separately, so
    # nothing is hidden — but they can no longer buy an amnesty. A real app
    # (`hamwrite`) still does, which is the `growth_but_new_process` mutation.
    HARNESS_COMMS = {'cat', 'sleep', 'echo'}
    born_all = sorted(set(tkb) - set(tka))
    died_all = sorted(set(tka) - set(tkb))
    born = [p for p in born_all if tkb[p] not in HARNESS_COMMS]
    died = [p for p in died_all if tka[p] not in HARNESS_COMMS]
    transient = ([p for p in born_all if tkb[p] in HARNESS_COMMS]
                 + [p for p in died_all if tka[p] in HARNESS_COMMS])
    print()
    print('=== long-lived processes (alive at BOTH endpoint samples) ===')
    if not tka or not tkb:
        inconc.append('/proc/tasks produced no task list in one or both '
                      'samples — the long-lived-process arm asserted nothing, '
                      'and a zero from an arm that never ran is not a green')
    if not lived:
        inconc.append('no process was alive at both samples — there is no '
                      'long-lived cohort to difference')
    grew = []
    for p in lived:
        a, b = ma.get(p), mb.get(p)
        if a is None or b is None:
            print('  pid %-6d %-16s statm MISSING (%s=%s %s=%s)'
                  % (p, tka[p], first, a, last, b))
            continue
        mark = ''
        if b > a:
            mark = '   <-- GREW'
            grew.append((p, tka[p], b - a))
        print('  pid %-6d %-16s resident %s=%-7d %s=%-7d delta %+d%s'
              % (p, tka[p], first, a, last, b, b - a, mark))
    if not any(p in ma and p in mb for p in lived):
        inconc.append('not one long-lived process yielded a statm reading in '
                      'BOTH samples — this arm is blind, not clean')
    if born:
        notes.append('processes that appeared during the gap: %s'
                     % ', '.join('%d/%s' % (p, tkb[p]) for p in born))
    if died:
        notes.append('processes that exited during the gap: %s'
                     % ', '.join('%d/%s' % (p, tka[p]) for p in died))
    if transient:
        notes.append('harness transients seen in one endpoint sweep and not '
                     'the other (%s) — the battery spawns these itself, so '
                     'they are reported and do NOT suppress the growth bar'
                     % ', '.join('%d/%s' % (p, tkb.get(p) or tka.get(p))
                                 for p in transient))
    for p, comm, d in grew:
        notes.append('long-lived pid %d (%s) grew %+d resident pages across '
                     'the gap' % (p, comm, d))

    # THE GROWTH BAR. Only meaningful when the task set was unchanged: a
    # process that started during the gap legitimately adds resident pages, and
    # condemning that would be a false red of exactly the shape this campaign
    # keeps catching.
    delta = total_b - total_a
    if delta > growth_bar:
        if born:
            notes.append('total live pages grew %+d (> bar %d) but %d '
                         'process(es) STARTED during the gap, so the growth is '
                         'not attributable to steady state — reported, not '
                         'condemned' % (delta, growth_bar, len(born)))
        else:
            bad.append('total live pages grew %+d over the gap with an '
                       'UNCHANGED live task set, past the bar of %d pages. '
                       'Nothing was launched or closed; a desktop that does '
                       'this does not run for months.' % (delta, growth_bar))
    else:
        notes.append('total live pages grew %+d over the gap, within the %d '
                     'page bar' % (delta, growth_bar))

    # THE PER-SITE BAR (leak pass 20). A TOTAL IS CANCELLABLE, and the bar
    # above was the only growth assertion this adjudicator made. Demonstrated
    # rather than argued: with site 9 (pgtable) at +900 and site 6 at -900 the
    # pass-19 report printed "total live pages grew +0 ... within the 256 page
    # bar" and returned PASS — over a run in which a KERNEL site, one the
    # orphan census explicitly declines to judge ("scope: USER-MAPPED sites
    # only"), took 900 pages in a gap where nothing was launched. Every word of
    # that verdict was true and the run was a leak. The mutation is
    # `site_swap_nets_zero`.
    #
    # The rule is per-site and uses the SAME bar, including site 0: after
    # arming, an untagged allocation path is the one bucket whose growth cannot
    # be acted on, so it is the last one that should get an exemption.
    #
    # Its negative control is `site_motion_under_bar`, and it is the one that
    # keeps this rule alive: pass 19's real run moved -151/+31/+2/+2 across four
    # sites — frames returned by the un-attributed population and re-allocated
    # WITH attribution — and a per-site rule that reddened on that would be
    # deleted within a pass.
    # THE RE-ATTRIBUTION CREDIT, and why it is INCONCLUSIVE and not PASS.
    # Site 0 is the population that was already live when the tracker was
    # armed, so it carries no recorded site and can only shrink as those frames
    # are freed and re-allocated WITH attribution. Pass 19's real 2.02 h run is
    # exactly that shape: site 0 -151 against +31/+2/+2 elsewhere. The effect
    # grows with the gap, so a naive per-site rule would redden every long run
    # and be deleted.
    #
    # But a shrinking site 0 does NOT prove that an attributed site's growth
    # came from it: frames are counted, not identity-tracked, so "the unknown
    # bucket recycled into pgtable" and "pgtable leaked while unrelated unknown
    # frames were freed" produce identical numbers. There is no discriminator
    # in this data, so the honest verdict for growth covered by that credit is
    # INCONCLUSIVE — named, with the reason — rather than the prettier of the
    # two readings. (Pass 15's rule.) The fix that WOULD discriminate is arming
    # the tracker at boot so site 0 is empty and no credit exists.
    credit = max(0, sa.get(0, 0) - sb.get(0, 0))
    for s in sorted(set(sa) | set(sb), key=lambda k: -(sb.get(k, 0)
                                                       - sa.get(k, 0))):
        d = sb.get(s, 0) - sa.get(s, 0)
        if d <= growth_bar or s == 0:
            continue
        if born:
            notes.append('site %d (%s) grew %+d pages (> bar %d) but %d '
                         'process(es) STARTED during the gap — reported, not '
                         'condemned'
                         % (s, PGNAME.get(s, '?'), d, growth_bar, len(born)))
            continue
        used = min(credit, d)
        credit -= used
        resid = d - used
        if resid > growth_bar:
            bad.append('site %d (%s) grew %+d pages over the gap with an '
                       'UNCHANGED live task set; site 0 (unknown) shrank by '
                       'enough to explain %d of them and %d remain, past the '
                       'bar of %d. The TOTAL does not condemn it because other '
                       'ATTRIBUTED sites returned the same frames, but a named '
                       'site accumulating at this rate is a leak with an '
                       'address.'
                       % (s, PGNAME.get(s, '?'), d, used, resid, growth_bar))
        else:
            inconc.append('site %d (%s) grew %+d pages past the bar of %d, and '
                          'site 0 (unknown) shrank by enough to cover %d of '
                          'them. Re-attribution of the pre-arming population '
                          'and a real leak at this site produce identical '
                          'counts, so this is UNADJUDICATED, not clean. Arm '
                          'the tracker at boot to remove the ambiguity.'
                          % (s, PGNAME.get(s, '?'), d, growth_bar, used))

    # =======================================================================
    # THE TREND ARM (leak pass 21). Engages ONLY at N >= 3.
    # =======================================================================
    # Everything above is an ENDPOINT rule: it differences the first and last
    # samples and compares the result against an absolute page bar. Two things
    # are wrong with that, and pass 20 hit both:
    #
    #   (1) An absolute bar structurally cannot see a slow linear leak. Site 9
    #       going 0 -> 30 -> 60 -> 90 pages over 8 hours is 96 MiB/year of
    #       unbounded accumulation and passes a 256-page bar without a murmur.
    #   (2) A settle and a leak print the SAME endpoint delta. Pass 20 measured
    #       site 6 (vma_anon) 1 -> 38 and could say nothing about whether that
    #       was a warm-up that had already finished or a slope that keeps going.
    #       Its own closing words: "two samples give a delta, not a curve."
    #
    # With three or more samples there IS a curve. Consecutive pairs are
    # differenced, each converted to pages/hour so unequal gaps are handled
    # honestly, and the classification is by SHAPE (see classify()):
    #
    #   FLAT       whole-span growth under the resolution floor -> nothing said
    #   SETTLE     the terminal rate is <= 0: it stopped
    #   DECAY      the terminal rate is under settle_frac of its earlier peak
    #   SUSTAINED  the rate is still there at the end of the span -> LEAK
    #
    # There is deliberately NO rate bar. A sustained positive rate is unbounded
    # by definition, so any threshold on it would be the same blindness as (1)
    # one decimal place down. The only threshold is the resolution floor.
    if len(labs) >= 3 and hours is not None:
        print()
        print('=== TREND across %d samples: consecutive rates, pages/hour ==='
              % len(labs))
        all_sites = sorted(set().union(*(set(site_series[s]) for s in labs)))
        # Site 0's terminal shrink rate is the pass-20 re-attribution credit
        # expressed as a RATE. The credit only excuses a leak if the
        # unattributed bucket is STILL being drained at the end of the span;
        # a site 0 that has finished shrinking cannot be feeding anything.
        s0 = [site_series[s].get(0, 0) for s in labs]
        s0_kind, s0_d = classify(s0, hours, 0, settle_frac)
        s0_term_shrink = max(0.0, -s0_d['r_term'])
        print('  site 0 (unknown) terminal rate %+.2f pg/h  -> credit '
              'available to other sites: %.2f pg/h'
              % (s0_d['r_term'], s0_term_shrink))
        for s in all_sites:
            ser = [site_series[lb].get(s, 0) for lb in labs]
            kind, d = classify(ser, hours, trend_min, settle_frac)
            print('  site %-3d %-13s %s   span %+d over %.2f h   rates %s   '
                  '-> %s' % (s, PGNAME.get(s, '?'),
                             '/'.join(str(v) for v in ser), d['span'],
                             d['span_h'], fmt_rates(d), kind))
            if kind == 'FLAT':
                continue
            if kind in ('SETTLE', 'DECAY'):
                notes.append('site %d (%s) grew %+d over the span but its rate '
                             '%s pg/h: a %s, NOT a leak. This is the '
                             'discrimination two samples could not make.'
                             % (s, PGNAME.get(s, '?'), d['span'],
                                'went to zero or below' if kind == 'SETTLE'
                                else 'decayed to %.2f from a peak of %.2f'
                                     % (d['r_term'], d['peak_early']),
                                kind))
                continue
            # SUSTAINED.
            if born:
                notes.append('site %d (%s) holds a SUSTAINED %+.2f pg/h but %d '
                             'process(es) STARTED during the span — reported, '
                             'not condemned'
                             % (s, PGNAME.get(s, '?'), d['r_term'], len(born)))
                continue
            yr = d['r_term'] * YEAR_H
            if s != 0 and s0_term_shrink >= d['r_term']:
                inconc.append('site %d (%s) holds a SUSTAINED %+.2f pg/h '
                              '(%.1f MiB/year) whose every consecutive delta is '
                              'under the %d-page bar — but site 0 (unknown) is '
                              'STILL shrinking at %.2f pg/h at the end of the '
                              'span, which covers it. Frames are counted, not '
                              'identity-tracked, so re-attribution and a real '
                              'leak print the same numbers. UNADJUDICATED, not '
                              'clean: arm the tracker at boot to remove the '
                              'ambiguity.'
                              % (s, PGNAME.get(s, '?'), d['r_term'],
                                 yr * 4 / 1024.0, growth_bar, s0_term_shrink))
                continue
            bad.append('site %d (%s) is LEAKING: its rate did NOT decay across '
                       '%.2f h of %d samples (%s pg/h), terminal %+.2f pg/h = '
                       '%.0f pages/year = %.1f MiB/year. Total span growth is '
                       'only %+d pages, UNDER the %d-page bar — an absolute bar '
                       'cannot see this and the endpoint verdict says PASS. '
                       'Site 0 offers only %.2f pg/h of re-attribution credit, '
                       'which does not cover it.'
                       % (s, PGNAME.get(s, '?'), d['span_h'], len(labs),
                          fmt_rates(d), d['r_term'], yr, yr * 4 / 1024.0,
                          d['span'], growth_bar, s0_term_shrink))

        # The same shape rule on the long-lived processes' resident sets. This
        # one is INCONCLUSIVE-at-worst on purpose; see the module docstring.
        statms = dict((lb, parse_statm(log, lb)) for lb in labs)
        tasksets = dict((lb, parse_tasks(samples[lb])) for lb in labs)
        everywhere = set(tasksets[labs[0]])
        for lb in labs[1:]:
            everywhere &= set(tasksets[lb])
        everywhere = sorted(p for p in everywhere
                            if all(p in statms[lb] for lb in labs))
        print()
        print('=== TREND, long-lived processes alive at ALL %d samples ==='
              % len(labs))
        if not everywhere:
            inconc.append('no process yielded a resident reading at ALL %d '
                          'samples — the process trend arm is blind, not clean'
                          % len(labs))
        for p in everywhere:
            ser = [statms[lb][p] for lb in labs]
            kind, d = classify(ser, hours, trend_min, settle_frac)
            if kind == 'FLAT' and d['span'] == 0:
                continue
            print('  pid %-6d %-16s %s   span %+d   rates %s   -> %s'
                  % (p, tasksets[labs[0]][p], '/'.join(str(v) for v in ser),
                     d['span'], fmt_rates(d), kind))
            if kind == 'SUSTAINED':
                inconc.append('long-lived pid %d (%s) resident set holds a '
                              'SUSTAINED %+.2f pg/h over %.2f h (%s), i.e. it '
                              'is still climbing at the END of the span — not a '
                              'bounded high-water. Reported as UNADJUDICATED '
                              'rather than FAIL because the one process this '
                              'gate DRIVES (the serial shell) grows for that '
                              'reason, and convicting the instrument\'s own '
                              'scaffolding is a false red.'
                              % (p, tasksets[labs[0]][p], d['r_term'],
                                 d['span_h'], fmt_rates(d)))
            elif kind in ('SETTLE', 'DECAY'):
                notes.append('long-lived pid %d (%s) grew %+d resident pages '
                             'but its rate %s: a %s, not a slope'
                             % (p, tasksets[labs[0]][p], d['span'],
                                'went to zero or below' if kind == 'SETTLE'
                                else 'decayed to %.2f pg/h from a peak of %.2f'
                                     % (d['r_term'], d['peak_early']), kind))

    # ---- arms: inter-sample nets, adjudicated by the owner discriminator ----
    aa, ab = parse_arms(ta), parse_arms(tb)
    oa, ob = parse_owners(ta), parse_owners(tb)
    orgl_detail = parse_orgl_detail(tb)
    print()
    print('=== COW origin arms: inter-sample net, and the owner discriminator '
          'at sample B ===')
    if not ab:
        inconc.append('no [origin] arm dump parsed at sample B — every net '
                      'below is unmeasured')
    for arm in sorted(set(aa) | set(ab)):
        b0, d0 = aa.get(arm, (0, 0))
        b1, d1 = ab.get(arm, (0, 0))
        net = (b1 - b0) - (d1 - d0)
        e = ob.get(arm, {})
        print('  arm %-3d born %+d died %+d net %+d   TOTAL=%s owner-dead=%s '
              'owner-unrecorded=%s owner-stray=%s untagged=%s'
              % (arm, b1 - b0, d1 - d0, net, e.get('total'), e.get('dead'),
                 e.get('unrec'), e.get('stray'), e.get('untagged')))
        if net <= 0:
            continue
        # PASS 21: adjudicate the owner-unrecorded population BY SITE before
        # anything else touches this arm. Pass 20 left "9 of 29 survivors are
        # owner-unrecorded" standing as an open residual for a whole pass
        # because the tally line is only a count.
        check_unrecorded_owners(arm, net, e, orgl_detail)
        if not e or 'dead' not in e or 'stray' not in e:
            inconc.append('arm %d: net %+d across the gap with no owner '
                          'discriminator dump at sample B — unadjudicated, '
                          'which is not green' % (arm, net))
            continue
        tot = e.get('total', 0)
        if tot > 0 and e.get('unrec', 0) == tot:
            inconc.append('arm %d: net %+d over %d survivors, NONE with a '
                          'recorded owner — owner-dead=0 is vacuous here'
                          % (arm, net, tot))
            continue
        if e['dead'] == 0 and e['stray'] == 0:
            notes.append('arm %d: RESIDENCY, net %+d across the gap, '
                         'owner-dead=0, owner-stray=0 of %d survivors'
                         % (arm, net, tot))
        else:
            bad.append('arm %d: LEAK — net %+d across the gap, owner-dead=%d, '
                       'survivors no longer mapped by their owner=%d'
                       % (arm, net, e['dead'], e['stray']))

    emit()


def emit():
    print()
    for n in notes:
        print('OK:    ' + n)
    for i in inconc:
        print('INCON: ' + i)
    for b in bad:
        print('BAD:   ' + b)
    print()
    if bad:
        print('VERDICT: FAIL')
        sys.exit(1)
    if inconc:
        print('VERDICT: INCONCLUSIVE')
        sys.exit(125)
    print('VERDICT: PASS — no measurable leak at hours scale')
    sys.exit(0)


main()
