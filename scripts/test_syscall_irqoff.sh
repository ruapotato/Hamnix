#!/usr/bin/env bash
# scripts/test_syscall_irqoff.sh
#
# INTERRUPT-LATENCY GATE: no syscall may hold EFLAGS.IF clear long enough to
# drop a timer tick, because the timer tick is what moves the mouse.
#
# USER REPORT: "things that take up a lot of CPU make the mouse studder or
# freze, it would be nice if the mouse would keep working even if a process is
# taking up 100% cpu."
#
# WHERE THIS SITS AMONG THE THREE LATENCY GATES
# ---------------------------------------------
#   test_wakeup_latency.sh          the SCHEDULER half: wake -> dispatch for
#                                   the DE client that must repaint. Measured
#                                   and CLEARED (12-56 us mean, 99-100% under
#                                   1 ms with four nice-0 hogs at 100% CPU).
#   test_pointer_latency_under_load.sh
#                                   the OUTCOME: longest interval during which
#                                   no mouse packet moved a cursor pixel.
#   THIS GATE                       the CAUSE the other two leave standing:
#                                   how long interrupts are actually MASKED,
#                                   and WHICH SYSCALL masked them.
#
# IA32_FMASK = 0x0200, so SYSCALL entry clears IF and the syscall body runs
# interrupts-off unless it re-enables them itself. While IF is clear the timer
# IRQ cannot be DELIVERED, and the timer IRQ is the only thing that runs
# mouse_pump_to_compositor(). So a masked stretch is a pointer freeze of
# exactly its own duration and no scheduler improvement can shorten it. That
# makes the masked stretch, not the syscall's wall-clock duration, the
# quantity to bound -- and the distinction matters: the blocking syscalls
# (nanosleep, blocking read, the cond_resched spin loops) do sti+hlt+cli per
# iteration, so an instrument that timed syscalls would name nanosleep the
# worst offender and be entirely wrong.
#
# WHAT THE INSTRUMENT REPORTS. Not syscall duration: the EXCESS over the
# nominal tick period, i.e. how late a timer IRQ that was already DUE got
# delivered because a syscall was holding IF clear. A syscall that never
# delays a due tick reports zero. See the banner over SYSIRQ_TICK_NS in
# arch/x86/kernel/time.ad for why the subtraction is load-bearing.
#
# WHAT IS ASSERTED
#   * max_us -- the longest tick delay attributable to a single syscall --
#     stays well inside one 100 Hz tick, in BOTH arms.
#   * NO syscall anywhere in the window delayed a tick by more than 5 ms.
#     Half a tick of masking is already visible cursor stutter, so this is a
#     zero-tolerance bucket rather than a percentile.
#   * the fraction of syscalls that delay a tick at ALL stays small.
#   * the loaded arm did not degrade relative to the idle arm beyond a ratio.
#     This is the arm that encodes the user's complaint: four processes at
#     100% CPU must not lengthen the masked stretches.
#
# MEASURED ON THIS TREE (-smp 1, TCG, hamsh boot, no DE):
#   idle    n=320530  delayed=287 (0.09%)   max=1915us
#   loaded  n=1439771 delayed=801 (0.056%)  max=1237us
#   worst offenders, both arms: write (nr=8) 1.2-1.9 ms, open (nr=5) ~0.1 ms.
#   `yield` (nr=24) heads the table with a max that tracks write's to within
#   ~20 us in both arms -- it is a yield SPANNING another task's write, not a
#   masked region of its own; see the cross-context-switch caveat in the
#   instrument banner. The real ceiling is write, and 1.9 ms is a FIFTH of a
#   tick: on this workload the syscall path does NOT mask interrupts long
#   enough to drop a tick, so it is not the source of a visible freeze.
#
# The report also NAMES the worst offenders (`[sysirq] top+ ... name=`), which
# is the attribution this gate exists to keep alive; the names are echoed into
# the output on every run, pass or fail, so a regression report says which
# syscall got slower rather than just that something did.
#
# VERDICTS
#   PASS          measured, under bound
#   FAIL          measured, over bound
#   INCONCLUSIVE  nothing measured (no report parsed, boot or serial injection
#                 dropped). An unobserved assertion is never a pass.
#
# Env overrides:
#   SYSIRQ_MAX_US        per-arm ceiling on the tick delay, us    (6000)
#   SYSIRQ_DELAY_PCT     max % of syscalls that delay a tick      (5)
#   SYSIRQ_MIN_SAMPLES   samples required per arm                 (500)
#   BOOT_WAIT            overall qemu timeout, s                  (300)
#   KEEP_LOG             1 = keep the serial log on PASS

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[sysirq]"
VTAG="sysirq"
source "$PROJ_ROOT/scripts/_verdict.sh"

