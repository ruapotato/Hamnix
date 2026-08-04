#!/usr/bin/env bash
# scripts/test_leak_hours_census.sh — THE HOURS-SCALE MEASUREMENT.
#
#
# This gate is not in ci_battery_manifest.txt because its whole assertion is
# that the two samples are HOURS apart — its minimum honest runtime is over an
# hour and its default is two, against a 50-minute shard cap. Registering it
# would either blow the battery or force GAP_S down to a value at which the
# gate reports INCONCLUSIVE by construction, which is a gate that exists to
# print "inconclusive" on every push. What IS registered is
# scripts/test_leak_hours_report_mutations.sh, the QEMU-free mutation gate that
# keeps this one's adjudicator (scripts/leak_hours_census_report.py) able to
# say no. Run this by hand, detached, when the hours-scale question is live.
#
# WHY THIS GATE EXISTS (leak pass 19)
# ===================================
# Eighteen passes closed the leak on counted quantities. Pass 18's own closing
# words state the residual honestly:
#
#     "these are minutes-long runs, not months. A leak of one frame per hour is
#      invisible at this timescale and would still cost 8 MiB a year. The
#      instrument to catch THAT is not a longer soak of the same kind — pass 15
#      established that a soak mean is not an estimator — it is this census run
#      TWICE, HOURS APART, on ONE boot, differencing the per-site live counts
#      with the plant discounted."
#
# This is that gate, and it answers pass 18's third question in the same boot:
# every previous gate measures apps that OPEN AND CLOSE, so nothing has ever
# measured the processes that never exit — hamUId, the panel, the compositor,
# the DE shell. Those are precisely the processes "months of uptime" is about,
# and a launch/close cycle instrument is blind to them by construction.
#
# THE SHAPE OF THE MEASUREMENT
# ============================
# ONE boot. Two identical sample batteries, HOURS apart, with NOTHING launched
# or closed in between — the guest simply runs, which is what a desktop does
# for months. Each battery takes, in this order:
#
#   1. `track dump`   per-site LIVE page counts        (BEFORE any plant, so no
#                                                       control frame is ever
#                                                       inside a counted site)
#   2. `track origin` per-arm born/died
#   3. `track org N`  the owner discriminator per arm
#   4. `cat /proc/tasks` + `cat /proc/<pid>/statm` for EVERY live task
#                     — the long-lived-process instrument
#   5. plant / mplant / census / unplant / unmplant
#   6. `kmtrack dump` kernel heap, reported
#
# and the verdict is the DIFFERENCE, per site, per arm, per surviving process,
# with the plant discounted.
#
# WHY DIFFERENCES AND NOT A SOAK MEAN
# ===================================
# Pass 15 established that two BYTE-IDENTICAL builds differ by 6.4 pg/cycle on
# a soak mean, so a before/after soak-mean pair cannot validate anything. Both
# samples here come from ONE boot of ONE build, so the build term cancels
# exactly and the difference is a difference in the machine's state, not in
# two estimates of it.
#
# WHY `born == died` IS NOT THE ASSERTION
# =======================================
# At hours scale on long-lived processes, EVERY owner outlives the measurement.
# An absolute balance is a permanent false red. The quantity is the INTER-SAMPLE
# net, and any non-zero net is adjudicated with the owner discriminator
# (owner-dead / owner-stray / owner-unrecorded), never on its sign.
#
# THE INSTRUMENT'S OWN CONTROLS (a green from a blind instrument is worse than
# a red — three passes caught a false green in their own tooling)
# ==============================================================
#   * BOTH census controls must be green in BOTH sweeps. A blind census and an
#     empty population print the same zero.
#   * The run predicate must report the planted control as UNACCOUNTED in both
#     sweeps. A predicate that explains everything away is over-claiming, and
#     the plant — mapped nowhere, therefore in no run — is its free positive
#     control.
#   * The plant is discounted BY PHYSICAL ADDRESS, and a sweep whose plant phys
#     was never printed is INCONCLUSIVE: a plant you cannot identify cannot be
#     discounted.
#   * A `TRUNCATED` site is INCONCLUSIVE, never clean.
#   * THE ELAPSED GAP IS ASSERTED. A gate called "hours" that ran for four
#     minutes is the purest false green available here, so the two samples'
#     host timestamps are differenced and a gap below MIN_GAP_S is
#     INCONCLUSIVE — the run did not measure the thing it is named for.
#   * No /dev/kvm => exit 125 INCONCLUSIVE, never 0.
#
# THE GROWTH BAR, AND WHERE THE NUMBER COMES FROM
# ===============================================
# Orphan-freedom is necessary and not sufficient. A resident set that grows
# forever kills months of uptime even though every frame is reachable from a
# live page table and no teardown fix could touch it. So the total live-page
# delta over an interval in which NOTHING was launched or closed is itself an
# assertion:
#
#     GROWTH_FAIL_PAGES (default 256 pages = 1 MiB) over the whole gap.
#
# 1 MiB per two idle hours is ~12 MiB/day and ~4.3 GiB/year. That is fatal to
# the user's bar by inspection, which is why it is a defensible threshold and
# not a tuned one; it is deliberately far LOOSER than "zero" so that a bounded
# ramp still settling (pass 17's lesson: a ramp is not a slope) does not fail
# the gate, and any FAIL it produces is unarguable.
#
# WHY THERE IS A SETTLE PERIOD BEFORE SAMPLE A
# ===========================================
# The smoke run of this gate took sample A about a minute after the DE handoff
# and made the flaw obvious: a machine that has just booted is still ramping —
# lazily faulted pages, first paints, page cache filling — so a two-hour delta
# measured from minute one is dominated by the BOOT RAMP and not by steady
# state. Pass 17's central lesson is that a ramp to a bounded high-water looks
# exactly like a slope, and this gate would have manufactured one. SETTLE_S
# (default 15 min) runs before the tracker is even armed, so both samples are
# taken from the same regime and their difference is a difference in steady
# state.
#
# N SAMPLES, NOT TWO (leak pass 21)
# =================================
# SAMPLES=N takes N batteries on ONE boot, each separated by GAP_S. N=2 (the
# default) is byte-for-byte the pass-19/20 shape, so the registered mutation
# gate and every captured two-sample log keep their exact meaning.
#
# Why N>2 is not a luxury: pass 20 ran this gate for 8.02 hours, PASSed, and
# its own verdict says the result cannot answer the question it was run for.
# Site 6 (vma_anon) went 1 -> 38 pages. A warm-up that finished in the first
# twenty minutes and a linear leak of 4.6 pages/hour produce THE SAME TWO
# NUMBERS. A delta has no shape; three points do. The adjudicator differences
# consecutive pairs and classifies the curve — see the TREND ARM in
# scripts/leak_hours_census_report.py — so the run must produce a curve.
#
# Env: INSTALLER_IMG, OVMF_FD, BOOT_WAIT, OUT_DIR, SETTLE_S, GAP_S, MIN_GAP_S,
#      GROWTH_FAIL_PAGES, ARMS, SAMPLES, TREND_MIN_PAGES, SETTLE_FRAC.


