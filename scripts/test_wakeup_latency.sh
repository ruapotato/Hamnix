#!/usr/bin/env bash
# scripts/test_wakeup_latency.sh
#
# LATENCY GATE: an event must reach the task that has to RESPOND to it, on
# time, while other processes burn 100% CPU.
#
# USER REPORT: "things that take up a lot of CPU make the mouse studder or
# freze, it would be nice if the mouse would keep working even if a process is
# taking up 100% cpu."
#
# WHAT THIS GATE OWNS, AND WHAT IT DOES NOT
# -----------------------------------------
# scripts/test_pointer_latency_under_load.sh already owns the CURSOR GLYPH:
# the kernel composites it and pumps it from the timer tick, so its bound is
# an INTERRUPT-latency bound. This gate owns the other half — the half a user
# actually interacts with. A mouse packet has to reach the DE client blocked
# reading /dev/wsys/<wid>/pointer, and that client is an ordinary task that
# must be SCHEDULED before it can repaint. Clicks, drags, menu tracking and
# hover all live on that path, and a cursor that glides over a frozen
# application is still a frozen desktop.
#
# The asserted quantity is WAKE -> DISPATCH LATENCY: nanoseconds from "this
# task became runnable because something woke it" to "this task got the cpu".
# Nothing else in the suite measures it. Counting context switches cannot: the
# wake always happened promptly; the DISPATCH is what could be late.
#
# THE THREE WAKE SHAPES, AND WHY ALL THREE ARE HERE
# -------------------------------------------------
# They have completely different latency behaviour, and two earlier
# reproducers for this bug measured the wrong one and concluded "no problem".
#
#   handoff  The waker BLOCKS immediately after waking (pipe ping-pong). Its
#            own schedule() hands the cpu straight to the woken task via the
#            lowest-vruntime pick, so no hog can get between them.
#            MEASURED: 99.96% of round trips under 1 ms with four hogs.
#            This arm exists to keep "the input task competes fairly with the
#            hogs and loses" RULED OUT.
#
#   preempt  The waker does NOT yield: it posts an event from a syscall and
#            keeps burning ring-3 cpu. The woken task can only run when
#            something takes the cpu away from the incumbent.
#            MEASURED: uniform over [0, 10] ms — bounded by the 100 Hz TICK,
#            not by the 50 ms scheduling quantum.
#
#   irq      The wake is raised in INTERRUPT context (the kernel probe parks
#            on a wait queue with a one-tick timeout and is force-woken by the
#            hrtimer expiry callback from the timer ISR) while four
#            syscall-free ring-3 hogs hold the cpu. THIS IS THE MOUSE'S SHAPE
#            and it is the tightest of the three.
#            MEASURED: mean 13-75 us, max 42-202 us typical; an occasional
#            single sample reaches one tick. Repeating it with nice -20 hogs
#            (a 200 ms slice instead of 50 ms) did NOT lengthen the tail.
#
# WHAT THE MEASUREMENT RULED OUT (do not re-derive this)
# -----------------------------------------------------
#   * "the pointer path is a normal-priority task competing fairly with hogs"
#     — ruled out. All three shapes are serviced within one tick or better
#     with four nice-0 hogs at 100% CPU.
#   * "timeslices are too coarse" — ruled out, and disproved directly by
#     re-running the irq arm with nice -20 hogs: a 4x longer incumbent slice
#     produced no longer a tail. A woken task keeps its stale, low vruntime,
#     so it wins the very next _pick_next — and picks happen far more often
#     than once per quantum, because every blocking syscall is a pick.
#   * "input IRQ work is deferred behind a queue a hog starves" — ruled out.
#     The probe kept its full 100 Hz cadence (probe iteration count advances
#     by ~1 per tick) throughout the loaded window.
#
# VERDICTS
#   PASS          measured, under bound
#   FAIL          measured, over bound
#   INCONCLUSIVE  nothing measured (no report parsed, boot or serial
#                 injection dropped). An unobserved assertion is never a pass.
#
# Env overrides:
#   WAKELAT_IRQ_MAX_US    irq-arm ceiling, us       (default 5000)
#   WAKELAT_TICK_MAX_US   preempt-arm ceiling, us   (default 25000)
#   WAKELAT_MIN_SAMPLES   samples required per arm  (default 100)
#   WAKELAT_HANDOFF_PCT   handoff arm: min % <=1ms  (default 99)
#   BOOT_WAIT             overall qemu timeout, s   (default 520)
#   KEEP_LOG              1 = keep the serial log on PASS

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[wakelat]"
VTAG="wakelat"
source "$PROJ_ROOT/scripts/_verdict.sh"

