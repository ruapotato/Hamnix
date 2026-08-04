#!/usr/bin/env python3
"""Difference the KERNEL HEAP (kmalloc/slab) between the two samples of a
one-boot hours-apart census run — leak pass 20.

    leak_kmtrack_diff.py <serial.log> [max_bytes_growth]

Exit status follows scripts/_verdict.sh: 0 PASS, 1 FAIL, 125 INCONCLUSIVE.

WHY THIS FILE EXISTS
--------------------
scripts/test_leak_hours_census.sh has issued `kmtrack dump` as step 6 of BOTH
sample batteries since pass 19, and scripts/leak_hours_census_report.py does
not contain the string "kmtrack". The kernel heap was being CAPTURED and never
ADJUDICATED: a pass-19 PASS said nothing whatsoever about kmalloc/slab, while
reading as though it covered the machine. The census walk is explicit about its
own scope in the guest log —

    [census] scope: USER-MAPPED sites only. kernel sites (pgtable/slab/kstack/
    pml4/wsys/tmpfs) have no user PTE by design and are NOT judged here — use
    kmtrack for the heap.

— so the orphan census CANNOT see a kernel-heap leak by construction, and
nothing else was looking. That is the classic shape this campaign keeps
catching: a green from an instrument that never pointed at the question.

It is a separate file from the pass-19 adjudicator on purpose, and for the same
reason that one is separate from the gate: the input is a captured log, so this
is mutation-testable in seconds (scripts/test_leak_kmtrack_diff.sh) where the
producing gate needs an eight-hour KVM boot.

THE TWO INDEPENDENT ESTIMATORS, AND WHY DISAGREEMENT IS A VERDICT
-----------------------------------------------------------------
mm/slab.ad publishes FOUR counters per site: a live/bytes histogram
(incremented in _km_note_alloc, decremented in _km_drain) and cumulative
allocs/frees. Between two samples with no `kmtrack reset` in between, these
give two independent readings of the same quantity:

    est1 = live[B]   - live[A]
    est2 = (allocs[B] - allocs[A]) - (frees[B] - frees[A])

They agree unless _km_drain's clamp fired — i.e. a site drained below zero,
which happens when an object allocated BEFORE arming is freed against a site
that was never charged for it. When they disagree the series is CONTAMINATED
and the honest verdict is INCONCLUSIVE with the site named, not the prettier of
the two numbers. (Pass 15's rule, applied to the heap.)

THE BLINDNESS CONTROLS
----------------------
A zero delta from a tracker that was never armed is indistinguishable from a
zero delta from a machine that never leaked, so all of these are INCONCLUSIVE:

  * either sample has no `[kmtrack]` header line at all;
  * `mode=0` in either sample — the tracker is OFF and every counter is stale;
  * a header but no per-site lines — nothing was attributed;
  * `exhausted` non-zero in either sample. The site-block pool ran out, so some
    slab pages are untracked and their objects book to UNKNOWN. Per-site
    attribution is then a prefix of the population, exactly like the census
    walk's TRUNCATED, and pass 19 made TRUNCATED inconclusive for this reason;
  * `blocks` at the KM_BLK_SLOTS ceiling (8192) — the pool is full, so the very
    next slab page is untracked even though `exhausted` has not ticked yet.

FAIL
----
  * total live heap bytes grew by more than <max_bytes_growth> across a gap in
    which nothing was launched and nothing was closed.
  * any counter went BACKWARDS in a cumulative series (allocs or frees smaller
    in B than in A). Those are monotone by construction, so a decrease means a
    `kmtrack reset` landed between the samples and the difference is not a
    difference of anything.
"""
import re
import sys

# Mirrors the KM_SITE_* ids in mm/slab.ad. That list is APPEND ONLY by
# documented policy, so an id never changes meaning between passes; an id
# beyond this table is printed by number rather than dropped.
KMNAME = {0: 'unknown', 1: 'vfs', 2: 'vma', 3: 'wsys', 4: 'vk', 5: 'task',
          6: 'abi', 7: 'net', 8: 'block', 9: 'snd', 10: 'tmpfs',
          11: 'selftest', 12: 'pipe', 13: 'pgrp'}
KM_BLK_SLOTS = 8192

bad, inconc, notes = [], [], []


def split_samples(log):
    """{'A': text, 'B': text}, split on the gate's HC_SAMPLE fences.

    Same convention as leak_hours_census_report.py: hamsh echoes each command
    back before running it, so the fence appears twice and the split is on the
    ANCHORED echo of the bare marker, which is the form the shell prints on a
    line of its own.
    """
    out, cur, buf = {}, None, []
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


def parse_km(text):
    """-> (header|None, {site: {live,bytes,allocs,frees}}).

    The LAST header in the sample wins: the gate issues exactly one dump per
    battery, but hamsh's echo of the command line is also in the capture and a
    retry would leave two, and the later one is the one the site lines below it
    belong to.
    """
    hdr = None
    for m in re.finditer(r'\[kmtrack\] mode=(\d+) blocks=(\d+) '
                         r'exhausted=(\d+)', text):
        hdr = {'mode': int(m.group(1)), 'blocks': int(m.group(2)),
               'exhausted': int(m.group(3))}
    sites = {}
    for m in re.finditer(r'\[kmtrack\] site (\d+): live=(\d+) bytes=(\d+)',
                         text):
        e = sites.setdefault(int(m.group(1)), {})
        e['live'] = int(m.group(2))
        e['bytes'] = int(m.group(3))
    for m in re.finditer(r'\[kmtrack\] site (\d+): allocs=(\d+) frees=(\d+)',
                         text):
        e = sites.setdefault(int(m.group(1)), {})
        e['allocs'] = int(m.group(2))
        e['frees'] = int(m.group(3))
    return hdr, sites


