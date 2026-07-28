#!/usr/bin/env bash
# scripts/test_hamsh_semicolon.sh — hamsh statement-LIST gate.
#
# WHAT THIS ASSERTS (and why it exists)
#
# A `;`-chained (and newline-separated) statement list must run EVERY
# statement, not just the first, and `&&`/`||` must short-circuit on the
# controlling status. The load-bearing case is a list of EXTERNAL
# commands:
#
#     /bin/echo A ; /bin/echo B      -> A AND B
#
# A QA probe reported this printing only `A` (the trailing statement
# "dropped"), echoing the older QA-N27 note. This gate pins the real
# behaviour so the class of bug — a statement-list loop that bails after
# the first command, or an external-exec path that conflates a child's
# exit status with a block-stop signal — cannot regress silently.
#
# ROOT-CAUSE NOTE (read before "fixing" a red here)
#
# The "drops the trailing statement" SYMPTOM was traced to the
# pre-existing SMP>=2 scheduler wedge, NOT to hamsh's statement handling:
# under -smp 2 the shell wedges in its post-external foreground-wait
# (launch_foreground_pid -> sys_waitpid_jc + sys_yield ->
# kernel/sched/core.ad::yield_to_others) after the FIRST external command
# exits, so NO later statement runs — and this reproduces for a single
# external on its own line (no `;` involved at all). hamsh's `;` / `&&` /
# `||` / mixed-list semantics are CORRECT; verified here under -smp 1,
# where the scheduler wedge does not fire. See scripts/test_pipe.sh's
# header for the same finding and the same -smp 1 workaround; the wedge
# itself is kernel-scope (cf. the #413 steal-window race).
#
# FIXED: the wedge was a recursive rq-lock self-deadlock in schedule()'s BSP
# idle-loop (it re-acquired rq_locks[0] without releasing the outer hold) — see
# kernel/sched/core.ad and scripts/test_smp2_foreground_external.sh. This gate is
# flipped BACK to -smp ${HAMNIX_TEST_SMP:-2} to prove the fix on the exact path.
#
# This gate runs the guest at -smp ${HAMNIX_TEST_SMP:-2}. It exercises
# the exact parse_program / exec_block / run_one_command_x / spawn path a
# statement list uses; a genuine statement-list regression (e.g.
# exec_block returning after the first ND_CMD) reds it even at -smp 1.
#
# ASSERTIONS (every positive marker is a UNIQUE token, matched only as
# genuine command OUTPUT via scripts/_hamsh_log.sh, never the editor's
# input echo):
#   1. external ;     /bin/echo SEMIEXT_A ; /bin/echo SEMIEXT_B  -> BOTH
#   2. builtin  ;     echo SEMIBLT_A ; echo SEMIBLT_B            -> BOTH
#   3. mixed 3-way    echo MIXA ; /bin/echo MIXB ; echo MIXC     -> ALL 3
#   4. && stops on failure, `;` after still runs
#                     /bin/false && /bin/echo ANDBAD ; /bin/echo ANDGOOD
#                     -> ANDBAD ABSENT, ANDGOOD PRESENT
#   5. || runs rhs on failure
#                     /bin/false || /bin/echo ORGOOD             -> ORGOOD
#   6. && runs rhs on success
#                     /bin/true && /bin/echo ANDOK               -> ANDOK
#
# VERDICTS (scripts/_verdict.sh, docs/TEST_VERDICTS.md)
#   PASS         (0)   every assertion was OBSERVED to hold
#   FAIL         (1)   an assertion was OBSERVED to be violated (a trailing
#                      statement dropped, or a short-circuit not honoured)
#   INCONCLUSIVE (125) never got far enough to observe: build failed, boot
#                      never reached the shell, the feeder never synced, or
#                      the guest was starved under host load
set -uo pipefail
# The guest's stdin is a FIFO; once QEMU exits, a further write raises
# SIGPIPE which would kill this script before it prints its verdict.
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_log.sh"
# _hamsh_drive.sh sources _kernel_iso.sh (installs the binshim that turns
# `-kernel <elf64>` into a GRUB-ISO boot) and gives us the load-adaptive
# marker-wait serial driver (hamsh_boot / _wait_boot / _sync / _send_await).
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG="test_hamsh_semicolon"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
export HAMNIX_TEST_SMP="${HAMNIX_TEST_SMP:-2}"   # -smp 2: the wedge is FIXED (below)
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[$TAG] (1/3) Build userland + kernel with hamsh as /init"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user.sh failed"
bash scripts/build_modules.sh >/dev/null 2>&1 || true
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs.py failed"

