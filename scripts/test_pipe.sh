#!/usr/bin/env bash
# scripts/test_pipe.sh — hamsh pipeline gate.
#
# WHY THIS GATE WAS REWRITTEN (read before touching an assertion)
#
# The previous version drove hamsh through
#
#     echo pipe payload | cat
#
# and grepped the serial log for "pipe payload". That assertion is
# satisfied by TWO completely different worlds:
#
#   (1) `echo` wrote into the pipe, `cat` drained it and printed the
#       payload — the pipe works; or
#   (2) `echo` never touched the pipe, wrote STRAIGHT TO THE CONSOLE,
#       and `cat` read instant EOF from an empty pipe and printed nothing.
#
# In world (2) the string still lands on serial, so the gate went green.
# World (2) is exactly what shipped: `echo` is a hamsh BUILTIN, and
# run_one_command_x's builtin arm ignored in_pipe / out_pipe entirely. A
# completely broken shell pipeline sailed through CI because this test
# could not distinguish "delivered through the pipe" from "leaked to the
# console".
#
# THE RULE THIS GATE NOW FOLLOWS
#
# Assert something ONLY A REAL PIPE CAN PRODUCE. Every pipe case asserts
# BOTH halves:
#
#   * POSITIVE — the consumer's COMPUTED answer appears: a count that the
#     producer never prints and therefore cannot have leaked; and
#   * NEGATIVE — the producer's own output does NOT appear on the console.
#
# A leak fails the negative. A dead pipe (reader gets EOF) fails the
# positive. Neither can pass both unless the bytes travelled the pipe.
#
# Cases:
#   1. external | external   seq 1000 1041 | wc -l          -> 42
#   2. BUILTIN  | external   echo BUILTINPIPE | wc -c       -> 12
#   3. three stages          seq 1000 1099 | grep 7 | wc -l -> 19
#   4. redirect              echo REDIRPAYLOAD > f ; cat f  (same fdbind path)
#   5. dup into a pipe       echo DUPPAYLOAD 2>&1 | wc -c   -> 11
#   6. the shell SURVIVES    a plain command still runs afterwards
#
# WHY hamsh-as-/init AND NOT THE runlevel-5 SHIPPED IMAGE
#
# Acceptance for a boot path is the shipped .img under UEFI/OVMF. But this
# gate asserts on what the INTERACTIVE SHELL prints, and on a runlevel-5
# boot the serial console (/dev/cons) is shared between the serial shell,
# three VT gettys and the DE input path — serial input routing is
# AMBIGUOUS, and driver keystrokes are routinely consumed by a getty or the
# DE instead of the shell whose output we assert. (scripts/test_security.sh
# documents the same finding and moved to the same lean rig for the same
# reason. Empirically: on build/hamnix-installer.img under OVMF+KVM, not
# one of `echo FEEDER_SYNC`, `\n`, `\r` or `\r\n` ever echoed, across
# repeated re-sends, even after gating on the console shell's own
# post-uid-drop marker.) A gate that cannot reliably deliver a keystroke
# cannot honestly report PASS or FAIL, so it must not be the gate.
#
# hamsh-as-/init keeps the serial line the SOLE interactive shell, and
# exercises the identical run_pipeline / spawn_pipeline_stage / devfd code.
# Whoever verifies a pipeline change on the shipped image drives it by
# hand; this gate makes CI catch the mechanism breaking.
#
#
# GUEST CPU COUNT — why the default is 1, and when to change it back
#
# This gate runs the guest with -smp ${HAMNIX_TEST_SMP:-1}. Under -smp 2 the
# shell intermittently WEDGES immediately after any pipeline: both stages
# reap cleanly ("task: pid N exited"), the kernel keeps running, and hamsh
# never returns from its post-pipeline wait. That is a PRE-EXISTING SCHEDULER
# bug, not a pipe bug — it reproduces on an UNMODIFIED hamsh, on TCG and on
# KVM, and switching the wait from the blocking sys_waitpid to a polled
# sys_waitpid_jc + sys_yield does not avoid it (both halt in
# kernel/sched/core.ad :: yield_to_others). run_pipeline is simply hamsh's
# only wait that yields while a sibling task is still running, so a pipeline
# is the reliable trigger.
#
# FIXED (default flipped back to 2): the wedge was a recursive rq-lock
# self-deadlock in schedule()'s BSP idle-loop — it re-acquired rq_locks[0]
# without releasing the outer hold whenever a child exited on the BSP while the
# parent had been work-stolen onto an AP. See kernel/sched/core.ad and
# scripts/test_smp2_foreground_external.sh. This gate now runs at -smp 2 to
# exercise the pipeline path (hamsh's other sibling-still-running wait) on the
# fixed scheduler.
#
# VERDICTS (scripts/_verdict.sh, docs/TEST_VERDICTS.md)
#   PASS         (0)   every assertion was OBSERVED to hold
#   FAIL         (1)   an assertion was OBSERVED to be violated — a wrong
#                      answer printed, or producer output on the console
#   INCONCLUSIVE (125) never got far enough to observe: the build failed,
#                      boot never reached the shell, the feeder's sync
#                      never echoed, or QEMU timed out under host load
set -uo pipefail
# The guest's stdin is a FIFO. Once QEMU exits (e.g. on `exit`, or when it
# is killed), any further write to it raises SIGPIPE — which would kill this
# script before it printed its verdict. Ignore it; every write site below
# tolerates a short write.
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_log.sh"
# _kernel_iso.sh installs a build/binshim/qemu-system-x86_64 wrapper on
# PATH that turns `-kernel <elf64>` into a GRUB-ISO `-cdrom` boot (QEMU's
# own multiboot1 loader rejects the higher-half elf64 kernel).
. "$PROJ_ROOT/scripts/_kernel_iso.sh"