def sname(i):
    return KMNAME.get(i, 'site%d' % i)


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[2].strip())
        return 125
    max_growth = int(sys.argv[2]) if len(sys.argv) > 2 else 65536
    try:
        with open(sys.argv[1], 'r', errors='replace') as f:
            log = f.read()
    except OSError as e:
        print('[kmdiff] INCONCLUSIVE: cannot read log: %s' % e)
        return 125

    samples = split_samples(log)
    print('[kmdiff] kernel-heap (kmalloc/slab) difference, one boot, two '
          'samples')
    print('[kmdiff] growth bar: %d bytes over the whole gap' % max_growth)

    for s in ('A', 'B'):
        if s not in samples:
            inconc.append('sample %s is missing entirely' % s)
    if inconc:
        return emit()

    hdr, sites = {}, {}
    for s in ('A', 'B'):
        hdr[s], sites[s] = parse_km(samples[s])
        if hdr[s] is None:
            inconc.append('sample %s has no [kmtrack] header — the heap was '
                          'never dumped, so nothing about it is asserted' % s)
            continue
        print('[kmdiff] sample %s: mode=%d blocks=%d exhausted=%d sites=%d'
              % (s, hdr[s]['mode'], hdr[s]['blocks'], hdr[s]['exhausted'],
                 len(sites[s])))
        if hdr[s]['mode'] == 0:
            inconc.append('sample %s reports mode=0 — kmtrack is OFF and every '
                          'counter below it is stale' % s)
        if not sites[s]:
            inconc.append('sample %s has a [kmtrack] header but no site lines '
                          '— nothing was attributed' % s)
        if hdr[s]['exhausted'] != 0:
            inconc.append('sample %s: site-block pool EXHAUSTED %d times — '
                          'some slab pages are untracked and their objects '
                          'book to UNKNOWN, so per-site attribution covers '
                          'only a prefix of the heap'
                          % (s, hdr[s]['exhausted']))
        if hdr[s]['blocks'] >= KM_BLK_SLOTS:
            inconc.append('sample %s: %d/%d site blocks used — the pool is '
                          'full, so the next slab page is untracked even '
                          'though exhausted has not ticked yet'
                          % (s, hdr[s]['blocks'], KM_BLK_SLOTS))
    if inconc:
        return emit()

    # --- per-site attribution, with the estimators cross-checked -----------
    all_sites = sorted(set(sites['A']) | set(sites['B']))
    tot_bytes = {'A': 0, 'B': 0}
    print('[kmdiff] per-site:')
    print('[kmdiff]   %-4s %-10s %8s %8s %7s  %10s %10s %9s'
          % ('id', 'site', 'liveA', 'liveB', 'dLive', 'bytesA', 'bytesB',
             'dBytes'))
    for i in all_sites:
        a = sites['A'].get(i, {})
        b = sites['B'].get(i, {})
        la, lb = a.get('live', 0), b.get('live', 0)
        ba, bb = a.get('bytes', 0), b.get('bytes', 0)
        tot_bytes['A'] += ba
        tot_bytes['B'] += bb
        print('[kmdiff]   %-4d %-10s %8d %8d %+7d  %10d %10d %+9d'
              % (i, sname(i), la, lb, lb - la, ba, bb, bb - ba))
        # Cumulative counters are monotone by construction.
        for k in ('allocs', 'frees'):
            if k in a and k in b and b[k] < a[k]:
                bad.append('site %d (%s): cumulative %s went BACKWARDS '
                           '%d -> %d. Those counters only ever increase, so a '
                           'kmtrack reset landed between the samples and this '
                           'is not a difference of anything.'
                           % (i, sname(i), k, a[k], b[k]))
        # Two independent estimators of the same delta.
        if all(k in a and k in b for k in ('allocs', 'frees')):
            est2 = (b['allocs'] - a['allocs']) - (b['frees'] - a['frees'])
            if est2 != lb - la:
                inconc.append('site %d (%s): the two estimators DISAGREE — the '
                              'live histogram says %+d, allocs-minus-frees '
                              'says %+d. _km_drain clamped, i.e. this site was '
                              'charged for fewer objects than were freed '
                              'against it, so its series is contaminated and '
                              'neither number is the answer.'
                              % (i, sname(i), lb - la, est2))

    d = tot_bytes['B'] - tot_bytes['A']
    print('[kmdiff] TOTAL live heap bytes: A=%d B=%d delta=%+d'
          % (tot_bytes['A'], tot_bytes['B'], d))
    if d > max_growth:
        bad.append('kernel heap grew %+d bytes over a gap in which nothing was '
                   'launched and nothing was closed (bar %d).'
                   % (d, max_growth))
    elif d > 0:
        notes.append('kernel heap grew %+d bytes, under the %d-byte bar — '
                     'named here rather than rounded to zero.' % (d, max_growth))
    return emit()


def emit():
    for n in notes:
        print('[kmdiff] NOTE: %s' % n)
    if bad:
        for b in bad:
            print('[kmdiff] FAIL: %s' % b)
        print('[kmdiff] VERDICT: FAIL')
        return 1
    if inconc:
        for c in inconc:
            print('[kmdiff] INCONCLUSIVE: %s' % c)
        print('[kmdiff] VERDICT: INCONCLUSIVE — nothing asserted about the '
              'kernel heap')
        return 125
    print('[kmdiff] VERDICT: PASS — kernel heap flat across the gap')
    return 0


if __name__ == '__main__':
    sys.exit(main())