# 6000 us: ~3x the measured worst case (1915 us) and still well inside one
# 10 ms tick, so a real regression is caught long before a tick is dropped.
SYSIRQ_MAX_US="${SYSIRQ_MAX_US:-6000}"
SYSIRQ_DELAY_PCT="${SYSIRQ_DELAY_PCT:-5}"
SYSIRQ_MIN_SAMPLES="${SYSIRQ_MIN_SAMPLES:-500}"
BOOT_WAIT="${BOOT_WAIT:-300}"

# ----------------------------------------------------------------------
# STRUCTURAL PRE-CHECK — runs with or without QEMU.
#
# The runtime numbers are only evidence if the instrument is still wired to
# the two things that make it sound: the tick (its witness that IF was set)
# and the syscall bracket (its attribution). A refactor that drops either
# would still produce a healthy-looking, entirely meaningless report.
# need_call() requires an INDENTED CALL, not just the identifier: a plain
# substring grep is satisfied by the import line, and a guard a deletion
# cannot trip is not a guard.
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
# Same guard for a call whose result is BOUND to a local (`x: T = fn()`). The
# `(` is still required, so the multi-line `from ... import (fn, fn2,)` block
# — which is indented and does contain the bare identifier — cannot satisfy it.
need_call_bound() {  # need_call_bound <file> <fn> <what>
    if ! grep -aqE "^[[:space:]]+[A-Za-z_].*[^A-Za-z0-9_]$2\(" "$1"; then
        echo "$TAG FAIL: structural marker missing: $3 (no indented call to $2( in $1)" >&2
        struct_fail=1
    fi
}
need_call arch/x86/kernel/time.ad sysirq_tick \
    "the timer tick that witnesses EFLAGS.IF being set"
need_call arch/x86/kernel/syscall.ad sysirq_account \
    "the per-syscall masked-time bracket in do_syscall"
need_call_bound arch/x86/kernel/syscall.ad sysirq_gap_take \
    "the re-entrancy-safe gap window saved on the do_syscall frame"
need arch/x86/kernel/time.ad "def sysirq_report" \
    "the report the gate parses"
need arch/x86/kernel/time.ad "def sysirq_name" \
    "worst-offender NAMES — the attribution this gate exists for"
need sys/src/9/port/devproc.ad '"sysirq"' \
    "the /proc/self/ctl control verb the reproducer drives"
# The kernel must ACK an accepted control verb. Without the ack a refused
# control write is indistinguishable from an accepted one, and both arms run
# in the same configuration while the gate reports "no difference".
need arch/x86/kernel/time.ad "ack armed=" \
    "control-verb acknowledgement (the silent-refusal guard)"
# Default-disarmed. An instrument that is on by default is a permanent cost
# on the syscall hot path, and this one is explicitly opt-in.
if ! grep -aqE "^sysirq_on:[[:space:]]+int32[[:space:]]+=[[:space:]]+0$" \
        arch/x86/kernel/time.ad; then
    echo "$TAG FAIL: sysirq must be DEFAULT-DISARMED (sysirq_on: int32 = 0)" >&2
    struct_fail=1
fi

if [ "$struct_fail" -ne 0 ]; then
    verdict_fail "$VTAG" "structural seams missing (see above)"
    exit 1
fi

# ----------------------------------------------------------------------
# BUILD: hamsh as /init so the reproducer can be driven from a shell.
# ----------------------------------------------------------------------
. "$PROJ_ROOT/scripts/_build_lock.sh"
. "$PROJ_ROOT/scripts/_qemu_drive.sh"