set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[hourscens]"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
# The gap between the two sample batteries. TWO HOURS by default: pass 18's
# residual is "one frame per hour", and one hour of separation gives that a
# single count of signal, which is not a measurement. Two gives two.
GAP_S="${GAP_S:-7200}"
# Let the machine reach steady state BEFORE arming anything. See the header:
# a delta measured from minute one of a boot is a ramp, not a slope.
SETTLE_S="${SETTLE_S:-900}"
# Below this, the run has not measured hours and says so. See the controls
# section above.
MIN_GAP_S="${MIN_GAP_S:-3600}"
GROWTH_FAIL_PAGES="${GROWTH_FAIL_PAGES:-256}"
# How many sample batteries to take on this one boot. 2 = the pass-19/20 shape,
# exactly. >= 3 engages the adjudicator's TREND arm, which is the only thing in
# this campaign that can tell a settle from a slow linear leak.
SAMPLES="${SAMPLES:-2}"
# The resolution floor for the trend arm, in pages of whole-span growth. A span
# of T hours cannot resolve a rate below roughly one page per T hours, so below
# this the shape of the curve is noise and the adjudicator says so instead of
# guessing. NOT a tolerance — see the adjudicator's header.
TREND_MIN_PAGES="${TREND_MIN_PAGES:-16}"
# A terminal rate under this fraction of its earlier peak counts as decayed.
SETTLE_FRAC="${SETTLE_FRAC:-0.5}"
case "$SAMPLES" in
    ''|*[!0-9]*) echo "$TAG SAMPLES must be an integer, got '$SAMPLES'" >&2; exit 2 ;;
