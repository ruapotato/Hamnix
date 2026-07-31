#!/usr/bin/env python3
"""Adjudicate an hours-apart, one-boot census pair (leak pass 19).

    leak_hours_census_report.py <serial.log> <stamps> <min_gap_s> <growth_fail_pages>

Exit status follows scripts/_verdict.sh: 0 PASS, 1 FAIL, 125 INCONCLUSIVE.

THIS FILE IS SEPARATE FROM THE GATE ON PURPOSE. The gate needs a two-hour KVM
boot to produce a log; the adjudication needs none, so keeping it out of the
heredoc is what makes it mutation-testable in seconds against synthetic and
against real captured logs. Every mutation in the pass-19 table was run
against this file, not against a boot.

WHAT IT ASSERTS, AND WHY EACH ONE IS HERE
-----------------------------------------
INCONCLUSIVE (125), not PASS, when:
  * the elapsed gap between the two samples is below <min_gap_s>. A gate named
    "hours" that ran four minutes is the purest false green available here.
  * either sample is missing a per-site table, either census control, the
    [cens3] run predicate, or its plant's physical address. A plant you cannot
    identify cannot be discounted; a census without both controls is not a
    measurement; a blind census and an empty population print the same zero.
  * any site reports TRUNCATED — it covered a prefix of the population.
  * an arm shows a positive inter-sample net over a population NONE of whose
    members has a recorded owner (`owner-dead=0` is vacuous there).

FAIL when:
  * any frame is UNACCOUNTED after discounting the plant, in either sweep;
  * the run predicate reports zero UNACCOUNTED while a plant is outstanding
    (it is over-claiming, and its verdict is void);
  * an arm's inter-sample net is positive with owner-dead or owner-stray > 0;
  * the total live-page delta over the gap exceeds <growth_fail_pages> while
    the live task set was unchanged.
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
    """Return {'A': text, 'B': text} split on the HC_SAMPLE fences.

    hamsh echoes each command line back before running it, so the fence text
    appears twice; the split is on the ANCHORED echo of the bare marker, which
    is the form the shell prints on its own line.
    """
    out = {}
    cur, buf = None, []
    for ln in log.splitlines():
        m = re.match(r'^HC_SAMPLE ([AB])\s*$', ln)
        if m:
            if cur is not None:
                out.setdefault(cur, []).extend(buf)
            cur, buf = m.group(1), []
            continue
        if re.match(r'^HC_SAMPLE_END ([AB])\s*$', ln):
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
        m = re.match(r'^HC_STATM ([AB]) (\d+)\s*$', ln)
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


def main():
    log = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
    log = log.replace('\r', '')
    stamps_path, min_gap, growth_bar = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

    stamps = {}
    try:
        for ln in open(stamps_path):
            f = ln.split()
            if len(f) == 2:
                stamps[f[0]] = int(f[1])
    except OSError:
        pass

    samples = split_samples(log)
    print('=== leak pass 19: hours-apart census on ONE boot ===')
    for s in ('A', 'B'):
        if s not in samples:
            inconc.append('sample %s never appeared in the log — the run did '
                          'not produce a pair to difference' % s)
    if 'A' in stamps and 'B' in stamps:
        gap = stamps['B'] - stamps['A']
        print('sample A at %d, sample B at %d, gap %ds (%.2f h)'
              % (stamps['A'], stamps['B'], gap, gap / 3600.0))
        if gap < min_gap:
            inconc.append('the two samples are only %ds apart (minimum %ds). '
                          'This run did NOT measure hours, and reporting a '
                          'PASS for it would be the exact false green this '
                          'gate exists to avoid.' % (gap, min_gap))
    else:
        gap = None
        inconc.append('no sample timestamps recorded — the elapsed gap is '
                      'unknown, so "hours apart" is unverified')

    if 'A' not in samples or 'B' not in samples:
        emit()
        return

    ta, tb = samples['A'], samples['B']
    sa, sb = parse_sites(ta), parse_sites(tb)
    if not sa or not sb:
        inconc.append('a per-site [trk] table is missing (A=%d sites, '
                      'B=%d sites) — there is nothing to difference'
                      % (len(sa), len(sb)))

    ca, cb = parse_census(ta), parse_census(tb)
    print()
    print('=== census, both sweeps ===')
    for nm, c in (('A', ca), ('B', cb)):
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
            print('  site %-3d %-13s A=%-7d B=%-7d delta %+d'
                  % (s, PGNAME.get(s, '?'), a, b, b - a))
    print('  TOTAL live pages A=%d B=%d delta %+d' % (total_a, total_b,
                                                      total_b - total_a))
    if gap:
        print('  => %.2f pages/hour, i.e. %.1f MiB/year at this rate'
              % ((total_b - total_a) / (gap / 3600.0),
                 (total_b - total_a) / (gap / 3600.0) * 8766 * 4 / 1024.0))

    # ---- the long-lived processes: THE thing nothing has ever measured ------
    tka, tkb = parse_tasks(ta), parse_tasks(tb)
    ma, mb = parse_statm(log, 'A'), parse_statm(log, 'B')
    lived = sorted(set(tka) & set(tkb))
    born = sorted(set(tkb) - set(tka))
    died = sorted(set(tka) - set(tkb))
    print()
    print('=== long-lived processes (alive at BOTH samples) ===')
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
            print('  pid %-6d %-16s statm MISSING (A=%s B=%s)'
                  % (p, tka[p], a, b))
            continue
        mark = ''
        if b > a:
            mark = '   <-- GREW'
            grew.append((p, tka[p], b - a))
        print('  pid %-6d %-16s resident A=%-7d B=%-7d delta %+d%s'
              % (p, tka[p], a, b, b - a, mark))
    if not any(p in ma and p in mb for p in lived):
        inconc.append('not one long-lived process yielded a statm reading in '
                      'BOTH samples — this arm is blind, not clean')
    if born:
        notes.append('processes that appeared during the gap: %s'
                     % ', '.join('%d/%s' % (p, tkb[p]) for p in born))
    if died:
        notes.append('processes that exited during the gap: %s'
                     % ', '.join('%d/%s' % (p, tka[p]) for p in died))
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

    # ---- arms: inter-sample nets, adjudicated by the owner discriminator ----
    aa, ab = parse_arms(ta), parse_arms(tb)
    oa, ob = parse_owners(ta), parse_owners(tb)
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
