#!/usr/bin/env bash
# scripts/test_cow_hamterm_origin.sh — the COW share arms, counted under the
# ONE workload that ever stranded frames: the DE terminal.
#
# WHY THIS GATE EXISTS (leak pass 16)
# ===================================
# Pass 14 named the burst: of 212 app launches across 53 soak cycles,
# `hamtermscene` stranded frames on 23 of 23 launches (~298 frames/launch) and
# every other app in the pool was within noise of zero. It is the only app that
# forks, so it is the only one that runs the COW share at all.
#
# Pass 15 then took the two `vma_fork_copy` share arms (23 = owner-mmap,
# 24 = demand-resident) and found them clean — but it drove them with
# /bin/u_mmap_fork, and said so explicitly:
#
#     "The +56 was measured under the DE soak's hamtermscene workload; this
#      gate runs u_mmap_fork. A leak needing a VMA shape u_mmap_fork never
#      builds ... would not appear here."
#
# That caveat is load-bearing, and this gate removes it: SAME instrument
# (`track origin`, `track org N`, `track census`), DIFFERENT driver — the real
# terminal, opened and closed the way the DE's own close box does it.
#
# THE ASSERTION
# =============
# For every COW origin arm, over the inter-cycle deltas of an identical,
# repeated terminal open/close:
#
#     net == 0                                          -> closed
#     net > 0, owner-dead == 0, and every survivor is
#              still mapped by its live owner            -> residency
#     anything else                                      -> LEAK
#
# plus a whole-machine orphan census with BOTH controls in the same run:
# `track plant` (a frame mapped nowhere, which MUST be reported) and
# `track mplant` (a mapped frame, which must NOT be). An orphan count without
# both is not a measurement — a blind census and an empty population print the
# same zero.
#
# WHY DELTAS AND NOT `born == died`. cow_share_page takes a frame 0 -> 2; the
# child's death returns it to 1, not 0, and the frame is not dead while the
# parent still maps it. The DE's own shell is alive for the whole run, so an
# absolute balance is a permanent false red. The closed-form quantity is the
# INTER-CYCLE delta of an identical workload: one-time populations are born in
# cycle 1, a per-cycle leak is a constant positive net on every later cycle.
#
# THE KERNEL HEAP RIDES ALONG (mission 2). The same boot arms `kmtrack` and
# dumps it per cycle, so the per-site kernel-heap growth per terminal cycle
# comes out of the SAME run — no second boot, no second workload, and the two
# answers cannot disagree about which cycle they describe.
#
# Env: INSTALLER_IMG, OVMF_FD, BOOT_WAIT, OUT_DIR, CYCLES.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[cowterm]"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
# FOUR cycles -> THREE inter-cycle deltas. Three is the minimum that
# distinguishes "one-time population" (net 0 after cycle 1) from "per-cycle
# leak" (constant positive net) without appealing to a slope, and gives one
# delta of contrast on either side of the assertion.
CYCLES="${CYCLES:-4}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/cow_hamterm_origin/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

# INCONCLUSIVE (125), not PASS (0). GitHub runners have no /dev/kvm, so an
# `exit 0` here made this gate report GREEN on every CI run while asserting
# nothing whatsoever about COW origins — the precise false-green class
# scripts/test_gate_kvmdark.sh ratchets against, and this gate has been the
# ratchet's only red since it was registered. 125 makes ci_run_gate.sh warn
# instead of counting the run as proof. See scripts/_verdict.sh.
[ -e /dev/kvm ] || { echo "$TAG INCONCLUSIVE: /dev/kvm absent — nothing asserted" >&2; exit 125; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "$TAG SKIP-RUNTIME: no OVMF" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "$TAG SKIP-RUNTIME: no socat" >&2; exit 0; }

# shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if declare -F installer_img_or_verdict >/dev/null 2>&1; then
    installer_img_or_verdict "$INSTALLER_IMG" "$TAG"
else
    installer_img_warn_if_stale "$INSTALLER_IMG" "$TAG"
fi
[ -f "$INSTALLER_IMG" ] || {
    echo "$TAG RESULT: INCONCLUSIVE ($INSTALLER_IMG absent — nothing booted)" >&2
    exit 125; }