esac
[ "$SAMPLES" -ge 2 ] || { echo "$TAG SAMPLES must be >= 2" >&2; exit 2; }
SAMPLE_LABELS=$(echo ABCDEFGH | cut -c1-"$SAMPLES")
[ "${#SAMPLE_LABELS}" -eq "$SAMPLES" ] || {
    echo "$TAG SAMPLES=$SAMPLES exceeds the A..H label space" >&2; exit 2; }
read -r -a ARM_LIST <<< "${ARMS:-1 2 5 19 21 23 24}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/leak_hours_census/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

[ -e /dev/kvm ] || { echo "$TAG INCONCLUSIVE: /dev/kvm absent — nothing asserted" >&2; exit 125; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "$TAG SKIP-RUNTIME: no OVMF" >&2; exit 0; }

# shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
installer_img_or_verdict "$INSTALLER_IMG" "$TAG"
[ -f "$INSTALLER_IMG" ] || {
    echo "$TAG RESULT: INCONCLUSIVE ($INSTALLER_IMG absent — nothing booted)" >&2
    exit 125; }
IMG_SZ=$(stat -c %s "$INSTALLER_IMG" 2>/dev/null || echo 0)
if [ "$IMG_SZ" -lt 33554432 ]; then
    echo "$TAG SKIP-RUNTIME: $INSTALLER_IMG is only ${IMG_SZ}B — a build is" >&2
    echo "$TAG   probably still writing it." >&2
    exit 0
fi
echo "$TAG image age: $(installer_img_age_str "$INSTALLER_IMG")"

mkdir -p "$OUT_DIR"
echo "$TAG output dir: $OUT_DIR"
echo "$TAG settle: ${SETTLE_S}s, gap: ${GAP_S}s (min accepted ${MIN_GAP_S}s), arms: ${ARM_LIST[*]}"
echo "$TAG samples: $SAMPLES ($SAMPLE_LABELS), total span $(( GAP_S * (SAMPLES - 1) ))s"
if [ "$SAMPLES" -ge 3 ]; then
    echo "$TAG   N>=3: the adjudicator's TREND arm engages — consecutive rates,"
    echo "$TAG   not just the endpoint delta. A settle flattens; a leak does not."
else
    echo "$TAG   N=2: endpoint delta only. This CANNOT tell a settle from a slow"
    echo "$TAG   linear leak (leak pass 20's own closing verdict)."
fi