ELF=build/hamnix-kernel-sysirq.elf
LOG="$(mktemp)"
restore_initramfs() {
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
cleanup() {
    restore_initramfs
    if [ "${KEEP_LOG:-0}" != "1" ]; then rm -f "$LOG" "$LOG.parsed"; fi
}
trap cleanup EXIT

echo "$TAG (1/3) build userland (sysirqprobe, wakelat_hog)"
if ! bash scripts/build_user.sh >/dev/null 2>&1; then
    verdict_inconclusive "$VTAG" "userland build failed"
    exit 125
fi
for b in sysirqprobe wakelat_hog; do
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

echo "$TAG (3/3) boot -smp 1 and run /bin/sysirqprobe"
# -smp 1 deliberately: this is the configuration the user reported, and with
# more CPUs than hogs the contention never happens. It is also the only
# configuration in which the BSP-only tick witness is unambiguous.
QEMU_EXTRA_ARGS="-smp 1" qemu_drive \
    "$LOG" "$ELF" "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    -- 'sysirqprobe' 60 'exit' 2
rc="$QEMU_DRIVE_RC"

echo "$TAG --- measured ---"
grep -aE "\[sysirq\]|\[sysirqprobe\] (start|arm=|done|FAIL)" "$LOG" || true
echo "$TAG --- end ---"

# ----------------------------------------------------------------------
# PARSE. Every extraction is checked; a missing field is INCONCLUSIVE, never
# a pass. (rc=124 is expected and harmless: the driver bounds the whole run
# and the guest has no reason to power off.)
# ----------------------------------------------------------------------
if ! grep -aq "\[sysirqprobe\] start" "$LOG"; then
    verdict_inconclusive "$VTAG" \
        "/bin/sysirqprobe never started (rc=$rc) — serial injection or boot dropped"
    exit 125
fi
if grep -aq "\[sysirqprobe\] FAIL" "$LOG"; then
    verdict_fail "$VTAG" "the reproducer reported a failure: $(grep -a '\[sysirqprobe\] FAIL' "$LOG" | head -1)"
    exit 1
fi
acks=$(grep -ac "\[sysirq\] ack armed=1" "$LOG" || true)
if [ "${acks:-0}" -lt 2 ]; then
    verdict_inconclusive "$VTAG" \
        "kernel acknowledged the sysirq arm verb only $acks time(s); both arms must arm it — the A/B did not happen"
    exit 125
fi

python3 - "$LOG" <<'PYEOF' > "$LOG.parsed"
import re, sys
txt = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
blocks, cur = [], None
for line in txt.splitlines():
    m = re.search(r'\[sysirq\] n=(\d+) armed=(\d+)', line)
    if m:
        cur = {'n': int(m.group(1)), 'armed': int(m.group(2))}
        blocks.append(cur)
        continue
    if cur is None:
        continue
    for pat, keys in (
        (r'\[sysirq\] delayed=(\d+) tick_ns=(\d+)', ('delayed', 'tick_ns')),
        (r'\[sysirq\] max_us=(\d+) mean_us=(\d+)',  ('max_us', 'mean_us')),
        (r'\[sysirq\] le1ms=(\d+) le5ms=(\d+)',     ('le1ms', 'le5ms')),
        (r'\[sysirq\] le12ms=(\d+) le25ms=(\d+)',   ('le12ms', 'le25ms')),
        (r'\[sysirq\] le60ms=(\d+) over60ms=(\d+)', ('le60ms', 'over60ms')),
    ):
        m = re.search(pat, line)
        if m:
            for i, k in enumerate(keys):
                cur[k] = int(m.group(i + 1))
for b in blocks:
    print(' '.join('%s=%d' % (k, v) for k, v in sorted(b.items())))
PYEOF

nblocks=$(grep -c . "$LOG.parsed" || true)
if [ "${nblocks:-0}" -lt 2 ]; then
    verdict_inconclusive "$VTAG" \
        "only ${nblocks:-0} sysirq report block(s) parsed; the idle/loaded A/B needs 2"
    exit 125
fi

fail=0
thin=0
arm=0
declare -a arm_max=()
while read -r blk; do
    [ -z "$blk" ] && continue
    eval "$(echo "$blk" | tr ' ' '\n' | sed 's/^/L_/')"
    arm=$((arm + 1))
    n="${L_n:-0}"
    [ "$n" -lt 1 ] && n=1
    # Samples that delayed a due tick by MORE THAN 5 ms. Zero tolerance: half
    # a tick of masking is already a visible cursor stutter, and unlike a
    # percentile this cannot be diluted by simply issuing more cheap syscalls.
    over5=$(( ${L_le12ms:-0} + ${L_le25ms:-0} + ${L_le60ms:-0} + ${L_over60ms:-0} ))
    delay_pct=$(( ${L_delayed:-0} * 100 / n ))
    # THE BOUND. The longest delay the kernel can PROVE it imposed on a timer
    # IRQ that was already due, inside one syscall. Past a tick that means a
    # DROPPED tick, and a dropped tick is a pointer that did not move.
    if [ "${L_max_us:-999999}" -gt "$SYSIRQ_MAX_US" ]; then
        echo "$TAG FAIL: arm $arm delayed a due timer IRQ by ${L_max_us}us > ${SYSIRQ_MAX_US}us (n=${L_n}, delayed=${L_delayed:-?})" >&2
        fail=1
    elif [ "$over5" -gt 0 ]; then
        echo "$TAG FAIL: arm $arm had $over5 syscall(s) that delayed a due timer IRQ by more than 5 ms (n=${L_n}, max=${L_max_us}us)" >&2
        fail=1
    elif [ "$delay_pct" -gt "$SYSIRQ_DELAY_PCT" ]; then
        echo "$TAG FAIL: arm $arm — ${delay_pct}% of syscalls delayed a due timer IRQ (limit ${SYSIRQ_DELAY_PCT}%, n=${L_n}, delayed=${L_delayed:-?})" >&2
        fail=1
    else
        echo "$TAG arm $arm: n=${L_n} delayed=${L_delayed:-?} (${delay_pct}%) max=${L_max_us}us over5ms=$over5"
    fi
    arm_max+=("${L_max_us:-0}")
    if [ "${L_n:-0}" -lt "$SYSIRQ_MIN_SAMPLES" ]; then
        thin=1
    fi
done < "$LOG.parsed"

# The A/B itself. Arm 1 is idle, arm 2 is under four processes at 100% CPU.
# The user's claim is that CPU load is what breaks the pointer; if that is
# true here it shows up as the loaded arm's masked stretches being longer.
idle_max="${arm_max[0]:-0}"
load_max="${arm_max[1]:-0}"
echo "$TAG A/B: idle max=${idle_max}us  loaded(4x100%% CPU) max=${load_max}us"
if [ "$idle_max" -gt 0 ] && [ "$load_max" -gt $(( idle_max * 3 )) ] \
        && [ "$load_max" -gt 12000 ]; then
    echo "$TAG FAIL: 100%-CPU load tripled the interrupt-masked stretch (${idle_max}us -> ${load_max}us) — the pointer path IS load-sensitive" >&2
    fail=1
fi

# Attribution, always echoed. A regression must say WHICH syscall got worse.
echo "$TAG --- worst offenders by name ---"
grep -aE "\[sysirq\] top\+? " "$LOG" || echo "$TAG (no per-syscall attribution lines)"
echo "$TAG --- end ---"
if ! grep -aq "\[sysirq\] top+ " "$LOG"; then
    verdict_inconclusive "$VTAG" \
        "no per-syscall attribution parsed — the report ran but named nothing"
    exit 125
fi

# ORDER MATTERS: assert on the numbers BEFORE complaining about sample count.
# A regression severe enough to starve the instrument must report FAIL, not
# "I could not tell"; a thin sample is only ambiguous when the samples that
# WERE collected look healthy.
if [ "$fail" -eq 0 ] && [ "$thin" -ne 0 ]; then
    verdict_inconclusive "$VTAG" \
        "an arm collected fewer than $SYSIRQ_MIN_SAMPLES samples while looking healthy — window too short or the boot was starved by host load"
    exit 125
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$VTAG" "a syscall held interrupts masked long enough to drop a timer tick — the pointer freezes for exactly that long"
    exit 1
fi
verdict_pass "$VTAG" "no syscall delays a due timer IRQ past ${SYSIRQ_MAX_US}us, idle or under four 100%-CPU processes (0 samples over 5 ms, <= ${SYSIRQ_DELAY_PCT}% delayed at all)"
exit 0
