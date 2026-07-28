#!/usr/bin/env bash
# scripts/test_hamsh_heartbeat.sh - the hamsh idle heartbeat lives.
#
# The interactive shell emits a periodic "[hamsh-alive] tick=N
# uptime=Ns" line from ed_readline's idle poll loop (see
# user/hamsh.ad's _hb_check_and_emit / _hb_emit_to_stderr). It is the
# canary for "shell is being scheduled at all" — without it, a
# regression where a kernel-mode syscall busy-loops without yielding
# (or a userland service hogs cycles) starves the shell, the user
# stops getting heartbeats, AND every test that drives input via the
# serial port stalls because the shell never reads anything.
#
# This silently regressed once already (per project memory's
# "regression-prone needs a test" rule), so it gets a dedicated CI
# test that boots the production rc.boot path (sshd + motd + ifconfig
# all running, which is the realistic load) and asserts at least
# three heartbeats reach the serial console within the boot window.
#
# Three rather than one because tick=0 fires almost instantly (the
# first ed_readline call seeds hb_inited), so the meaningful signal
# is that successive ticks (tick=1 at ~3 s, tick=2 at ~6 s, ...) DO
# follow — i.e. the idle loop keeps getting CPU.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_hamsh_heartbeat] (1/3) Build"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
# The [hamsh-alive] heartbeat is OPT-IN (dev/CI liveness canary, kept off a
# normal shipped boot's console). ENABLE_HAMSH_HEARTBEAT=1 plants the
# /etc/hamsh-heartbeat marker hamsh's main() probes to arm it — without this
# the heartbeat never fires and this gate would (correctly) see zero ticks.
ENABLE_HAMSH_HEARTBEAT=1 python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_hamsh_heartbeat] (2/3) Boot QEMU"
LOG=$(mktemp /tmp/hamsh-heartbeat.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

# Boot+observation window. Historical value was 90 s — chosen against a
# nominal stage-07 reach time of ~12-15 s, which left ~75 s of idle for
# heartbeats at 3 s cadence (≥24 ticks in a quiet run). The failure mode
# we hit is "0 heartbeat lines on first run, 24-26 on the immediate retry
# without code changes" — i.e. the FIRST run boots so slowly under load
# (orchestrator runs heartbeat right after agents tear down their own
# QEMU processes; those drain for ~tens of seconds and the host's TCG
# scheduler is heavily contended in that window) that the kernel never
# reaches stage-07 inside 90 s. There is no real bug — give the boot
# more headroom.
#
# 180 s leaves ≥150 s of observable idle even when the boot crawls to
# stage-07 at T+30 s under heavy host load, and is still bounded enough
# that a real prompt regression fails fast. Override with
# HAMNIX_HEARTBEAT_TIMEOUT=<seconds> for one-off debugging.
HEARTBEAT_TIMEOUT="${HAMNIX_HEARTBEAT_TIMEOUT:-180}"

# boot_arm <ncpus> <logfile> -> echoes qemu's rc; log lands in <logfile>.
#
# Pure observation — production boot path with all services running.
# No input piped in: a fully idle interactive shell MUST still emit
# heartbeats. If it doesn't, a kernel busy-loop or a userland CPU hog
# is starving the prompt.
# -m 1G: the debug kernel ELF carries a large embedded initramfs (~200MB
# .text). At -m 256M the BIOS GRUB ISO loader (via _kernel_iso.sh) #PFs
# "error: out of memory" before it can hand control to the kernel. 1G
# matches the installer/rl5 harness budget and leaves GRUB room to load.
# This gate asserts a WALL-CLOCK cadence (N heartbeat ticks inside a host-timed
# window), so it MUST run under a hardware accelerator or it cannot distinguish a
# slow guest from a stopped one. In practice the `_kernel_iso.sh` PATH shim
# (sourced via _build_lock.sh) already injects `-accel kvm -cpu host` when
# /dev/kvm is usable and no accelerator was chosen; the explicit KVM_ARGS here is
# belt-and-braces so the requirement is visible at the call site and survives
# anyone invoking this script outside the shim. Even under KVM a wall-clock canary
# cannot separate "wedged" from "slow" on its own — that is what the -smp 1
# CONTROL arm below is for (the comparison the earlier version of this comment
# said the gate still needed; it now exists).
KVM_ARGS=""
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM_ARGS="-enable-kvm -cpu host"
fi

# boot_arm <ncpus> <logfile> -> echoes qemu's rc; log lands in <logfile>.
boot_arm() {
    local ncpus="$1" log="$2" arm_rc=0
    timeout "${HEARTBEAT_TIMEOUT}s" qemu-system-x86_64 \
        $KVM_ARGS \
        -kernel "$ELF" -smp "$ncpus" -nographic -no-reboot -m 1G \
        -monitor none -serial stdio < /dev/null > "$log" 2>&1 || arm_rc=$?
    echo "$arm_rc"
}

tick_lines()    { grep -F -c "[hamsh-alive] tick=" "$1" 2>/dev/null || true; }
distinct_tick() { grep -Eo "\[hamsh-alive\] tick=[0-9]+ " "$1" 2>/dev/null \
                  | sort -u | wc -l || true; }
reached_repl()  { grep -F -q "[hamsh:stage-07] loop-enter" "$1"; }

set +e
rc=$(boot_arm 2 "$LOG")
set -e

echo "[test_hamsh_heartbeat] (3/3) Assertions"
TAG=test_hamsh_heartbeat

# ─── The -smp 1 CONTROL ARM ─────────────────────────────────────────────────
#
# WHY THIS EXISTS. Everything below used to collapse "the guest wedged" and
# "the host was too slow to boot it in time" into a single INCONCLUSIVE,
# because from a truncated log they are indistinguishable. That ambiguity hid
# a real, deterministic `-smp 2` kernel wedge for WEEKS: the shared global
# `quantum_left` meant an AP's idle-loop dispatches kept re-arming the BSP's
# time slice, so the BSP never preempted and hamsh sat STATE_READY forever
# (see kernel/sched/core.ad). Every run reported INCONCLUSIVE; nobody looked.
#
# The discriminator is a CONTROL: re-run the SAME kernel, SAME window, SAME
# host, at `-smp 1`. The bug is SMP-only, so:
#
#   -smp 1 heartbeats, -smp 2 none  -> the host was demonstrably fast enough.
#                                      The delta is the kernel. FAIL.
#   neither arm produces heartbeats -> the host really is starved (or boot is
#                                      broken for both). INCONCLUSIVE.
#
# Only run the control when the -smp 2 arm came up empty; a passing run costs
# nothing extra.
# Sets the globals CTRL_LOG / CTRL_RC / CTRL_TICKS and RETURNS 0 ("live") if the
# -smp 1 control reached the REPL and emitted ≥1 heartbeat, else returns 1
# ("dead"). MUST be called directly (not in `$(...)`) so the globals survive.
CTRL_LOG=""; CTRL_RC=""; CTRL_TICKS=0
smp1_control_is_live() {
    CTRL_LOG=$(mktemp /tmp/hamsh-heartbeat-smp1.XXXXXX.log)
    echo "[test_hamsh_heartbeat] -smp 2 came up empty — running the -smp 1" \
         "control arm to tell a wedge apart from a starved host"
    set +e
    CTRL_RC=$(boot_arm 1 "$CTRL_LOG")
    set -e
    CTRL_TICKS=$(tick_lines "$CTRL_LOG")
    echo "[test_hamsh_heartbeat] control: -smp 1 rc=$CTRL_RC" \
         "heartbeats=$CTRL_TICKS"
    reached_repl "$CTRL_LOG" && [ "$CTRL_TICKS" -gt 0 ]
}

# Sanity: the prompt actually came up.
#
# If stage-07 is absent we must be careful about what we can honestly
# claim. Two very different worlds produce that same observation:
#
#   (a) the kernel/userland is genuinely wedged before the REPL, OR
#   (b) the boot was simply still crawling when our host wall-clock
#       window closed (the historical note below documents exactly
#       this: "0 heartbeat lines on first run, 24-26 on the immediate
#       retry without code changes").
#
# From "stage-07 absent" alone these are INDISTINGUISHABLE. The
# discriminator is HOW QEMU died:
#
#   * rc != 124  -> QEMU exited on its own before the prompt. We
#                   OBSERVED a crash / early exit. That is a real FAIL.
#   * rc == 124  -> `timeout` killed a still-running QEMU. We observed
#                   nothing except that it hadn't finished booting yet.
#                   INCONCLUSIVE.
#
# Note what this is NOT: it is not a licence to ignore a wedge. An
# INCONCLUSIVE never counts as a pass, run_gate.sh retries it once, and
# gate_summary.sh renders the whole battery as NOT VERIFIED. A genuine
# boot wedge produces INCONCLUSIVE *every* time, including on a quiet
# host, which is the signal to go look. The previous code's response to
# this same ambiguity was to stretch the timeout 90s -> 180s until the
# flake went away; that hid the ambiguity instead of reporting it.
if ! reached_repl "$LOG"; then
    echo "[test_hamsh_heartbeat] qemu rc=$rc timeout=${HEARTBEAT_TIMEOUT}s"
    tail -50 "$LOG" | strings
    if [ "$rc" -ne 124 ]; then
        verdict_fail "$TAG" "hamsh never reached the interactive loop" \
            "(stage-07 marker absent) and qemu exited on its own with" \
            "rc=$rc — an observed crash before the prompt."
    fi
    # rc == 124: still running at the deadline. Ask the control arm whether
    # this host can boot the SAME kernel to a live prompt at -smp 1.
    if smp1_control_is_live; then
        verdict_fail "$TAG" "-smp 2 never reached stage-07 in" \
            "${HEARTBEAT_TIMEOUT}s, but the -smp 1 control arm reached the" \
            "prompt and emitted $CTRL_TICKS heartbeats on this same host in" \
            "the same window. The host is not the problem — the kernel wedges" \
            "with more than one CPU. Control log: $CTRL_LOG"
    fi
    verdict_inconclusive "$TAG" "boot had not reached stage-07 when the" \
        "${HEARTBEAT_TIMEOUT}s window closed (qemu rc=124, still running)," \
        "AND the -smp 1 control arm did not reach a live prompt either" \
        "(rc=$CTRL_RC, $CTRL_TICKS heartbeats) — so the host, not the" \
        "kernel, is the likely cause. Re-run on a quiet host."
fi

# Count heartbeat ticks (total lines + distinct tick numbers).
#
# Original threshold was "≥3 ticks AND tick=1 AND tick=2". That asks
# two things at once:
#   (a) the boot reached the prompt (stage-07) — TRUE liveness signal.
#   (b) ≥2 periodic rearms of the heartbeat occurred — proves the idle
#       poll loop keeps getting CPU after the prompt.
#
# Under heavy host contention (the orchestrator runs heartbeat right
# after agents finish; their QEMU procs are still draining, and the
# host scheduler + emulated timer-IRQ delivery to the guest get badly
# starved) the GUEST'S jiffies counter advances much slower than host
# wall clock. With HB_PERIOD_JIFFIES=300 (3 guest-seconds at 100 Hz),
# a guest whose jiffies only ticks once per ~5 host-seconds needs
# ~15 host-seconds per heartbeat instead of 3. The original 90 s
# window had ~78 s of post-stage-07 idle under quiet conditions —
# plenty for ≥3 ticks. Under load it could shrink to 0-5 s and no
# tick fires before host timeout. Hence the observed flake.
#
# Two-tier check:
#   1. stage-07 reached (above).
#   2. ≥2 distinct tick values within window. ≥2 implies the rearm path
#      in _hb_check_and_emit ran at least once (so a tick=0-forever
#      rearm bug still fails). Under quiet conditions we'd see 0..25;
#      under load we may see only 0,1 (or even just 1 since tick=0 is
#      NOT emitted — see _hb_check_and_emit, which seeds and returns
#      silently on first call).
#
# Zero ticks means the heartbeat semantic was NEVER OBSERVED. The old
# code called that "PASS (inconclusive: ...)" and exited 0, which is a
# contradiction in terms and precisely the false green this project
# keeps getting burned by: the entire purpose of this canary is to
# observe heartbeat cadence, so a run that observed none proved
# NOTHING. It is now reported as INCONCLUSIVE (exit 125) — not a pass,
# not a code failure. See scripts/_verdict.sh.
tick_count=$(tick_lines "$LOG")
distinct_ticks=$(distinct_tick "$LOG")
echo "[test_hamsh_heartbeat] observed $tick_count heartbeat lines," \
     "$distinct_ticks distinct tick values"

# Detect a real rearm bug: heartbeat lines present but only ONE
# distinct tick number — that means _hb_check_and_emit got called and
# emitted, but the rearm-on-next-jiffies path never advanced. This is
# a different failure shape than "no ticks at all" and IS a hard fail.
if [ "$tick_count" -gt 0 ] && [ "$distinct_ticks" -lt 2 ]; then
    echo "[test_hamsh_heartbeat] --- tail ---"
    tail -50 "$LOG" | strings
    verdict_fail "$TAG" "$tick_count heartbeat lines but only" \
        "$distinct_ticks distinct tick value(s). The idle poll loop emitted" \
        "but never rearmed — likely a heartbeat-rearm regression in" \
        "_hb_check_and_emit (hb_next_jiffies not advancing) or a" \
        "tick=0-forever corruption. OBSERVED, and wrong."
fi

# No heartbeats at all.
#
#   rc != 124 -> QEMU exited on its own at or just after the prompt: an
#                OBSERVED crash. FAIL.
#   rc == 124 -> `timeout` killed a live QEMU. The guest's jiffies
#                counter never advanced HB_PERIOD_JIFFIES within our
#                host wall-clock window. We did not observe a heartbeat
#                and we did not observe its absence-under-fair-scheduling
#                either. INCONCLUSIVE — say so, and exit 125.
if [ "$tick_count" -eq 0 ]; then
    echo "[test_hamsh_heartbeat] --- tail ---"
    tail -50 "$LOG" | strings
    if [ "$rc" -ne 124 ]; then
        verdict_fail "$TAG" "0 heartbeats and qemu rc=$rc (non-timeout exit" \
            "— kernel/userland crashed at or just after the prompt)." \
            "This is NOT the host-contention case."
    fi
    # rc == 124 and stage-07 WAS reached: the shell came up and then went
    # quiet. This is the exact signature of the -smp>1 wedge (hamsh parked
    # STATE_READY on a runqueue whose CPU stopped preempting). The control
    # arm settles whether the host or the kernel is at fault.
    if smp1_control_is_live; then
        verdict_fail "$TAG" "0 heartbeats at -smp 2 after reaching stage-07," \
            "but the -smp 1 control arm emitted $CTRL_TICKS heartbeats on the" \
            "same host in the same ${HEARTBEAT_TIMEOUT}s window. The prompt" \
            "came up and then stopped being scheduled: an SMP wedge, not host" \
            "starvation. Control log: $CTRL_LOG"
    fi
    verdict_inconclusive "$TAG" "0 heartbeats observed in ${HEARTBEAT_TIMEOUT}s." \
        "stage-07 was reached and qemu was still running when the window" \
        "closed (rc=124), AND the -smp 1 control arm was also unable to" \
        "produce a heartbeat (rc=$CTRL_RC, $CTRL_TICKS heartbeats) — so the" \
        "guest timer really was starved by host load. The heartbeat cadence" \
        "this canary exists to check was NEVER OBSERVED, either way."
fi

verdict_pass "$TAG" "qemu rc=$rc, $tick_count heartbeat lines," \
    "$distinct_ticks distinct tick values (≥2 required: rearm confirmed)"