OVMF_RW=$(mktemp --tmpdir hamnix-hc.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-hc.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
STAMPS="$OUT_DIR/sample_stamps.txt"
MON=$(mktemp --tmpdir -u hamnix-hc-mon.XXXXXX)
FIFO=$(mktemp -u --tmpdir hamnix-hc.XXXXXX).in
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"
: > "$STAMPS"

QEMU_PID=""
cleanup() {
    # Kill ONLY our own QEMU, by recorded pid. Never a pattern kill — a
    # sibling gate's boot is not ours to end.
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$FIFO"
}
trap cleanup EXIT
exec 4<>"$FIFO"; exec 3>"$FIFO"

wait_for() {
    local pat="$1" deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

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
printf 'echo MARK_HC_READY\n' >&3
sleep 1
wait_for MARK_HC_READY 12 || { printf 'echo MARK_HC_READY\n' >&3; sleep 2; }

fail=0
inconclusive=0
say_fail() { echo "$TAG FAIL $*" >&2; fail=1; }

send() {
    local cmd="$1" mark="$2" to="${3:-30}"
    printf '%s; echo %s\n' "$cmd" "$mark" >&3
    local d=$(( SECONDS + to ))
    while [ "$SECONDS" -lt "$d" ]; do
        grep -aq "^${mark}" "$LOG" && { sleep 1; return 0; }
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

# take_sample <A|B> — one whole battery, fenced so the parser can split the
# stream without guessing.
take_sample() {
    local s="$1"
    echo "$TAG === sample $s ==="
    echo "$s $(date +%s)" >> "$STAMPS"
    printf 'echo HC_SAMPLE %s\n' "$s" >&3
    sleep 1
    # (1) per-site live counts, taken BEFORE any plant exists, so the control
    # frame can never sit inside a counted site. Pass 18's first run failed on
    # exactly that contamination in the growth rule.
    send "echo track dump > /proc/meminfo"   "HC_TRK_$s"  60 \
        || say_fail "sample $s: track dump timed out"
    send "echo track origin > /proc/meminfo" "HC_ORG_$s"  60 \
        || say_fail "sample $s: track origin timed out"
    local arm
    for arm in "${ARM_LIST[@]}"; do
        printf 'echo HC_ARMFENCE %s %s\n' "$s" "$arm" >&3
        sleep 1
        send "echo track org $arm > /proc/meminfo" "HC_ORGL_${s}_$arm" 120 \
            || say_fail "sample $s: track org $arm timed out"
    done
    # (4) THE LONG-LIVED-PROCESS INSTRUMENT. /proc/tasks names every live task;
    # /proc/<pid>/statm gives its resident page count. Differencing these two
    # samples over an interval in which nothing was launched is the first
    # measurement in this campaign of a process that never exits.
    send "cat /proc/tasks" "HC_TASKS_$s" 60 \
        || say_fail "sample $s: /proc/tasks read timed out"
    sleep 1
    # /proc/tasks lines are "<pid>\t<state>\t<comm>\t<utime>\t<stime>". Take
    # every numeric first field seen since the sample fence.
    local pids
    pids=$(awk -v s="HC_SAMPLE $s" '
        index($0, s) == 1 { on = 1; next }
        on && /^[0-9]+\t/ { print $1 }
    ' "$LOG" | sort -n | uniq)
    local p
    for p in $pids; do
        printf 'echo HC_STATM %s %s; cat /proc/%s/statm; echo HC_STATMEND_%s_%s\n' \
            "$s" "$p" "$p" "$s" "$p" >&3
        local d=$(( SECONDS + 20 ))
        while [ "$SECONDS" -lt "$d" ]; do
            grep -aq "^HC_STATMEND_${s}_${p}\$" "$LOG" && break
            kill -0 "$QEMU_PID" 2>/dev/null || break
            sleep 1
        done
    done
    # (5) census, both controls outstanding in the SAME sweep.
    send "echo track plant > /proc/meminfo"    "HC_PLANT_$s"   60 \
        || say_fail "sample $s: track plant timed out"
    send "echo track mplant > /proc/meminfo"   "HC_MPLANT_$s"  60 \
        || say_fail "sample $s: track mplant timed out"
    send "echo track census > /proc/meminfo"   "HC_CENSUS_$s" 300 \
        || say_fail "sample $s: track census timed out"
    send "echo track unplant > /proc/meminfo"  "HC_UNPL_$s"    60 || true
    send "echo track unmplant > /proc/meminfo" "HC_UNMP_$s"    60 || true
    send "echo kmtrack dump > /proc/meminfo"   "HC_KM_$s"      90 || true
    printf 'echo HC_SAMPLE_END %s\n' "$s" >&3
    sleep 2
}

echo "$TAG settling ${SETTLE_S}s before arming — a delta measured from"
echo "$TAG   minute one of a boot is the boot ramp, not a steady-state slope"
sleep "$SETTLE_S"
printf 'echo HC_SETTLED\n' >&3
sleep 2
grep -aq "^HC_SETTLED\$" "$LOG" || echo "$TAG WARNING: no echo after the settle period — guest shell may be wedged" >&2

send "echo track full > /proc/meminfo" HC_ARM_PAGE 60 || say_fail "track full timed out"
send "echo kmtrack on > /proc/meminfo" HC_ARM_KM   60 || say_fail "kmtrack on timed out"

# ---------------------------------------------------------------------------
# THE GAP. By default nothing is launched, nothing is closed. The DE's own
# long-lived processes keep running — the panel repaints its clock, the
# compositor services damage — which is exactly the workload "months of uptime"
# means and exactly the one every previous gate's open/close shape cannot see.
#
# A heartbeat every 5 minutes so a guest that died at minute 12 is discovered
# then rather than at hour 2, and so the serial path is proven alive at the
# moment sample B is taken.
#
# GAP_LOAD=1 — A LOADED GAP, AND WHY IT DOES NOT COST ATTRIBUTION
# ==============================================================
# Pass 19 chose a quiet gap deliberately: a quiet interval is one where a
# non-zero delta has an unambiguous owner. The cost is that an idle gap
# measures almost nothing — a four-hour soak that idled for four hours has
# exercised the compositor's repaint path and little else, and the campaign's
# whole open question is whether work leaves residue.
#
# The resolution is that attribution is a property of the SAMPLE POINTS, not of
# the gap. Both samples are still taken with the machine quiet and — this is
# the load-bearing part — with the SAME LIVE TASK SET, because every app opened
# during the gap is closed during the gap and its exit is confirmed before the
# next one opens. GAP_LOAD_QUIESCE_S of strict idle then runs before sample B
# so nothing is mid-teardown when the census walks.
#
# Under that shape the adjudicator's rules all keep their meaning, and one of
# them gets STRONGER:
#
#   * the growth bar is only condemned on an UNCHANGED task set
#     (leak_hours_census_report.py). A load phase that fully closes leaves the
#     set unchanged, so the bar still bites. If an app FAILS to exit, the set
#     differs, the report sees a `born` process and downgrades to "reported,
#     not condemned" — the honest outcome, reached automatically.
#   * `owner-dead` STOPS BEING VACUOUS. In an idle gap no owner ever dies, so
#     owner-dead is 0 by construction and the discriminator that separates a
#     leak from mere residency never fires. In a loaded gap every app that ran
#     is a dead owner, so a survivor frame still tagged to one is a LEAK the
#     adjudicator will actually convict on. This is the arm rule at line
#     "arm %d: LEAK" finally having a population to rule over.
#
# So: quiet at the endpoints, loaded in between, and every launch matched by a
# confirmed exit. Survivors of a failed close are counted and reported, because
# a load phase that silently stopped launching is the "silent cap" failure this
# campaign is also hunting.
# ---------------------------------------------------------------------------
GAP_LOAD="${GAP_LOAD:-0}"
GAP_LOAD_QUIESCE_S="${GAP_LOAD_QUIESCE_S:-600}"
GAP_LOAD_PER_CYCLE="${GAP_LOAD_PER_CYCLE:-4}"
read -r -a GAP_APP_POOL <<< "${GAP_LOAD_APPS:-hamwrite hamsheet hamslides hamfmscene hammonscene hamcalcscene hamtermscene}"
gl_pool_i=0
gl_launched=0
gl_closed=0
gl_survivors=0
gl_cycles=0
gl_nowindow=0

mapped_count() { grep -ac '\[devwsys\] window .* mapped' "$LOG" 2>/dev/null || echo 0; }

# gap_load_cycle — open GAP_LOAD_PER_CYCLE apps, then close every one of them
# and CONFIRM the exit. Returns non-zero only if the guest died.
gap_load_cycle() {
    local n=0 app before line pid open_pids="" exit_base d
    gl_cycles=$(( gl_cycles + 1 ))
    while [ "$n" -lt "$GAP_LOAD_PER_CYCLE" ]; do
        app="${GAP_APP_POOL[$(( gl_pool_i % ${#GAP_APP_POOL[@]} ))]}"
        gl_pool_i=$(( gl_pool_i + 1 ))
        n=$(( n + 1 ))
        before=$(mapped_count)
        printf '/bin/%s &\n' "$app" >&3
        gl_launched=$(( gl_launched + 1 ))
        d=$(( SECONDS + 30 ))
        while [ "$SECONDS" -lt "$d" ]; do
            [ "$(mapped_count)" -gt "$before" ] && break
            kill -0 "$QEMU_PID" 2>/dev/null || return 1
            sleep 1
        done
        if [ "$(mapped_count)" -le "$before" ]; then
            # A launch that maps no window is exactly the silent-cap shape
            # (devwsys's per-pid table was a LIFETIME cap, not a concurrency
            # cap). Count it loudly; it is a finding, not noise.
            gl_nowindow=$(( gl_nowindow + 1 ))
            echo "$TAG   LOAD: cycle $gl_cycles: $app mapped NO window in 30s (launch #$gl_launched)" >&2
            continue
        fi
        line=$(grep -a '\[devwsys\] window .* mapped' "$LOG" | tail -1)
        pid=$(echo "$line" | sed -n 's/.*mapped pid=\([0-9]*\).*/\1/p')
        [ -n "$pid" ] && open_pids="$open_pids $pid"
        sleep 1
    done
    sleep 2
    for pid in $open_pids; do
        exit_base=$(grep -ac "task: pid $pid exited" "$LOG")
        printf '/bin/kill %s\n' "$pid" >&3
        d=$(( SECONDS + 20 ))
        while [ "$SECONDS" -lt "$d" ]; do
            [ "$(grep -ac "task: pid $pid exited" "$LOG")" -gt "$exit_base" ] && break
            kill -0 "$QEMU_PID" 2>/dev/null || return 1
            sleep 1
        done
        if [ "$(grep -ac "task: pid $pid exited" "$LOG")" -gt "$exit_base" ]; then
            gl_closed=$(( gl_closed + 1 ))
        else
            gl_survivors=$(( gl_survivors + 1 ))
            echo "$TAG   LOAD: pid $pid survived its terminate note — the task set at B will DIFFER from A" >&2
        fi
    done
    sleep 3
    return 0
}

hb=0
# run_gap <next-sample-label> — ONE inter-sample interval of GAP_S seconds.
# Factored out of the straight-line pass-19 body so that N-1 of them can run on
# one boot (leak pass 21). Nothing about the interval's behaviour changed.
run_gap() {
    local nextlab="$1" gap_end load_end left
    if [ "$GAP_LOAD" = "1" ]; then
        echo "$TAG LOADED gap: ${GAP_S}s total, launch/close cycles of ${GAP_LOAD_PER_CYCLE}"
        echo "$TAG   apps from: ${GAP_APP_POOL[*]}"
        echo "$TAG   with the last ${GAP_LOAD_QUIESCE_S}s strictly idle so both samples"
        echo "$TAG   are taken quiet and on the SAME live task set"
    else
        echo "$TAG idling ${GAP_S}s before sample $nextlab (nothing launched, nothing closed)"
    fi
    gap_end=$(( SECONDS + GAP_S ))
    load_end=$(( gap_end - GAP_LOAD_QUIESCE_S ))
    while [ "$SECONDS" -lt "$gap_end" ]; do
        if [ "$GAP_LOAD" = "1" ] && [ "$SECONDS" -lt "$load_end" ]; then
            # One load cycle, then heartbeat. The cycle is self-timing (it waits
            # on windows and exits), so it replaces the sleep rather than adding
            # to it.
            gap_load_cycle || { echo "$TAG guest died during a load cycle" >&2; return 1; }
        else
            # Sleep only as far as the deadline, never past it. A flat
            # `sleep 300` overshoots GAP_S by up to five minutes; the gap the
            # verdict uses is the MEASURED one from the timestamps either way,
            # so this is about the gate doing what its knob says, not about
            # honesty of the number.
            left=$(( gap_end - SECONDS ))
            [ "$left" -gt 300 ] && left=300
            [ "$left" -gt 0 ] && sleep "$left"
        fi
        hb=$(( hb + 1 ))
        printf 'echo HC_ALIVE %d\n' "$hb" >&3
        sleep 2
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            echo "$TAG guest died during the gap (heartbeat $hb)" >&2
            return 1
        fi
        if ! grep -aq "^HC_ALIVE $hb\$" "$LOG"; then
            echo "$TAG WARNING: heartbeat $hb produced no echo — guest shell may be wedged" >&2
        fi
        echo "$TAG   heartbeat $hb ($(( gap_end - SECONDS ))s to sample $nextlab)" \
             "${GAP_LOAD:+[load: ${gl_launched} launched, ${gl_closed} closed, ${gl_survivors} survivors, ${gl_nowindow} no-window]}"
    done
    return 0
}

# Sample A, then (gap, sample) for every remaining label. For SAMPLES=2 this is
# exactly `take_sample A; run_gap B; take_sample B`, i.e. the pass-19/20 body.
take_sample "${SAMPLE_LABELS:0:1}"
i=1
while [ "$i" -lt "$SAMPLES" ]; do
    lab="${SAMPLE_LABELS:$i:1}"
    run_gap "$lab" || break
    take_sample "$lab"
    i=$(( i + 1 ))
done

if [ "$GAP_LOAD" = "1" ]; then
    echo "$TAG LOAD PHASE TOTALS: cycles=$gl_cycles launched=$gl_launched closed=$gl_closed survivors=$gl_survivors no-window=$gl_nowindow"
    echo "$gl_cycles $gl_launched $gl_closed $gl_survivors $gl_nowindow" > "$OUT_DIR/gap_load_totals.txt"
    if [ "$gl_nowindow" -gt 0 ]; then
        say_fail "the gap's load phase had $gl_nowindow launch(es) map NO window — a launch path that stops working over hours is a silent cap, which is fatal to months of uptime whether or not a frame leaked"
    fi
    if [ "$gl_survivors" -gt 0 ]; then
        echo "$TAG WARNING: $gl_survivors app(s) survived their terminate note; the" >&2
        echo "$TAG   task set at the last sample differs from the first and the" >&2
        echo "$TAG   growth bar will self-downgrade" >&2
    fi
fi

kill "$QEMU_PID" 2>/dev/null
( sleep 5; kill -9 "$QEMU_PID" 2>/dev/null ) & WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null

SUMMARY="$OUT_DIR/summary.txt"
python3 "$PROJ_ROOT/scripts/leak_hours_census_report.py" \
    "$LOG" "$STAMPS" "$MIN_GAP_S" "$GROWTH_FAIL_PAGES" \
    "$SAMPLES" "$TREND_MIN_PAGES" "$SETTLE_FRAC" > "$SUMMARY" 2>&1
rc=$?
cat "$SUMMARY"

if grep -aF -q "[trap-diag] vec=" "$LOG"; then
    echo "$TAG DIAG: CPU exception during the run"
    grep -aF "[trap-diag] vec=" "$LOG" | head -6 || true
    fail=1
fi
if grep -aE -q "PANIC|panic:|BUG:" "$LOG"; then
    echo "$TAG FAIL: kernel fault during the run"
    fail=1
fi

if [ "$rc" -eq 125 ]; then inconclusive=1; elif [ "$rc" -ne 0 ]; then fail=1; fi

if [ "$fail" -ne 0 ]; then
    echo "$TAG FAIL — see $OUT_DIR" >&2
    exit 1
fi
if [ "$inconclusive" -ne 0 ]; then
    echo "$TAG INCONCLUSIVE — see $OUT_DIR" >&2
    exit 125
fi
echo "$TAG PASS — over the measured gap, with both census controls green in"
echo "$TAG   both sweeps, no site accumulated an unaccounted frame and the"
echo "$TAG   long-lived processes' resident sets did not grow past the bar."
echo "$TAG   Artifacts in $OUT_DIR"
exit 0