WAKELAT_IRQ_MAX_US="${WAKELAT_IRQ_MAX_US:-5000}"
WAKELAT_TICK_MAX_US="${WAKELAT_TICK_MAX_US:-25000}"
WAKELAT_MIN_SAMPLES="${WAKELAT_MIN_SAMPLES:-100}"
WAKELAT_HANDOFF_PCT="${WAKELAT_HANDOFF_PCT:-99}"
BOOT_WAIT="${BOOT_WAIT:-520}"

# ----------------------------------------------------------------------
# STRUCTURAL PRE-CHECK — runs with or without QEMU.
#
# These are the seams the runtime numbers depend on. A refactor that drops one
# could still produce a healthy-looking number on a lightly loaded boot, so
# each is guarded explicitly. need_call() requires an INDENTED CALL, not just
# the identifier: a plain substring grep is satisfied by the `extern def` /
# import line, and a guard a deletion cannot trip is not a guard.
# ----------------------------------------------------------------------
struct_fail=0
need() {  # need <file> <literal> <what>
    if ! grep -aFq "$2" "$1"; then
        echo "$TAG FAIL: structural marker missing: $3 ($2 in $1)" >&2
        struct_fail=1
    fi
}
need_call() {  # need_call <file> <fn> <what>
    if ! grep -aqE "^[[:space:]]+$2\(" "$1"; then
        echo "$TAG FAIL: structural marker missing: $3 (no indented call to $2( in $1)" >&2
        struct_fail=1
    fi
}
need_call kernel/sched/core.ad _wklat_stamp \
    "wake timestamps taken on the WAIT->READY transition"
need_call kernel/sched/core.ad _wklat_account \
    "wake->dispatch interval closed at dispatch"
need kernel/sched/core.ad "def sched_note_dispatch" \
    "the single dispatch hook the instrument rides"
need sys/src/9/port/devproc.ad '"wklat"' \
    "the /proc/self/ctl control verb the gate drives"
# The kernel must ACK an accepted control verb. Without the ack a refused
# control write is indistinguishable from an accepted one, and the A/B runs
# both arms in the same configuration and reports "no difference" — which is
# exactly what happened twice while this gate was being built.
need kernel/sched/core.ad "ack wakeup_preempt=" \
    "control-verb acknowledgement (the silent-refusal guard)"

if [ "$struct_fail" -ne 0 ]; then
    verdict_fail "$VTAG" "structural seams missing (see above)"
    exit 1
fi

# ----------------------------------------------------------------------
# BUILD: hamsh as /init so the reproducer can be driven from a shell.
# ----------------------------------------------------------------------
. "$PROJ_ROOT/scripts/_build_lock.sh"
. "$PROJ_ROOT/scripts/_qemu_drive.sh"

