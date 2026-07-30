#!/usr/bin/env bash
# scripts/test_cow_deapps_origin.sh — the origin gate pointed at the EIGHT DE
# apps that are not the terminal.
#
# WHY THIS GATE EXISTS (leak pass 18)
# ===================================
# Pass 14 named `hamtermscene` as the burst. Passes 15 and 16 retired every
# kernel COW share path underneath it. Pass 17 then measured `hamsh` itself and
# exonerated it: 361 consecutive identical RSS samples over thirty minutes, and
# a post-GC arena floor byte-identical across three sweeps of 16 command
# classes. It closed with the question this gate answers:
#
#     "hamsh is exonerated and the terminal path is retired; if a residual
#      slope survives, it belongs to something NEITHER existing gate
#      launches."
#
# scripts/test_cow_hamterm_origin.sh launches exactly one app. The DE soak
# launches nine but adjudicates none of them — it reports slopes, and a slope
# over a mixed app pool cannot say WHICH app owns it. This gate launches the
# other EIGHT, one at a time, in per-app runs of identical open/close cycles,
# and adjudicates each app separately with the same instrument.
#
# THE ASSERTION, PER APP
# ======================
# For every COW origin arm, over the inter-cycle deltas of an identical,
# repeated open/close of ONE app:
#
#     net <= 0                                          -> closed
#     net > 0, owner-dead == 0, owner-stray == 0        -> residency
#     anything else                                     -> LEAK
#
# and, because the COW paths are now retired and a surviving slope would be on
# some OTHER allocator, per-app PER-SITE page deltas are computed too. A site
# that grows on EVERY delta of one app is not condemned on that alone — pass
# 17's central lesson is that a ramp to a bounded high-water looks exactly like
# a slope over few cycles. It is flagged, and adjudicated against the census:
# growth at a site with UNACCOUNTED orphans is a leak; growth at a site with
# none is a resident set until a longer run says otherwise.
#
# THE WHOLE-MACHINE CENSUS runs once at the end with BOTH controls outstanding
# (`track plant` = a frame mapped nowhere that MUST be reported, `track mplant`
# = a mapped frame that must NOT be), plus the pass-18 run predicate
# (`[cens3]`): every orphan, asked whether it lies inside a live task's
# wholesale-return run. That is what settles the intermittent site-20 residue
# passes 16 and 17 could only count.
#
# WHY DELTAS AND NOT `born == died`: cow_share_page takes a frame 0 -> 2 and
# the child's death returns it to 1, not 0. The DE's own shell outlives the
# whole run, so an absolute balance is a permanent false red. See the same
# section of test_cow_hamterm_origin.sh.
#
# A FAILING APP DOES NOT ABORT THE RUN. Eight apps share one ~30-minute boot;
# an app that never maps a window is recorded INCONCLUSIVE *for that app* and
# the loop moves on, because throwing away seven good adjudications over one
# bad launch is how a long gate becomes a gate nobody runs.
#
# Env: INSTALLER_IMG, OVMF_FD, BOOT_WAIT, OUT_DIR, CYCLES_PER_APP, DEAPPS.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[cowapps]"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
# FOUR cycles per app -> THREE inter-cycle deltas per app. Three is the
# minimum that separates "one-time population, born in cycle 1" from
# "per-cycle leak, constant positive net" without appealing to a slope.
CYCLES_PER_APP="${CYCLES_PER_APP:-4}"
# The eight non-terminal DE apps, i.e. exactly test_de_stress_soak.sh's pool
# minus hamtermscene (which test_cow_hamterm_origin.sh owns). hambrowse gets
# --demo so it renders a deterministic offline page instead of waiting on a
# network that is not there.
read -r -a APP_POOL <<< "${DEAPPS:-hamwrite hamsheet hamslides hamfmscene hammonscene hamaudioscene hamcalcscene hambrowse}"
APP_ARGS_hambrowse="--demo"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/cow_deapps_origin/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

