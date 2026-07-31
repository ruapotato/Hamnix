#!/usr/bin/env bash
# scripts/test_pidh_no_tombstone.sh — the pid->slot hash must not degrade with
# uptime.
#
# THE BUG THIS EXISTS TO KILL (leak pass 20, 2026-07-31)
# ======================================================
# kernel/sched/core.ad's pid->slot hash is open-addressed with linear probing.
# It used to remove by writing a PIDH_DELE tombstone, and NOTHING ever
# converted a tombstone back to PIDH_EMPTY: no rehash, no compaction. Because
# `next_pid` is strictly monotonic (it only resets in sched_init), a tombstoned
# bucket was never reclaimed by a re-insert of the same pid either.
#
# Inserts coped, because _pidh_insert reuses tombstones. LOOKUPS did not:
# _pidh_get terminates a probe chain only on a match or on PIDH_EMPTY. So after
# roughly PIDH_SIZE (1024) cumulative process exits — a few hours on a desktop
# that launches apps — no bucket anywhere was PIDH_EMPTY, and every hash MISS
# walked all 1024 buckets before falling back to the legacy O(NTASKS) linear
# scan. task_lookup_by_pid sits on the signal, waitpid, /proc and devwsys-prune
# paths.
#
# It leaks no memory. It just permanently stops being a hash, and never
# recovers short of a reboot — which is precisely what a months-of-uptime bar
# cannot afford, and precisely the class the devwsys per-pid window table
# belonged to.
#
# WHAT THIS GATE ASSERTS
# ======================
#   (1) SOURCE INVARIANT: the pid hash declares no tombstone sentinel. A
#       reintroduced PIDH_DELE global is the regression, and it is greppable.
#   (2) THE ALGORITHM IS CORRECT: the backward-shift removal now in core.ad,
#       transcribed line-for-line, is brute-forced against a reference dict
#       over 400k churn events at the kernel's REAL table size, hash multiplier
#       and load factor. Every live pid must resolve to its right slot
#       throughout, and the live-entry count must match.
#   (3) IT DOES NOT DEGRADE: EMPTY buckets must survive the churn and the
#       worst-case miss must stay small.
#
# THE GATE'S OWN POSITIVE CONTROL (a green from a blind instrument is worse
# than a red — this campaign has caught four of those)
# ====================================================================
# Assertion (3) would also pass against a table that was simply never
# populated, and a model that had silently stopped exercising removal would
# look perfect. So the gate ALSO runs the OLD tombstone algorithm through the
# identical harness and REQUIRES it to degrade — 0 EMPTY buckets left and a
# worst-case miss of the full table. If the control comes back clean, the
# harness cannot see the bug it exists to catch, and the gate reports
# INCONCLUSIVE rather than PASS.
#
# QEMU-free and fast, so it is registered and runs on every push.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
TAG="[pidh]"

CORE="kernel/sched/core.ad"
[ -f "$CORE" ] || { echo "$TAG INCONCLUSIVE: $CORE absent" >&2; exit 125; }

# --- (1) the source invariant ---------------------------------------------
# A comment may DISCUSS the old tombstone (the fix's own note does); a
# declaration reintroduces it. Match the global definition specifically.
if grep -nE '^[[:space:]]*PIDH_DELE[[:space:]]*:' "$CORE"; then
    echo "$TAG FAIL: PIDH_DELE is declared again in $CORE." >&2
    echo "$TAG   Tombstones in this table are never reclaimed — the pid hash" >&2
    echo "$TAG   degrades to a full-table scan on every miss after ~1024 exits" >&2
    echo "$TAG   and never recovers. Remove by backward-shift instead." >&2
    exit 1
fi
if ! grep -q 'BACKWARD-SHIFT' "$CORE"; then
    echo "$TAG INCONCLUSIVE: $CORE no longer documents a backward-shift" >&2
    echo "$TAG   removal — the thing this gate models may not be what runs." >&2
    exit 125
fi
echo "$TAG source invariant ok: no tombstone sentinel; removal is backward-shift"

# --- (2)(3) the model, and its own positive control ------------------------
python3 - "$TAG" <<'PY'
import random
import sys

TAG = sys.argv[1]
SIZE = 1024          # PIDH_SIZE
EMPTY = 0            # PIDH_EMPTY
DELE = (1 << 64) - 1 # the OLD tombstone sentinel (control arm only)
M = 2654435761       # the multiplier in core.ad
MASK = (1 << 64) - 1
NTASKS = 512


def home(p):
    return ((p * M) & MASK) % SIZE