ELF=build/hamnix-kernel-wakelat.elf
LOG="$(mktemp)"
restore_initramfs() {
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
cleanup() {
    restore_initramfs
    if [ "${KEEP_LOG:-0}" != "1" ]; then rm -f "$LOG"; fi
}
trap cleanup EXIT

echo "$TAG (1/3) build userland (wakelat, wakelat_echo, wakelat_hog)"
if ! bash scripts/build_user.sh >/dev/null 2>&1; then
    verdict_inconclusive "$VTAG" "userland build failed"
    exit 125
fi
for b in wakelat wakelat_echo wakelat_hog nice_hi; do
    if [ ! -f "build/user/$b.elf" ]; then
        verdict_inconclusive "$VTAG" "build/user/$b.elf missing after build"
        exit 125
    fi
done

echo "$TAG (2/3) build kernel with hamsh as /init"
if ! INIT_ELF=build/user/hamsh.elf python3 scripts/build_initramfs.py >/dev/null 2>&1; then
    verdict_inconclusive "$VTAG" "initramfs build failed"
    exit 125
fi
if ! python3 -m compiler.adder compile --target=x86_64-bare-metal \
        init/main.ad -o "$ELF" >/dev/null 2>&1; then
    verdict_inconclusive "$VTAG" "kernel build failed"
    exit 125
fi

echo "$TAG (3/3) boot -smp 1 and run /bin/wakelat"
# -smp 1 deliberately: with more cpus than hogs a woken task can simply be
# placed on an idle cpu and the contention the user reported never happens.
QEMU_EXTRA_ARGS="-smp 1" qemu_drive \
    "$LOG" "$ELF" "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    -- 'wakelat' 240 'exit' 2
rc="$QEMU_DRIVE_RC"

echo "$TAG --- measured ---"
grep -aE "\[wakelat\] (arm=|rt arm=|svc |hog )|\[wklat\]" "$LOG" \
    | grep -av runtime || true
echo "$TAG --- end ---"

# ----------------------------------------------------------------------
# PARSE. Every extraction is checked; a missing field is INCONCLUSIVE, never
# a pass. (rc=124 is expected and harmless: the driver bounds the whole run
# and the guest has no reason to power off.)
# ----------------------------------------------------------------------
if ! grep -aq "\[wakelat\] start" "$LOG"; then
    verdict_inconclusive "$VTAG" \
        "/bin/wakelat never started (rc=$rc) — serial injection or boot dropped"
    exit 125
fi
if grep -aq "\[wakelat\] FAIL" "$LOG"; then
    verdict_fail "$VTAG" "the reproducer reported a failure: $(grep -a '\[wakelat\] FAIL' "$LOG" | head -1)"
    exit 1
fi
# The control surface must have been REACHED. Both settings must be
# acknowledged by the kernel; if only one appears, the A/B never happened.
acks_off=$(grep -ac "\[wklat\] ack wakeup_preempt=0" "$LOG" || true)
acks_on=$(grep -ac "\[wklat\] ack wakeup_preempt=1" "$LOG" || true)
if [ "${acks_off:-0}" -lt 1 ] || [ "${acks_on:-0}" -lt 1 ]; then
    verdict_inconclusive "$VTAG" \
        "kernel never acknowledged the wklat control verb (off=$acks_off on=$acks_on) — the A/B did not happen"
    exit 125
fi

# --- kernel-side wake->dispatch reports. Each is a 7-line block; the ones we
# want are the LAST two, emitted by the irq arms (the only arms that run with
# the probe going, which the `probe=` field proves).
python3 - "$LOG" <<'PYEOF' > "$LOG.parsed"
import re, sys
txt = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
blocks, cur = [], None
for line in txt.splitlines():
    m = re.search(r'\[wklat\] n=(\d+) preempt=(\d+)', line)
    if m:
        cur = {'n': int(m.group(1)), 'preempt': int(m.group(2))}
        blocks.append(cur)
        continue
    if cur is None:
        continue
    for pat, keys in (
        (r'\[wklat\] max_us=(\d+) mean_us=(\d+)', ('max_us', 'mean_us')),
        (r'\[wklat\] le1ms=(\d+) le5ms=(\d+)',    ('le1ms', 'le5ms')),
        (r'\[wklat\] le12ms=(\d+) le25ms=(\d+)',  ('le12ms', 'le25ms')),
        (r'\[wklat\] le60ms=(\d+) over60ms=(\d+)', ('le60ms', 'over60ms')),
        (r'\[wklat\] kicks=(\d+) irqret=(\d+)',   ('kicks', 'irqret')),
        (r'\[wklat\] tickret=(\d+) probe=(\d+)',  ('tickret', 'probe')),
    ):
        m = re.search(pat, line)
        if m:
            for i, k in enumerate(keys):
                cur[k] = int(m.group(i + 1))
for b in blocks:
    print(' '.join('%s=%d' % (k, v) for k, v in sorted(b.items())))
PYEOF

# The irq arms are the blocks with a NON-ZERO probe iteration count: only they
# ran with the interrupt-context waker going.
irq_blocks=$(grep -E '(^| )probe=[1-9]' "$LOG.parsed" || true)
if [ -z "$irq_blocks" ]; then
    verdict_inconclusive "$VTAG" \
        "no kernel wake->dispatch report from an irq arm (probe never ran)"
    rm -f "$LOG.parsed"
    exit 125
fi

fail=0
prev_probe=0
while read -r blk; do
    [ -z "$blk" ] && continue
    eval "$(echo "$blk" | tr ' ' '\n' | sed 's/^/L_/')"
    if [ "${L_n:-0}" -lt "$WAKELAT_MIN_SAMPLES" ]; then
        verdict_inconclusive "$VTAG" \
            "irq arm collected only ${L_n:-0} samples (need $WAKELAT_MIN_SAMPLES) — window too short or probe stalled"
        rm -f "$LOG.parsed"
        exit 125
    fi
    # THE BOUND. The quantity the user perceives on the application half of
    # the pointer path, under four processes at 100% CPU.
    if [ "${L_max_us:-999999}" -gt "$WAKELAT_IRQ_MAX_US" ]; then
        echo "$TAG FAIL: irq-arm wake->dispatch max ${L_max_us}us > ${WAKELAT_IRQ_MAX_US}us (preempt=${L_preempt})" >&2
        fail=1
    else
        echo "$TAG irq arm preempt=${L_preempt}: n=${L_n} max=${L_max_us}us mean=${L_mean_us}us (bound ${WAKELAT_IRQ_MAX_US}us)"
    fi
    # The probe must have kept its 100 Hz cadence: a starved probe would make
    # the histogram look great by simply not sampling the bad moments. Roughly
    # one iteration per tick over a ~4.5 s window.
    step=$(( ${L_probe:-0} - prev_probe ))
    if [ "$step" -lt 200 ]; then
        echo "$TAG FAIL: probe advanced only $step iterations in the window — the interrupt-context waker was starved, so the histogram is not evidence" >&2
        fail=1
    fi
    prev_probe="${L_probe:-0}"
done <<< "$irq_blocks"

# --- the "preempt" arm (ring-0 waker that keeps the cpu): tick-bounded.
svc_lines=$(grep -aoE '\[wakelat\] svc n=[0-9]+ max_us=[0-9]+ mean_us=[0-9]+' "$LOG" \
            | awk -F'n=| max_us=| mean_us=' '$2 >= 10 {print $3}' || true)
if [ -z "$svc_lines" ]; then
    verdict_inconclusive "$VTAG" "no responder histogram (preempt arm) parsed"
    rm -f "$LOG.parsed"
    exit 125
fi
while read -r mx; do
    [ -z "$mx" ] && continue
    if [ "$mx" -gt "$WAKELAT_TICK_MAX_US" ]; then
        echo "$TAG FAIL: preempt-arm service latency max ${mx}us > ${WAKELAT_TICK_MAX_US}us" >&2
        fail=1
    else
        echo "$TAG preempt arm: max=${mx}us (bound ${WAKELAT_TICK_MAX_US}us)"
    fi
done <<< "$svc_lines"

# --- the "handoff" arm: keeps the ruled-out cause ruled out.
ho=$(grep -aoE '\[wakelat\] rt arm=handoff n=[0-9]+ max_us=[0-9]+ mean_us=[0-9]+ le1ms=[0-9]+' "$LOG" | tail -1 || true)
if [ -z "$ho" ]; then
    verdict_inconclusive "$VTAG" "no handoff-arm histogram parsed"
    rm -f "$LOG.parsed"
    exit 125
fi
ho_n=$(echo "$ho" | grep -oE 'n=[0-9]+' | head -1 | cut -d= -f2)
ho_1ms=$(echo "$ho" | grep -oE 'le1ms=[0-9]+' | cut -d= -f2)
if [ "$ho_n" -lt 1000 ]; then
    verdict_inconclusive "$VTAG" "handoff arm only $ho_n round trips"
    rm -f "$LOG.parsed"
    exit 125
fi
ho_pct=$(( ho_1ms * 100 / ho_n ))
if [ "$ho_pct" -lt "$WAKELAT_HANDOFF_PCT" ]; then
    echo "$TAG FAIL: only ${ho_pct}% of cooperative handoffs finished within 1 ms (need ${WAKELAT_HANDOFF_PCT}%) — schedule()'s lowest-vruntime pick has regressed" >&2
    fail=1
else
    echo "$TAG handoff arm: ${ho_pct}% of $ho_n round trips within 1 ms"
fi

rm -f "$LOG.parsed"

if [ "$fail" -ne 0 ]; then
    verdict_fail "$VTAG" "wake->dispatch latency exceeded its bound under 100% CPU load"
    exit 1
fi
verdict_pass "$VTAG" "wake->dispatch stays bounded under four 100%-CPU hogs (irq <= ${WAKELAT_IRQ_MAX_US}us, preempt <= ${WAKELAT_TICK_MAX_US}us, handoff >= ${WAKELAT_HANDOFF_PCT}% <1ms)"
exit 0