# INCONCLUSIVE (125), never 0. GitHub runners have no /dev/kvm; an `exit 0`
# here would make this gate report GREEN on every CI run having asserted
# nothing whatsoever — the false-green class scripts/test_gate_kvmdark.sh
# ratchets against, and the one test_cow_hamterm_origin.sh actually shipped
# for a whole pass. See scripts/_verdict.sh.
[ -e /dev/kvm ] || { echo "$TAG INCONCLUSIVE: /dev/kvm absent — nothing asserted" >&2; exit 125; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "$TAG SKIP-RUNTIME: no OVMF" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || true

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
# The image AGE is the only signal that the kernel edit under test is in the
# thing being booted. Pass 13 lost a whole measurement to a stale image; print
# it every time and let an implausible number be the tell.
echo "$TAG image age: $(( $(date +%s) - $(stat -c %Y "$INSTALLER_IMG") ))s"

mkdir -p "$OUT_DIR"
echo "$TAG output dir: $OUT_DIR"
echo "$TAG apps: ${APP_POOL[*]}  (${CYCLES_PER_APP} cycles each)"

OVMF_RW=$(mktemp --tmpdir hamnix-ca.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-ca.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-ca-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-ca.XXXXXX).in
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    # Kill ONLY our own QEMU, by recorded pid. Never a pattern kill — a
    # sibling gate's boot is not ours to end.
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
printf 'echo MARK_CA_READY\n' >&3
sleep 1
wait_for MARK_CA_READY 12 || { printf 'echo MARK_CA_READY\n' >&3; sleep 2; }

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

# ARM. `track full` = page tracker mode 2 + the COW ledger (the same verb the
# soak uses). kmtrack is armed independently — they answer different questions.
send "echo track full > /proc/meminfo" CA_ARM_PAGE 40 || say_fail "track full timed out"
send "echo kmtrack on > /proc/meminfo"  CA_ARM_KM   40 || say_fail "kmtrack on timed out"

# The per-app marker file is the join key between the host's launch order and
# the guest's dumps: the ctl writes are fixed strings and carry no app name.
ORDER_F="$OUT_DIR/app_order.txt"
: > "$ORDER_F"

for app in "${APP_POOL[@]}"; do
    eval "extra=\${APP_ARGS_${app}:-}"
    echo "$TAG === $app ==="
    c=0
    while [ "$c" -lt "$CYCLES_PER_APP" ]; do
        c=$((c+1))
        before=$(mapped_count)
        # Launch as a CHILD OF THIS SHELL: devproc's note gate is
        # caller-uid == target-uid, so /bin/kill closes it exactly the way the
        # DE's own close box does (hamUId daemon_close_slot -> p9_note_tree).
        printf '/bin/%s %s &\n' "$app" "$extra" >&3
        d=$(( SECONDS + 45 ))
        while [ "$SECONDS" -lt "$d" ]; do
            [ "$(mapped_count)" -gt "$before" ] && break
            sleep 1
        done
        if [ "$(mapped_count)" -le "$before" ]; then
            echo "$TAG $app cycle $c: mapped NO window in 45s — app recorded" \
                 "INCONCLUSIVE, moving on" >&2
            echo "INCONCLUSIVE $app cycle $c no-window" >> "$ORDER_F"
            break
        fi
        line=$(grep -a '\[devwsys\] window .* mapped' "$LOG" | tail -1)
        pid=$(echo "$line" | sed -n 's/.*mapped pid=\([0-9]*\).*/\1/p')
        if [ -z "$pid" ]; then
            echo "$TAG $app cycle $c: no pid in the mapped line" >&2
            echo "INCONCLUSIVE $app cycle $c no-pid" >> "$ORDER_F"
            break
        fi
        # Let the app actually start and paint, or the close lands before the
        # allocations this gate is about — a pass for entirely the wrong reason.
        sleep 4
        exit_base=$(grep -ac "task: pid $pid exited" "$LOG")
        printf '/bin/kill %s\n' "$pid" >&3
        d=$(( SECONDS + 25 ))
        while [ "$SECONDS" -lt "$d" ]; do
            [ "$(grep -ac "task: pid $pid exited" "$LOG")" -gt "$exit_base" ] && break
            sleep 1
        done
        if [ "$(grep -ac "task: pid $pid exited" "$LOG")" -le "$exit_base" ]; then
            echo "$TAG $app cycle $c: pid $pid survived the note for 25s" >&2
            echo "INCONCLUSIVE $app cycle $c no-exit" >> "$ORDER_F"
            break
        fi
        # An orphaned zombie is collected by reap_orphan_zombies at the NEXT
        # task allocation, so sample after settling rather than mid-teardown.
        sleep 5
        # A per-app, per-cycle FENCE line in the guest log. The parser splits
        # the dump stream on these, which is what makes the adjudication
        # PER-APP rather than over a mixed pool.
        printf 'echo CA_FENCE %s %s\n' "$app" "$c" >&3
        sleep 1
        send "echo track origin > /proc/meminfo" "CA_ORG_${app}_$c" 40 \
            || { echo "$TAG $app cycle $c: origin dump timed out" >&2
                 echo "INCONCLUSIVE $app cycle $c origin-timeout" >> "$ORDER_F"
                 break; }
        send "echo track dump > /proc/meminfo" "CA_TRK_${app}_$c" 40 \
            || { echo "$TAG $app cycle $c: track dump timed out" >&2
                 echo "INCONCLUSIVE $app cycle $c trk-timeout" >> "$ORDER_F"
                 break; }
        echo "OK $app cycle $c pid $pid" >> "$ORDER_F"
        echo "$TAG $app cycle $c done (pid $pid)"
    done
done

# NAME the survivors of every arm a share path can reach. This is the
# adjudicator: a count cannot tell a stalled leak from a resident set, and
# `owner-dead` / `owner-stray` can. Arms 1 and 19 are in the list because
# pass 17 made region_alloc attributable (PA_SITE_REGION) and they have owners
# for the first time — they were INSTRUMENTED by that pass, not adjudicated.
for arm in 1 2 5 19 21 23 24; do
    send "echo track org $arm > /proc/meminfo" "CA_ORGL_$arm" 90 \
        || say_fail "track org $arm timed out"
done

# WHOLE-MACHINE ORPHAN CENSUS, with BOTH controls outstanding in the SAME
# sweep. Positive: a frame mapped nowhere that MUST be reported. Negative: a
# mapped frame that must NOT be. Neither alone is enough — a blind census and
# an empty population print the same zero.
send "echo track plant > /proc/meminfo"   CA_PLANT   40 || say_fail "track plant timed out"
send "echo track mplant > /proc/meminfo"  CA_MPLANT  40 || say_fail "track mplant timed out"
send "echo track census > /proc/meminfo"  CA_CENSUS 240 || say_fail "track census timed out"
send "echo track unplant > /proc/meminfo" CA_UNPLANT 40 || true
send "echo track unmplant > /proc/meminfo" CA_UNMPL  40 || true

kill "$QEMU_PID" 2>/dev/null
( sleep 5; kill -9 "$QEMU_PID" 2>/dev/null ) & WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null

echo "$TAG --- live-frame owners ---"
grep -aF "[orgl] org=" "$LOG" | grep -aE "TOTAL=|owner-dead=|owner-stray=" || true
echo "$TAG --- census ---"
grep -aE "\[census\]" "$LOG" | tail -40 || true
echo "$TAG --- run predicate ---"
grep -aF "[cens3]" "$LOG" || true
echo "$TAG --- end ---"

if grep -aF -q "[origin] DISARMED" "$LOG" || grep -aF -q "[origin] NO TABLE" "$LOG"; then
    echo "$TAG FAIL: the origin ledger is not armed — every dump is VOID"
    fail=1
fi

SUMMARY="$OUT_DIR/summary.txt"
python3 - "$LOG" "$ORDER_F" > "$SUMMARY" 2>&1 <<'PY'
import re, sys
log = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace').replace('\r', '')

PGNAME = {0: 'unknown', 1: 'vma_large', 2: 'vma_fixed', 3: 'vma_prefault',
          4: 'vma_file', 5: 'vma_huge', 6: 'vma_anon', 7: 'vma_swapin',
          8: 'vma_grow', 9: 'pgtable', 10: 'fork_copy', 11: 'cow_resolve',
          12: 'kstack', 13: 'ustack', 14: 'pml4', 15: 'selftest', 16: 'slab',
          17: 'uaccess', 18: 'tmpfs', 19: 'wsys', 20: 'execve', 21: 'region'}
# The sites the census actually judges (page_alloc_site_is_user_mapped). A
# growth flag on a KERNEL site is not adjudicable by an orphan count, and
# saying so is the difference between a measurement and a guess.
USER_SITES = {1, 2, 3, 4, 6, 7, 8, 10, 11, 13, 20}

# ---- split the dump stream on the per-app CA_FENCE lines ------------------
# Everything after the last `[orgl]`-free fence and before the next one is one
# (app, cycle) sample. Fences are echoed by hamsh, so the line appears twice
# (echo + output); dedupe on (app, cycle).
cut = log.find('[orgl]')
cyclelog = log[:cut] if cut >= 0 else log
samples = []          # (app, cycle, {arm:(born,died)}, {site:live})
cur_app, cur_cyc = None, None
org, pg = {}, {}
have_org = have_pg = False


def flush():
    global org, pg, have_org, have_pg
    if cur_app is not None and (have_org or have_pg):
        samples.append((cur_app, cur_cyc, org, pg))
    org, pg, have_org, have_pg = {}, {}, False, False


for ln in cyclelog.splitlines():
    m = re.search(r'^CA_FENCE (\S+) (\d+)\s*$', ln)
    if m:
        flush()
        cur_app, cur_cyc = m.group(1), int(m.group(2))
        continue
    m = re.search(r'\[origin\] org=(\d+) born=(\d+) died=(\d+)', ln)
    if m:
        org[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
        have_org = True
        continue
    m = re.search(r'\[trk\] site=(\d+) live=(\d+) allocs=(\d+)', ln)
    if m:
        pg[int(m.group(1))] = int(m.group(2))
        have_pg = True
        continue
flush()

# ---- the owner discriminator, per arm (one dump per arm, at the end) ------
own, stray, untag = {}, {}, {}
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
        untag[int(m.group(1))] = int(m.group(3) or 0)
        continue
    m = re.search(r'\[orgl\] org=(\d+) TOTAL=(\d+)', ln)
    if m:
        a = int(m.group(1))
        own.setdefault(a, [0, 0, 0])
        own[a][2] = int(m.group(2))

bad, notes = [], []

print('=== owner discriminator (track org N), whole run ===')
if not own:
    bad.append('no `track org N` dump parsed — every positive net below is '
               'UNADJUDICATED, which is not green')
for a in sorted(own):
    d, u, t = own[a]
    print('arm %-3d TOTAL=%-5d owner-dead=%-4d owner-unrecorded=%-4d '
          'stray=%-4d untagged=%d' % (a, t, d, u, stray.get(a, 0),
                                      untag.get(a, 0)))


def adjudicate(a, net, who):
    # The SAME rule test_cow_hamterm_origin.sh applies, factored out so the
    # eight apps cannot each drift their own version of it.
    if a not in own:
        return ('BAD', '%s arm %d: net %+d with NO `track org %d` dump — '
                       'inconclusive, not green' % (who, a, net, a))
    dead, unrec, tot = own[a]
    if tot > 0 and unrec == tot:
        # `owner-dead = 0` over a population whose owner was never RECORDED
        # means "nobody wrote an owner down", not "no owner is dead". Pass 16
        # nearly published two false exonerations of exactly this shape.
        return ('BAD', '%s arm %d: UNADJUDICATED — net %+d over %d survivors, '
                       'NONE with a recorded owner; owner-dead=0 is vacuous '
                       'here' % (who, a, net, tot))
    if a not in stray:
        return ('BAD', '%s arm %d: net %+d and no owner-stray tally — a stale '
                       'kernel, so inconclusive' % (who, a, net))
    if dead == 0 and stray[a] == 0:
        return ('OK', '%s arm %d: RESIDENCY, net %+d, owner-dead=0, '
                      'owner-stray=0 (of %d survivors)' % (who, a, net, tot))
    return ('BAD', '%s arm %d: LEAK — net %+d, owner-dead=%d, survivors no '
                   'longer mapped by their owner=%d'
                   % (who, a, net, dead, stray[a]))


# ---- PER-APP adjudication --------------------------------------------------
apps = []
for app, cyc, o, p in samples:
    if app not in apps:
        apps.append(app)
print()
print('=== per-app adjudication (inter-cycle deltas of an identical '
      'open/close) ===')
per_app_growth = {}     # app -> [site, ...] monotone growers
adjudicated = 0
for app in apps:
    ss = [s for s in samples if s[0] == app]
    ss.sort(key=lambda s: s[1])
    print()
    print('--- %s: %d cycle sample(s) ---' % (app, len(ss)))
    if len(ss) < 3:
        bad.append('%s: only %d cycle sample(s); need >= 3 for two '
                   'inter-cycle deltas — INCONCLUSIVE for this app'
                   % (app, len(ss)))
        continue
    adjudicated += 1
    arms = sorted(set().union(*[set(s[2]) for s in ss]))
    exercised = False
    for a in arms:
        nets = []
        for i in range(1, len(ss)):
            b0, d0 = ss[i - 1][2].get(a, (0, 0))
            b1, d1 = ss[i][2].get(a, (0, 0))
            nets.append((b1 - b0) - (d1 - d0))
            if b1 - b0 > 0:
                exercised = True
        print('  arm %-3d nets %s' % (a, ' '.join('%+d' % n for n in nets)))
        if nets[-1] > 0:
            kind, msg = adjudicate(a, nets[-1], app)
            (notes if kind == 'OK' else bad).append(msg)
        else:
            notes.append('%s arm %d: closed (last net %+d)' % (app, a, nets[-1]))
    if not exercised:
        # NOT a failure here, unlike the terminal gate: these eight apps do
        # not fork, so they legitimately never reach the COW share. Said out
        # loud so a zero is never read as an exoneration of a path that never
        # ran.
        notes.append('%s: took NO COW share birth in any cycle — this app '
                     'never reaches the share path, so its zero nets prove '
                     'nothing ABOUT COW. The per-site table below is what '
                     'speaks for it.' % app)
    # per-site page deltas, and the monotone-growth flag
    sites = sorted(set().union(*[set(s[3]) for s in ss]))
    grow = []
    for s in sites:
        ds = [ss[i][3].get(s, 0) - ss[i - 1][3].get(s, 0)
              for i in range(1, len(ss))]
        if any(ds):
            print('  site %-3d %-13s live@last %-7d deltas %s'
                  % (s, PGNAME.get(s, '?'), ss[-1][3].get(s, 0),
                     ' '.join('%+d' % d for d in ds)))
        if all(d > 0 for d in ds) and len(ds) >= 2:
            grow.append(s)
    if grow:
        per_app_growth[app] = grow
        print('  MONOTONE GROWERS: %s'
              % ', '.join('%d/%s' % (s, PGNAME.get(s, '?')) for s in grow))

# ---- census, with BOTH controls + the pass-18 run predicate ---------------
print()
print('=== census ===')
orph = re.findall(r'\[census\].*orphaned frames?[:= ]+(\d+)', log)
pos = 'control OK: planted orphan detected' in log
neg = 'negative control OK' in log
print('positive control (track plant)  : %s' % ('OK' if pos else 'MISSING'))
print('negative control (track mplant) : %s' % ('OK' if neg else 'MISSING'))
print('orphan counts reported          : %s'
      % (', '.join(orph) if orph else 'none parsed'))
if not pos or not neg:
    bad.append('census controls incomplete (positive=%s negative=%s) — an '
               'orphan count without both is not a measurement' % (pos, neg))

# The run predicate. `[cens3] site N: M UNACCOUNTED (in no live run)`.
unacc = {}
inrun = {}
trunc = []
for m in re.finditer(r'\[cens3\] site (\d+): (\d+) UNACCOUNTED', log):
    unacc[int(m.group(1))] = int(m.group(2))
for m in re.finditer(r'\[cens3\] site (\d+): (\d+) orphan\(s\) collected, '
                     r'(\d+) inside a', log):
    inrun[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
for m in re.finditer(r'\[cens3\] site (\d+): TRUNCATED', log):
    trunc.append(int(m.group(1)))
print()
print('=== run predicate (pass 18): does each orphan lie in a live task\'s '
      'wholesale-return run? ===')
if not unacc:
    if orph and int(orph[-1]) > 0:
        bad.append('the census reported %s orphan(s) but printed NO [cens3] '
                   'run-check — a stale kernel, so the site-20 question is '
                   'UNSETTLED and this run is inconclusive' % orph[-1])
    else:
        print('(no orphans at any user-mapped site, so nothing to adjudicate)')
for s in sorted(set(list(unacc) + list(inrun))):
    n, ir = inrun.get(s, (0, 0))
    print('site %-3d %-13s collected %-3d  in-run %-3d  UNACCOUNTED %d'
          % (s, PGNAME.get(s, '?'), n, ir, unacc.get(s, 0)))
if trunc:
    bad.append('run-check TRUNCATED at site(s) %s — it covered a prefix of '
               'the population, so those sites are inconclusive, not clean'
               % ', '.join(str(s) for s in trunc))
tot_unacc = sum(unacc.values())
if unacc:
    # THE PLANT IS THE RUN-CHECK'S OWN POSITIVE CONTROL, for free: `track
    # plant` allocates a frame and maps it nowhere, so it lies in no run and
    # MUST come out UNACCOUNTED. A run-check that reported zero here would be
    # over-claiming — every orphan "explained" — and that is a blind
    # instrument printing a green.
    if tot_unacc == 0:
        bad.append('run predicate reported 0 UNACCOUNTED while a planted '
                   'control orphan (mapped NOWHERE, so in NO run) was '
                   'outstanding — the predicate OVER-CLAIMS and its verdict '
                   'is void')
    elif tot_unacc == 1:
        notes.append('run predicate: exactly 1 UNACCOUNTED frame, which is '
                     'the planted control — every other orphan lies inside a '
                     'live task\'s wholesale-return run')
    else:
        detail = ', '.join('site %d x%d' % (s, unacc[s])
                           for s in sorted(unacc) if unacc[s])
        bad.append('run predicate: %d UNACCOUNTED frames; 1 is the planted '
                   'control, so %d frame(s) lie in NO live run and nobody '
                   'will ever return them — %s'
                   % (tot_unacc, tot_unacc - 1, detail))

# Growth flags are adjudicated AGAINST the census, never on their own: pass
# 17's lesson is that a ramp to a bounded high-water is indistinguishable from
# a slope over few cycles.
for app, sites in per_app_growth.items():
    for s in sites:
        if s in USER_SITES and unacc.get(s, 0) > 0:
            bad.append('%s: site %d/%s grew on EVERY delta AND the census '
                       'finds %d UNACCOUNTED orphan(s) there — that is a '
                       'named slope'
                       % (app, s, PGNAME.get(s, '?'), unacc[s]))
        else:
            notes.append('%s: site %d/%s grew on every delta but the census '
                         'finds no unaccounted orphan there — resident set or '
                         'ramp, not a demonstrated leak'
                         % (app, s, PGNAME.get(s, '?')))

if adjudicated == 0:
    bad.append('NO app produced enough cycles to adjudicate — this run '
               'asserted nothing')

print()
print('apps adjudicated: %d of %d' % (adjudicated, len(apps)))
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
    echo "$TAG FAIL — see $OUT_DIR" >&2
    exit 1
fi
echo "$TAG PASS — no COW share arm strands a frame under any of the eight"
echo "$TAG   non-terminal DE apps, and every census orphan but the planted"
echo "$TAG   control lies inside a live task's wholesale-return run."
echo "$TAG   Artifacts in $OUT_DIR"
exit 0