class Table:
    def __init__(self, tombstone):
        self.pid = [EMPTY] * SIZE
        self.slot = [0] * SIZE
        self.tombstone = tombstone

    def insert(self, pid, slot):
        if pid == 0:
            return
        h = home(pid)
        probes = 0
        while probes < SIZE:
            b = (h + probes) % SIZE
            bp = self.pid[b]
            if bp == pid:
                self.slot[b] = slot
                return
            # The old insert reused tombstones; the new one only sees EMPTY.
            if bp == EMPTY or (self.tombstone and bp == DELE):
                self.pid[b] = pid
                self.slot[b] = slot
                return
            probes += 1

    def get(self, pid):
        """(slot_or_-1, probes_taken) — stops only at a match or EMPTY."""
        if pid == 0:
            return -1, 0
        h = home(pid)
        probes = 0
        while probes < SIZE:
            b = (h + probes) % SIZE
            bp = self.pid[b]
            if bp == pid:
                return self.slot[b], probes + 1
            if bp == EMPTY:
                return -1, probes + 1
            probes += 1
        return -1, SIZE

    def remove(self, pid):
        if pid == 0:
            return
        h = home(pid)
        probes = 0
        i = SIZE
        while probes < SIZE:
            b = (h + probes) % SIZE
            bp = self.pid[b]
            if bp == pid:
                i = b
                probes = SIZE
            else:
                if bp == EMPTY:
                    return
                probes += 1
        if i == SIZE:
            return
        if self.tombstone:
            self.pid[i] = DELE
            self.slot[i] = 0
            return
        # Backward-shift: punch the hole, then pull back any later entry whose
        # home lies at or before it. dk >= di is the standard move rule.
        moving = 1
        while moving == 1:
            self.pid[i] = EMPTY
            self.slot[i] = 0
            moving = 0
            j = i
            steps = 0
            while steps < SIZE:
                j = (j + 1) % SIZE
                steps += 1
                jp = self.pid[j]
                if jp == EMPTY:
                    steps = SIZE
                else:
                    kh = home(jp)
                    di = (j + SIZE - i) % SIZE
                    dk = (j + SIZE - kh) % SIZE
                    if dk >= di:
                        self.pid[i] = jp
                        self.slot[i] = self.slot[j]
                        i = j
                        moving = 1
                        steps = SIZE

    def live(self):
        return sum(1 for x in self.pid
                   if x != EMPTY and not (self.tombstone and x == DELE))


def run(tombstone, iters=400000, seed=1234):
    random.seed(seed)
    t = Table(tombstone)
    ref = {}
    next_pid = 1
    worst_miss = 0
    total_miss = 0
    nmiss = 0
    for it in range(iters):
        if len(ref) < NTASKS // 2 and (random.random() < 0.55 or not ref):
            p = next_pid
            next_pid += 1
            s = random.randrange(NTASKS)
            t.insert(p, s)
            ref[p] = s
        else:
            p = random.choice(list(ref))
            t.remove(p)
            del ref[p]
        # A pid that is definitely absent: the cost tombstones destroyed.
        _, pr = t.get(next_pid + 10_000_000)
        worst_miss = max(worst_miss, pr)
        total_miss += pr
        nmiss += 1
        if it % 20000 == 0:
            for p, s in ref.items():
                got, _ = t.get(p)
                assert got == s, "pid %d -> %s want %d at it=%d" % (
                    p, got, s, it)
            assert t.live() == len(ref), "live %d ref %d at it=%d" % (
                t.live(), len(ref), it)
    for p, s in ref.items():
        got, _ = t.get(p)
        assert got == s, "final: pid %d -> %s want %d" % (p, got, s)
    assert t.live() == len(ref), "final live %d ref %d" % (t.live(), len(ref))
    empties = sum(1 for x in t.pid if x == EMPTY)
    return empties, worst_miss, total_miss / nmiss, len(ref)


# --- the shipped algorithm ---
emp, worst, mean, live = run(tombstone=False)
print('%s backward-shift : live=%d EMPTY=%d/%d worst-miss=%d mean-miss=%.2f'
      % (TAG, live, emp, SIZE, worst, mean))

# --- the positive control: the OLD algorithm MUST degrade ---
cemp, cworst, cmean, clive = run(tombstone=True)
print('%s CONTROL(tomb)  : live=%d EMPTY=%d/%d worst-miss=%d mean-miss=%.2f'
      % (TAG, clive, cemp, SIZE, cworst, cmean))

bad = []
inconc = []
if cemp != 0 or cworst < SIZE:
    inconc.append(
        'the tombstone CONTROL did not degrade (EMPTY=%d, worst=%d). The '
        'harness cannot see the bug it exists to catch, so its green on the '
        'shipped algorithm means nothing.' % (cemp, cworst))
if emp <= 0:
    bad.append('no EMPTY bucket survived the churn — every miss now walks the '
               'whole table; the degradation is back')
if worst >= 64:
    bad.append('worst-case miss grew to %d probes (bar 64)' % worst)
if mean >= 8.0:
    bad.append('mean miss cost %.2f probes (bar 8.0)' % mean)

for m in inconc:
    print('%s INCONCLUSIVE: %s' % (TAG, m), file=sys.stderr)
for m in bad:
    print('%s FAIL: %s' % (TAG, m), file=sys.stderr)
if inconc:
    sys.exit(125)
if bad:
    sys.exit(1)
print('%s   control degraded as required (%.0fx the shipped mean), so the '
      'harness is not blind' % (TAG, cmean / mean))
sys.exit(0)
PY
rc=$?
if [ "$rc" -eq 125 ]; then
    echo "$TAG INCONCLUSIVE — see above" >&2
    exit 125
fi
if [ "$rc" -ne 0 ]; then
    echo "$TAG FAIL — see above" >&2
    exit 1
fi
echo "$TAG PASS — no tombstone sentinel in the pid hash, and the backward-shift"
echo "$TAG   removal it uses keeps lookups O(1) across 400k churn events while"
echo "$TAG   the old tombstone algorithm degrades to a full-table scan."
exit 0