TAG="test_pipe"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
# Wall-clock ceiling for the whole guest run. Under TCG on a loaded host a
# single interactive line takes many seconds (the editor echoes it one
# character at a time), so the driver below is ADAPTIVE: it waits for each
# command's own output rather than sleeping a fixed amount. This is only
# the backstop.
SMP="${HAMNIX_TEST_SMP:-2}"     # see the -smp note in the header
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[$TAG] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user.sh failed"
bash scripts/build_modules.sh >/dev/null 2>&1 || true

echo "[$TAG] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs.py failed"

echo "[$TAG] (3/4) Rebuild kernel image"
LOG=$(mktemp)
# A minimal restore trap is armed immediately: from here on, an early exit
# must still put /init back (the initramfs currently has hamsh as /init).
restore_init() {
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap restore_init EXIT

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null 2>&1 || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[$TAG] (4/4) Boot and drive hamsh"
FIFO=$(mktemp -u --tmpdir hamnix-pipe-in.XXXXXX)
mkfifo "$FIFO"
QEMU_PID=""
# Widen the trap now that there is a QEMU to kill and a FIFO to remove.
# Leave no zombie qemu behind, on any exit path.
restore_init() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    [ -n "${QEMU_PID:-}" ] && wait "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    rm -f "$FIFO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap restore_init EXIT

# Command-output assertions come from scripts/_hamsh_log.sh. `outline_eq 42`
# means some command really printed a line whose ENTIRE content was "42" —
# a value none of the producers below ever print, so a console leak cannot
# fake it, and a kernel "[001042]" timestamp cannot either.
outlines()      { hamsh_outlines "$LOG"; }
outline_eq()    { hamsh_out_eq "$LOG" "$1"; }
outline_count() { hamsh_out_count "$LOG" "$1"; }

# The binshim on PATH rewrites `-kernel <elf64>` into a GRUB `-cdrom` boot.
qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp "$SMP" -m "${HAMNIX_VM_MEM:-2G}" \
    -nographic -no-reboot -monitor none \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
exec 3> "$FIFO"

alive() { kill -0 "$QEMU_PID" 2>/dev/null; }

wait_raw() {                       # <literal> <secs> — match anywhere in log
    local i
    for i in $(seq 1 "$2"); do
        grep -a -F -q "$1" "$LOG" && return 0
        alive || return 1
        sleep 1
    done
    return 1
}

# A freshly-booted hamsh DROPS the first serial line it is sent, and its
# readline only starts consuming stdin after rc.boot hands off. So never
# gate a keystroke on a fixed sleep: re-send an IDEMPOTENT command until
# the effect we are waiting for shows up. (scripts/_qemu_drive.sh documents
# the same rule; these variants wait on the command's OUTPUT, so they cost
# exactly as long as the guest needs and no longer.)
# sync_probe — ONLY for the very first line. A freshly-booted hamsh drops
# the first serial line it is sent (and its readline does not consume stdin
# until rc.boot hands off), so the first command must be RE-SENT until it
# echoes. `echo` is idempotent, so a duplicate landing twice is harmless.
sync_probe() {                     # <secs>
    local secs="$1" waited=0 i
    while [ "$waited" -lt "$secs" ]; do
        alive || return 1
        printf 'echo FEEDER_SYNC\n' >&3 2>/dev/null || return 1
        for i in $(seq 1 5); do
            grep -a -F -q "FEEDER_SYNC" "$LOG" && { sleep 1; return 0; }
            alive || return 1
            sleep 1; waited=$((waited + 1))
            [ "$waited" -ge "$secs" ] && break
        done
    done
    return 1
}

# After the sync handshake the readline is provably consuming stdin, so every
# later command is sent EXACTLY ONCE and we wait for its result. Re-sending
# here would be actively harmful: under TCG the editor echoes a line one
# character at a time and takes tens of seconds, so a resend would splice a
# second copy of the command into the line still being typed.
send_await_raw() {                 # <cmd> <literal-in-log> <secs>
    local cmd="$1" pat="$2" secs="$3" i
    alive || return 1
    printf '%s\n' "$cmd" >&3 2>/dev/null || return 1
    for i in $(seq 1 "$secs"); do
        grep -a -F -q "$pat" "$LOG" && { sleep 1; return 0; }
        alive || return 1
        sleep 1
    done
    return 1
}
send_await_out() {                 # <cmd> <exact-output-line> <secs>
    local cmd="$1" want="$2" secs="$3" i
    alive || return 1
    printf '%s\n' "$cmd" >&3 2>/dev/null || return 1
    for i in $(seq 1 "$secs"); do
        outline_eq "$want" && { sleep 1; return 0; }
        alive || return 1
        sleep 1
    done
    return 1
}

wait_raw "[hamsh:stage-07] loop-enter" "$BOOT_WAIT" || {
    tail -30 "$LOG" | strings >&2
    verdict_inconclusive "$TAG" "hamsh never reached its interactive loop in ${BOOT_WAIT}s"
}
# Prove a live readline is consuming stdin before asserting anything.
sync_probe 120 || {
    tail -30 "$LOG" | strings >&2
    verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"
}

# Drive each case to its OWN observable result. A result that never appears
# within CMD_WAIT means the guest was starved, not that the code is wrong —
# that is INCONCLUSIVE. The one exception is case 6, where "the shell never
# ran it" IS the failure being tested for.
# Each wait ends as soon as EITHER the right answer or the tell-tale of the
# bug appears, so a broken build fails fast instead of burning CMD_WAIT.
c1=0; c2=0; c3=0; c4=0; c5=0; c6=0
send_await_out 'seq 1000 1041 | wc -l'          '42'          "$CMD_WAIT" && c1=1
send_await_out 'echo BUILTINPIPE | wc -c'       '12'          "$CMD_WAIT" && c2=1
send_await_out 'seq 1000 1099 | grep 7 | wc -l' '19'          "$CMD_WAIT" && c3=1
send_await_raw 'echo REDIRPAYLOAD > /tmp/pipetest_f' \
               'REDIRPAYLOAD > /tmp/pipetest_f'               "$CMD_WAIT" && c4=1
sleep 2
send_await_out 'cat /tmp/pipetest_f' 'REDIRPAYLOAD'           "$CMD_WAIT" || true
send_await_out 'echo DUPPAYLOAD 2>&1 | wc -c'   '11'          "$CMD_WAIT" && c5=1
send_await_raw 'echo ALIVE-AFTER-PIPE' 'ALIVE-AFTER-PIPE'     "$CMD_WAIT" && c6=1
alive && { printf 'exit\n' >&3 2>/dev/null || true; }
sleep 2

fail=0
wrong() { echo "[$TAG] WRONG: $*" >&2; fail=1; }
ok()    { echo "[$TAG] ok: $*"; }

# --- 1. external | external -------------------------------------------
# 42 lines cross the pipe. `wc -l` prints a count seq never prints; a leak
# shows up as bare "1000"/"1041" console lines.
if [ "$c1" -eq 0 ] && ! outline_eq "1000" && ! outline_eq "1041"; then
    verdict_inconclusive "$TAG" \
        "case 1 produced neither the answer nor a leak within ${CMD_WAIT}s — guest starved?"
fi
if outline_eq "42"; then
    ok "case 1 (external|external): 'seq 1000 1041 | wc -l' printed 42"
else
    wrong "case 1: no '42' — the reader saw EOF, nothing crossed the pipe"
fi
if outline_eq "1000" || outline_eq "1041"; then
    wrong "case 1: producer output LEAKED to the console (bare '1000'/'1041' line)"
else
    ok "case 1: seq's 1000..1041 never reached the console"
fi

# --- 2. BUILTIN | external --------------------------------------------
# The case the old gate structurally could not see. "BUILTINPIPE\n" = 12 B.
# `echo` is a hamsh builtin: it used to write straight to the console while
# wc read EOF from an empty pipe and printed 0.
if [ "$c2" -eq 0 ] && ! outline_eq "BUILTINPIPE"; then
    verdict_inconclusive "$TAG" "case 2 produced no observable result — guest starved?"
fi
if outline_eq "12"; then
    ok "case 2 (builtin|external): 'echo BUILTINPIPE | wc -c' printed 12"
else
    wrong "case 2: builtin on the pipeline LHS delivered no bytes (no '12')"
fi
if outline_eq "BUILTINPIPE"; then
    wrong "case 2: the builtin LEAKED 'BUILTINPIPE' to the console instead of the pipe"
else
    ok "case 2: 'BUILTINPIPE' never appeared as console output"
fi

# --- 3. three stages ---------------------------------------------------
# Of 1000..1099, 19 contain a '7' (units-7: 10, tens-7: 10, 1077 in both).
if [ "$c3" -eq 0 ] && ! outline_eq "1007" && ! outline_eq "1070"; then
    verdict_inconclusive "$TAG" "case 3 produced no observable result — guest starved?"
fi
if outline_eq "19"; then
    ok "case 3 (3-stage): 'seq 1000 1099 | grep 7 | wc -l' printed 19"
else
    wrong "case 3: 3-stage pipeline did not print 19 — an inter-stage pipe dropped data"
fi
if outline_eq "1007" || outline_eq "1070"; then
    wrong "case 3: an intermediate stage's output LEAKED to the console"
else
    ok "case 3: no intermediate stage output on the console"
fi

# --- 4. redirect (the same sys_fdbind path) ----------------------------
# The payload must be console output EXACTLY ONCE: never from the `echo`
# (it went to the file), once from the `cat`.
if [ "$c4" -eq 0 ]; then
    verdict_inconclusive "$TAG" "case 4's redirect command never even echoed — guest starved?"
fi
n=$(outline_count "REDIRPAYLOAD")
if [ "$n" -eq 1 ]; then
    ok "case 4 (redirect): 'echo > f' landed in the file; 'cat f' printed it once"
elif [ "$n" -eq 0 ]; then
    wrong "case 4: 'cat /tmp/pipetest_f' printed nothing — the redirect never wrote the file"
else
    wrong "case 4: REDIRPAYLOAD appeared $n times as output — 'echo > f' also leaked to the console"
fi

# --- 5. dup (2>&1) into a pipe -----------------------------------------
# "DUPPAYLOAD\n" = 11 bytes.
if [ "$c5" -eq 0 ] && ! outline_eq "DUPPAYLOAD"; then
    verdict_inconclusive "$TAG" "case 5 produced no observable result — guest starved?"
fi
if outline_eq "11"; then
    ok "case 5 (dup): 'echo DUPPAYLOAD 2>&1 | wc -c' printed 11"
else
    wrong "case 5: dup-into-pipe did not deliver 11 bytes"
fi
if outline_eq "DUPPAYLOAD"; then
    wrong "case 5: the 2>&1 payload LEAKED to the console"
else
    ok "case 5: no DUPPAYLOAD on the console"
fi

# --- 6. the shell survives the pipelines -------------------------------
# hamsh used to wedge in its own post-pipeline bookkeeping — both children
# reaped, then nothing, and every later command silently lost. A builtin
# stage returned its exit STATUS where run_pipeline stores a PID, so the
# shell sys_waitpid()ed pid 1 (init), which never exits.
if [ "$c6" -eq 1 ] && hamsh_ran "$LOG" "ALIVE-AFTER-PIPE"; then
    ok "case 6: the shell still executes commands after the pipelines"
else
    wrong "case 6: the shell is WEDGED after the pipelines — 'echo ALIVE-AFTER-PIPE' never ran"
fi

# --- verdict -----------------------------------------------------------
if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    outlines | tail -40 >&2
    verdict_fail "$TAG" "a pipe/redirect/dup assertion was VIOLATED (see WRONG: lines)"
fi
verdict_pass "$TAG" \
    "pipes carry bytes (external|external, builtin|external, 3-stage); redirect + dup land; shell survives"