LOG=$(mktemp)
# From here on, any exit must put /init back (the initramfs currently has
# hamsh as /init) and reap our QEMU (armed by hamsh_boot's HD_QEMU_PID).
restore() {
    hamsh_shutdown 2>/dev/null || true
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap restore EXIT

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null 2>&1 || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[$TAG] (2/3) Boot and drive hamsh (-smp $HAMNIX_TEST_SMP)"
hamsh_boot "$LOG" "$ELF"

hamsh_wait_boot "[hamsh:stage-07] loop-enter" "$BOOT_WAIT" || {
    tail -30 "$LOG" | strings >&2
    verdict_inconclusive "$TAG" "hamsh never reached its interactive loop in ${BOOT_WAIT}s"
}
hamsh_sync 120 || {
    tail -30 "$LOG" | strings >&2
    verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"
}

echo "[$TAG] (3/3) Drive each statement-list case to its own output"
# Each command is sent ONCE (post-sync the readline is provably consuming
# stdin) and waited on its OWN observable effect, so it costs exactly as
# long as the starved guest needs and no longer.
c1=0; c2=0; c3=0; c4=0; c5=0; c6=0
hamsh_send_await '/bin/echo SEMIEXT_A ; /bin/echo SEMIEXT_B' 'SEMIEXT_B' "$CMD_WAIT" && c1=1
hamsh_send_await 'echo SEMIBLT_A ; echo SEMIBLT_B'           'SEMIBLT_B' "$CMD_WAIT" && c2=1
hamsh_send_await 'echo MIXA ; /bin/echo MIXB ; echo MIXC'    'MIXC'      "$CMD_WAIT" && c3=1
hamsh_send_await '/bin/false && /bin/echo ANDBAD ; /bin/echo ANDGOOD' \
                                                             'ANDGOOD'   "$CMD_WAIT" && c4=1
hamsh_send_await '/bin/false || /bin/echo ORGOOD'            'ORGOOD'    "$CMD_WAIT" && c5=1
hamsh_send_await '/bin/true && /bin/echo ANDOK'              'ANDOK'     "$CMD_WAIT" && c6=1
hamsh_send 'exit'
sleep 2

# Assertions look ONLY at genuine command output (hamsh_out_eq drops any
# line carrying a shell prompt, i.e. the editor echoing the typed line).
fail=0
wrong() { echo "[$TAG] WRONG: $*" >&2; fail=1; }
ok()    { echo "[$TAG] ok: $*"; }
out_eq() { hamsh_out_eq "$LOG" "$1"; }

# --- 1. external ; chain — the reported case --------------------------
if [ "$c1" -eq 0 ] && ! out_eq "SEMIEXT_A"; then
    verdict_inconclusive "$TAG" "case 1 produced no observable result within ${CMD_WAIT}s — guest starved?"
fi
if out_eq "SEMIEXT_A"; then ok "case 1: first external ran (SEMIEXT_A)"
else wrong "case 1: even the FIRST external produced no output"; fi
if out_eq "SEMIEXT_B"; then ok "case 1: TRAILING external ran (SEMIEXT_B) — no drop"
else wrong "case 1: '/bin/echo A ; /bin/echo B' DROPPED the trailing external (no SEMIEXT_B)"; fi

# --- 2. builtin ; chain -----------------------------------------------
if [ "$c2" -eq 0 ] && ! out_eq "SEMIBLT_A"; then
    verdict_inconclusive "$TAG" "case 2 produced no observable result — guest starved?"
fi
if out_eq "SEMIBLT_A" && out_eq "SEMIBLT_B"; then ok "case 2: builtin ; chain ran both"
else wrong "case 2: builtin ; chain dropped a statement (SEMIBLT_A/SEMIBLT_B)"; fi

# --- 3. mixed 3-way ---------------------------------------------------
if [ "$c3" -eq 0 ] && ! out_eq "MIXA"; then
    verdict_inconclusive "$TAG" "case 3 produced no observable result — guest starved?"
fi
if out_eq "MIXA" && out_eq "MIXB" && out_eq "MIXC"; then ok "case 3: mixed builtin/external 3-way ran all three"
else wrong "case 3: mixed 3-way list dropped a statement (MIXA/MIXB/MIXC)"; fi

# --- 4. && short-circuits on failure; the following ; still runs ------
if [ "$c4" -eq 0 ] && ! out_eq "ANDGOOD"; then
    verdict_inconclusive "$TAG" "case 4 produced no observable result — guest starved?"
fi
if out_eq "ANDBAD"; then wrong "case 4: && did NOT short-circuit — ANDBAD ran after /bin/false"
else ok "case 4: && short-circuited (ANDBAD absent)"; fi
if out_eq "ANDGOOD"; then ok "case 4: the ; statement after the && chain still ran (ANDGOOD)"
else wrong "case 4: the ; statement after a failed && chain was DROPPED (no ANDGOOD)"; fi

# --- 5. || runs the rhs on failure ------------------------------------
if [ "$c5" -eq 0 ] && ! out_eq "ORGOOD"; then
    verdict_inconclusive "$TAG" "case 5 produced no observable result — guest starved?"
fi
if out_eq "ORGOOD"; then ok "case 5: || ran the rhs after /bin/false (ORGOOD)"
else wrong "case 5: || did not run its rhs after a failing lhs (no ORGOOD)"; fi

# --- 6. && runs the rhs on success ------------------------------------
if [ "$c6" -eq 0 ] && ! out_eq "ANDOK"; then
    verdict_inconclusive "$TAG" "case 6 produced no observable result — guest starved?"
fi
if out_eq "ANDOK"; then ok "case 6: && ran the rhs after /bin/true (ANDOK)"
else wrong "case 6: && did not run its rhs after a succeeding lhs (no ANDOK)"; fi

# --- verdict ----------------------------------------------------------
if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -40 >&2
    verdict_fail "$TAG" "a statement-list assertion was VIOLATED (see WRONG: lines)"
fi
verdict_pass "$TAG" \
    "; chains run every statement (external, builtin, mixed); && / || short-circuit correctly"