IMG_SZ=$(stat -c %s "$INSTALLER_IMG" 2>/dev/null || echo 0)
if [ "$IMG_SZ" -lt 33554432 ]; then
    echo "$TAG SKIP-RUNTIME: $INSTALLER_IMG is only ${IMG_SZ}B — a build is" >&2
    echo "$TAG   probably still writing it." >&2
    exit 0
fi
# The image AGE against what is on disk is the only signal that the kernel
# edit under test is actually in the thing being booted (pass 13 lost a whole
# measurement to a stale image, and `mm/` was missing from the image's input
# dirs until 07-30). Print it every time; an implausible number is the tell.
echo "$TAG image age: $(( $(date +%s) - $(stat -c %Y "$INSTALLER_IMG") ))s"

mkdir -p "$OUT_DIR"
echo "$TAG output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-ct.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-ct.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-ct-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-ct.XXXXXX).in
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    # Kill ONLY our own QEMU by recorded pid. Never a pattern kill — a
    # concurrent gate's boot is not ours to end.
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO"
}
trap cleanup EXIT
exec 4<>"$FIFO"; exec 3>"$FIFO"

# grep -a everywhere: the serial log carries NUL bytes.
wait_for() {
    local pat="$1" deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
mapped_count() { grep -ac "\[devwsys\] window .* mapped" "$LOG"; }

qemu-system-x86_64 \
    -enable-kvm -cpu host -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio -m 1G \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

echo "$TAG waiting up to ${BOOT_WAIT}s for the DE handoff..."
wait_for "$HANDOFF_MARKER" "$BOOT_WAIT" || {
    echo "$TAG FAIL: no handoff marker in ${BOOT_WAIT}s" >&2
    tail -40 "$LOG" >&2; exit 1; }
sleep 8
# hamsh drops the FIRST serial command; burn one on a ready marker.
printf 'echo MARK_CT_READY\n' >&3
sleep 1
wait_for MARK_CT_READY 12 || { printf 'echo MARK_CT_READY\n' >&3; sleep 2; }

fail=0
say_fail() { echo "$TAG FAIL $*" >&2; fail=1; }

# send <cmd> <marker> <timeout> — run a ctl write and wait for its own echo
# marker rather than sleeping. A sleep that is too short silently drops the
# very dump the gate asserts on.
send() {
    local cmd="$1" mark="$2" to="${3:-30}"
    printf '%s; echo %s\n' "$cmd" "$mark" >&3
    local d=$(( SECONDS + to ))
    while [ "$SECONDS" -lt "$d" ]; do
        # ANCHORED: hamsh echoes the command line (which contains the marker)
        # back before running it, so an unanchored match finds the echo.
        grep -aq "^${mark}" "$LOG" && { sleep 1; return 0; }
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

# ARM. `track full` = page tracker mode 2 + the COW ledger (same verb the soak
# uses). kmtrack is armed independently — the two answer different questions.
send "echo track full > /proc/meminfo" CT_ARM_PAGE 40 || say_fail "track full timed out"
send "echo kmtrack on > /proc/meminfo"  CT_ARM_KM   40 || say_fail "kmtrack on timed out"

c=0
while [ "$c" -lt "$CYCLES" ]; do
    c=$((c+1))
    before=$(mapped_count)
    # Launch as a CHILD OF THIS SHELL: devproc's note gate is
    # caller-uid == target-uid, so /bin/kill closes it exactly the way the
    # DE's own close box does (hamUId daemon_close_slot -> p9_note_tree).
    printf '/bin/hamtermscene &\n' >&3
    d=$(( SECONDS + 40 ))
    while [ "$SECONDS" -lt "$d" ]; do
        [ "$(mapped_count)" -gt "$before" ] && break
        sleep 1
    done
    if [ "$(mapped_count)" -le "$before" ]; then
        say_fail "cycle $c: hamtermscene mapped NO window in 40s"
        break
    fi
    line=$(grep -a '\[devwsys\] window .* mapped' "$LOG" | tail -1)
    pid=$(echo "$line" | sed -n 's/.*mapped pid=\([0-9]*\).*/\1/p')
    if [ -z "$pid" ]; then say_fail "cycle $c: no pid in the mapped line"; break; fi
    # Let the child shell actually start, or the close happens before the fork
    # that this whole gate is about — a pass for entirely the wrong reason.
    sleep 4
    exit_base=$(grep -ac "task: pid $pid exited" "$LOG")
    printf '/bin/kill %s\n' "$pid" >&3
    d=$(( SECONDS + 25 ))
    while [ "$SECONDS" -lt "$d" ]; do
        [ "$(grep -ac "task: pid $pid exited" "$LOG")" -gt "$exit_base" ] && break
        sleep 1
    done
    if [ "$(grep -ac "task: pid $pid exited" "$LOG")" -le "$exit_base" ]; then
        say_fail "cycle $c: pid $pid survived the terminate note for 25s"; break
    fi
    # An orphaned zombie is collected by reap_orphan_zombies at the NEXT task
    # allocation, so sample after settling rather than mid-teardown.
    sleep 5
    send "echo track origin > /proc/meminfo" "CT_ORG_c$c" 40 \
        || { say_fail "cycle $c: origin dump timed out"; break; }
    send "echo kmtrack dump > /proc/meminfo" "CT_KM_c$c" 40 \
        || { say_fail "cycle $c: kmtrack dump timed out"; break; }
    # PER-SITE PAGE attribution, same cycle. If no COW arm strands a frame,
    # the residual slope is on a NON-COW allocator, and this is the dump that
    # names which one — without it the answer to "then where?" would need
    # another twelve-minute boot.
    send "echo track dump > /proc/meminfo" "CT_TRK_c$c" 40 \
        || { say_fail "cycle $c: track dump timed out"; break; }
    # Re-baseline the kernel heap ONCE, after the first cycle: everything live
    # at arming time is charged to KM_SITE_UNKNOWN by construction, and the
    # first terminal open also populates every one-time cache. Resetting here
    # makes cycles 2..N a clean per-cycle measurement.
    if [ "$c" -eq 1 ]; then
        send "echo kmtrack reset > /proc/meminfo" CT_KM_RESET 40 \
            || say_fail "kmtrack reset timed out"
    fi
    echo "$TAG cycle $c done (pid $pid)"
done
CYCLES_RUN=$c

# NAME the survivors of every arm that a share path can reach. This is the
# adjudicator: a count cannot tell a stalled leak from a resident set, and
# `owner-dead` / "owner maps here" can.
for arm in 1 2 5 19 21 23 24; do
    send "echo track org $arm > /proc/meminfo" "CT_ORGL_$arm" 60 \
        || say_fail "track org $arm timed out"
done

# WHOLE-MACHINE ORPHAN CENSUS, with BOTH controls outstanding in the SAME
# sweep. Positive: a frame mapped nowhere that MUST be reported. Negative: a
# mapped frame that must NOT be. Neither alone is enough — a blind census and
# an empty population print the same zero, and an over-reporting census
# invalidates every span conclusion drawn from an orphan tally.
send "echo track plant > /proc/meminfo"   CT_PLANT   40 || say_fail "track plant timed out"
send "echo track mplant > /proc/meminfo"  CT_MPLANT  40 || say_fail "track mplant timed out"
send "echo track census > /proc/meminfo"  CT_CENSUS 180 || say_fail "track census timed out"
send "echo track unplant > /proc/meminfo" CT_UNPLANT 40 || true
send "echo track unmplant > /proc/meminfo" CT_UNMPL  40 || true

kill "$QEMU_PID" 2>/dev/null
( sleep 5; kill -9 "$QEMU_PID" 2>/dev/null ) & WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null

echo "$TAG --- origin ledger ---"
grep -aF "[origin]" "$LOG" | tail -80 || true
echo "$TAG --- live-frame owners ---"
grep -aF "[orgl]" "$LOG" || true
echo "$TAG --- kernel heap ---"
grep -aF "[kmtrack]" "$LOG" || true
echo "$TAG --- census ---"
grep -aE "\[census\]" "$LOG" | tail -60 || true
echo "$TAG --- end ---"

if grep -aF -q "[origin] DISARMED" "$LOG" || grep -aF -q "[origin] NO TABLE" "$LOG"; then
    echo "$TAG FAIL: the origin ledger is not armed — every dump is VOID"
    fail=1
fi

SUMMARY="$OUT_DIR/summary.txt"
python3 - "$LOG" "$CYCLES_RUN" > "$SUMMARY" 2>&1 <<'PY'
import re, sys
log = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace').replace('\r', '')
ncyc = int(sys.argv[2])

# --- COW origin: per-arm born/died, one block per `track origin` dump ---
#
# ONLY the per-cycle dumps. `track census` ENDS by calling cow_origin_dump
# itself, so the raw log carries an extra origin block that no terminal
# open/close preceded. Counting it produced an all-zero-births final delta and
# the gate's own positive control correctly called that inconclusive — but the
# right fix is to stop attributing a census's dump to a workload cycle. The
# per-cycle dumps are exactly the ones before the first `track org N`.
cut = log.find('[orgl]')
cycle_log = log[:cut] if cut >= 0 else log
blocks, cur = [], {}
for line in cycle_log.splitlines():
    m = re.search(r'\[origin\] org=(\d+) born=(\d+) died=(\d+)', line)
    if m:
        cur[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
    elif 'tagged live frames' in line:
        blocks.append(cur); cur = {}

print('=== COW origin arms, per-cycle deltas (identical hamtermscene open/close) ===')
if len(blocks) < 3:
    print('VERDICT: FAIL (only %d origin dumps parsed; need >= 3)' % len(blocks))
    sys.exit(1)
arms = sorted(set().union(*[set(b) for b in blocks]))
hdr = 'arm  ' + ''.join('  d%-2d born/died/net' % i for i in range(2, len(blocks) + 1))
print(hdr)
nets = {}
for a in arms:
    row, ns = '%-4d' % a, []
    for i in range(1, len(blocks)):
        b0, d0 = blocks[i - 1].get(a, (0, 0))
        b1, d1 = blocks[i].get(a, (0, 0))
        db, dd = b1 - b0, d1 - d0
        ns.append(db - dd)
        row += '   %5d/%5d/%+d' % (db, dd, db - dd)
    nets[a] = ns
    print(row)

# --- the owner discriminator, per arm ---
own = {}          # arm -> [dead, unrecorded, total]
# `owner-stray` is the KERNEL's own tally over EVERY survivor. The printed
# per-frame detail stops at 64, so deriving stray from the printed lines would
# silently mean "stray among the first 64" — fine for pass 15's population of
# two, a false exoneration for a workload that strands hundreds.
stray = {}
# Survivors with an owner but NO recorded VA: the VA half of the
# discriminator cannot speak for them, and pretending otherwise is a false
# red. Reported, never swept.
untagged = {}
for ln in log.splitlines():
    m = re.search(r'\[orgl\] org=(\d+) owner-dead=(\d+) owner-unrecorded=(\d+)', ln)
    if m:
        a = int(m.group(1))
        own.setdefault(a, [0, 0, 0])
        own[a][0], own[a][1] = int(m.group(2)), int(m.group(3))
        continue
    m = re.search(r'\[orgl\] org=(\d+) owner-stray=(\d+)(?: owner-untagged=(\d+))?', ln)
    if m:
        stray[int(m.group(1))] = int(m.group(2))
        untagged[int(m.group(1))] = int(m.group(3) or 0)
        continue
    m = re.search(r'\[orgl\] org=(\d+) TOTAL=(\d+)', ln)
    if m:
        a = int(m.group(1))
        own.setdefault(a, [0, 0, 0])
        own[a][2] = int(m.group(2))
        continue

print()
print('=== owner discriminator (track org N) ===')
for a in sorted(own):
    d, u, t = own[a]
    print('arm %-3d TOTAL=%-5d owner-dead=%-4d owner-unrecorded=%-4d stray=%-4d '
          'untagged=%d' % (a, t, d, u, stray.get(a, 0), untagged.get(a, 0)))

# --- verdict, on the LAST inter-cycle delta ---
bad, notes = [], []
exercised = False
for a in sorted(nets):
    last = nets[a][-1]
    # POSITIVE CONTROL for the arms themselves: at least one share arm must
    # have taken births in the final window, or "balanced" describes an empty
    # set — the same blind-instrument failure `track plant` rules out for the
    # census.
    b0, d0 = blocks[-2].get(a, (0, 0))
    b1, d1 = blocks[-1].get(a, (0, 0))
    if b1 - b0 > 0:
        exercised = True
    if last <= 0:
        notes.append('arm %d: closed (last net %+d)' % (a, last))
        continue
    if a not in own:
        bad.append('arm %d: last net %+d and NO `track org %d` dump to '
                   'adjudicate it — inconclusive, not green' % (a, last, a))
        continue
    dead, unrec, tot = own[a]
    # A VACUOUS GREEN IS THE FAILURE MODE THIS WHOLE CAMPAIGN GUARDS AGAINST.
    # `owner-dead = 0` over a population whose owner was NEVER RECORDED means
    # "nobody wrote an owner down", not "no owner is dead" — and reporting
    # that as "every survivor is still mapped by its live owner" would be a
    # false exoneration on exactly the kind of span pass 14 found the main
    # leak in. An arm with a positive net and no recorded owner is
    # INCONCLUSIVE, and inconclusive is not green.
    if tot > 0 and unrec == tot:
        bad.append('arm %d: UNADJUDICATED — last net %+d over %d survivors, '
                   'NONE of which has a recorded owner. owner-dead=0 here is '
                   'vacuous; the allocating site needs a pa_set_owner()'
                   % (a, last, tot))
        continue
    if a not in stray:
        bad.append('arm %d: last net %+d and the dump carries no owner-stray '
                   'tally — a stale kernel, so this is inconclusive, not green'
                   % (a, last))
        continue
    if dead == 0 and stray[a] == 0:
        notes.append('arm %d: RESIDENCY, last net %+d, owner-dead=0, no survivor '
                     'has a live owner that stopped mapping it '
                     '(owner-unrecorded=%d, owner-untagged=%d, of %d)'
                     % (a, last, unrec, untagged.get(a, 0), tot))
    else:
        bad.append('arm %d: LEAK — last net %+d, owner-dead=%d, survivors no '
                   'longer mapped by their owner=%d'
                   % (a, last, dead, stray[a]))
if not exercised:
    bad.append('NO share arm took a birth in the final cycle — the workload '
               'never reached the COW share, so a zero net proves nothing')

# --- census, with BOTH controls ---
print()
print('=== census ===')
orph = re.findall(r'\[census\].*orphan(?:ed)? frames?[:= ]+(\d+)', log)
pos = 'control OK: planted orphan detected' in log
neg = 'negative control OK' in log
print('positive control (track plant)  : %s' % ('OK' if pos else 'MISSING'))
print('negative control (track mplant) : %s' % ('OK' if neg else 'MISSING'))
print('orphan counts reported          : %s' % (', '.join(orph) if orph else 'none parsed'))
# NAME the sites, and say whether each one GREW over the cycles. An orphan at
# a site whose live count never moved across an identical repeated workload is
# a fixed residue; one at a site that grows per cycle is the leak itself. The
# count alone cannot tell them apart, and every earlier pass that reported a
# bare orphan number had to re-derive this by hand.
persite = {}
for m in re.finditer(r'\[census\] site (\d+): (\d+) orphans, live (\d+)', log):
    persite[int(m.group(1))] = [int(m.group(2)), int(m.group(3))]
# DISCOUNT THE PLANT FROM ITS OWN SITE. `track plant` allocates at a
# user-mapped site, so the positive control lands in a real site's tally and
# would otherwise be re-reported as a leak in whichever site it happened to
# use. It is identified by its tag, not by its site: page_alloc_census_plant
# stamps 0xc0ffee00 and nothing else does.
planted_site = None
for m in re.finditer(r'\[census\] site (\d+) orphan\[\d+\] tag_va=0x0*c0ffee00', log):
    planted_site = int(m.group(1))
if planted_site is not None and planted_site in persite:
    persite[planted_site][0] -= 1
pgdumps = []
pgcur = None
for ln in log.splitlines():
    if re.search(r'\[trk\] mode=(\d+) frames=(\d+)', ln):
        if pgcur is not None:
            pgdumps.append(pgcur)
        pgcur = {}
        continue
    if pgcur is None:
        continue
    m = re.search(r'\[trk\] site=(\d+) live=(\d+) allocs=(\d+)', ln)
    if m:
        pgcur[int(m.group(1))] = int(m.group(2))
if pgcur is not None:
    pgdumps.append(pgcur)
for s in sorted(persite):
    n_orph, n_live = persite[s]
    if len(pgdumps) >= 2:
        grew = pgdumps[-1].get(s, 0) - pgdumps[0].get(s, 0)
        gtxt = 'live %+d over %d cycles' % (grew, len(pgdumps))
    else:
        gtxt = 'growth unknown (too few page dumps)'
    print('site %-3d %d orphan(s), live %d, %s' % (s, n_orph, n_live, gtxt))
if not pos or not neg:
    bad.append('census controls incomplete (positive=%s negative=%s) — an '
               'orphan count without both controls is not a measurement'
               % (pos, neg))
elif orph:
    n = int(orph[-1])
    # 1 == the deliberately planted positive control and nothing else.
    if n > 1:
        resid = ', '.join('site %d x%d' % (s, persite[s][0])
                          for s in sorted(persite) if persite[s][0] > 0)
        bad.append('census reports %d orphaned frames; 1 is the planted '
                   'positive control (site %s), so %d frame(s) are genuinely '
                   'unreachable — %s'
                   % (n, planted_site, n - 1, resid or 'site unreported'))
    else:
        notes.append('census: %d orphan (the planted positive control), both '
                     'controls green in the same sweep' % n)

print()
for n in notes:
    print('OK:   ' + n)
for b in bad:
    print('BAD:  ' + b)
print()
print('VERDICT: %s' % ('FAIL' if bad else 'PASS'))
sys.exit(1 if bad else 0)
PY
rc=$?
cat "$SUMMARY"
[ "$rc" -ne 0 ] && fail=1

# The kernel heap is REPORTED, not asserted on, in this gate. kmtrack's own
# per-site slopes need a baseline this run does not establish, and a threshold
# invented here would be a number with no measurement behind it. Mission 2
# reads these deltas; it does not gate on them yet.
KMSUM="$OUT_DIR/kmtrack.txt"
python3 - "$LOG" > "$KMSUM" 2>&1 <<'PY'
import re, sys
log = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace').replace('\r', '')
NAMES = {0: 'unknown', 1: 'vfs', 2: 'vma', 3: 'wsys', 4: 'vk', 5: 'task',
         6: 'abi', 7: 'net', 8: 'block', 9: 'snd', 10: 'tmpfs', 11: 'selftest',
         12: 'pipe', 13: 'pgrp'}
dumps, cur = [], None
for ln in log.splitlines():
    m = re.search(r'\[kmtrack\] mode=(\d+) blocks=(\d+) exhausted=(\d+)', ln)
    if m:
        if cur is not None:
            dumps.append(cur)
        cur = {'_hdr': tuple(int(x) for x in m.groups())}
        continue
    if cur is None:
        continue
    m = re.search(r'\[kmtrack\] site (\d+): live=(\d+) bytes=(\d+)', ln)
    if m:
        cur.setdefault(int(m.group(1)), {}).update(
            live=int(m.group(2)), bytes=int(m.group(3)))
        continue
    m = re.search(r'\[kmtrack\] site (\d+): allocs=(\d+) frees=(\d+)', ln)
    if m:
        cur.setdefault(int(m.group(1)), {}).update(
            allocs=int(m.group(2)), frees=int(m.group(3)))
if cur is not None:
    dumps.append(cur)
print('=== kernel heap per terminal open/close (kmtrack) ===')
if not dumps:
    print('no kmtrack dumps parsed')
    sys.exit(0)
for i, d in enumerate(dumps):
    print('dump %d: mode=%d blocks=%d exhausted=%d' % ((i + 1,) + d['_hdr']))
sites = sorted(set(k for d in dumps for k in d if k != '_hdr'))
print()
print('%-4s %-9s %s' % ('site', 'name', '  '.join('d%d live/bytes' % (i + 1)
                                                  for i in range(1, len(dumps)))))
for s in sites:
    row = '%-4d %-9s' % (s, NAMES.get(s, '?'))
    for i in range(1, len(dumps)):
        a = dumps[i - 1].get(s, {})
        b = dumps[i].get(s, {})
        row += '  %+d/%+d' % (b.get('live', 0) - a.get('live', 0),
                              b.get('bytes', 0) - a.get('bytes', 0))
    print(row)
ex = dumps[-1]['_hdr'][2]
if ex:
    print()
    print('WARNING: kmtrack block pool exhausted %d times — some slab pages '
          'went untracked and their objects report under site 0 (unknown). '
          'The shortfall is REPORTED, never silently mis-attributed.' % ex)
PY
cat "$KMSUM"

# PER-SITE PAGE deltas per terminal cycle — reported, not asserted, for the
# same reason as kmtrack: this gate's assertion is about the COW arms, and a
# page-site threshold invented here would be a number with no measurement
# behind it. What this table is FOR is the next question: if every COW arm is
# clean, the slope is on one of these sites.
PGSUM="$OUT_DIR/pgsite.txt"
python3 - "$LOG" > "$PGSUM" 2>&1 <<'PY'
import re, sys
log = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace').replace('\r', '')
NAMES = {0: 'unknown', 1: 'vma_large', 2: 'vma_fixed', 3: 'vma_prefault',
         4: 'vma_file', 5: 'vma_huge', 6: 'vma_anon', 7: 'vma_swapin',
         8: 'vma_grow', 9: 'pgtable', 10: 'fork_copy', 11: 'cow_resolve',
         12: 'kstack', 13: 'ustack', 14: 'pml4', 15: 'selftest', 16: 'slab',
         17: 'uaccess', 18: 'tmpfs', 19: 'wsys', 20: 'execve'}
dumps, cur = [], None
for ln in log.splitlines():
    m = re.search(r'\[trk\] mode=(\d+) frames=(\d+)', ln)
    if m:
        if cur is not None:
            dumps.append(cur)
        cur = {}
        continue
    if cur is None:
        continue
    m = re.search(r'\[trk\] site=(\d+) live=(\d+) allocs=(\d+)', ln)
    if m:
        cur[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
if cur is not None:
    dumps.append(cur)
print('=== page sites, live-frame delta per terminal open/close ===')
if len(dumps) < 2:
    print('only %d page dumps parsed' % len(dumps))
    sys.exit(0)
sites = sorted(set(k for d in dumps for k in d))
print('%-4s %-13s %10s   %s' % ('site', 'name', 'live@last',
                                '  '.join('d%d' % (i + 1) for i in range(1, len(dumps)))))
rows = []
for s in sites:
    deltas = [dumps[i].get(s, (0, 0))[0] - dumps[i - 1].get(s, (0, 0))[0]
              for i in range(1, len(dumps))]
    rows.append((sum(deltas[len(deltas) // 2:]), s, deltas))
for _, s, deltas in sorted(rows, reverse=True):
    print('%-4d %-13s %10d   %s'
          % (s, NAMES.get(s, '?'), dumps[-1].get(s, (0, 0))[0],
             '  '.join('%+d' % d for d in deltas)))
PY
cat "$PGSUM"

if grep -aF -q "[trap-diag] vec=" "$LOG"; then
    echo "$TAG DIAG: CPU exception during the run"
    grep -aF "[trap-diag] vec=" "$LOG" | head -6 || true
    fail=1
fi
if grep -aE -q "PANIC|panic:|BUG:" "$LOG"; then
    echo "$TAG FAIL: kernel fault during the run"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "$TAG FAIL ($CYCLES_RUN cycles) — see $OUT_DIR" >&2
    exit 1
fi
# Deliberately NOT "born == died": that is not what was asserted, and a banner
# that overstates its own gate is how a green run stops meaning anything.
echo "$TAG PASS ($CYCLES_RUN cycles) — no COW share arm strands a frame under"
echo "$TAG   the terminal workload; artifacts in $OUT_DIR"
exit 0
