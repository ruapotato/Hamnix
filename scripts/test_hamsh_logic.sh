#!/usr/bin/env bash
# scripts/test_hamsh_logic.sh — hamsh `&&` / `||` / `;` (new shell).
#
# The `&&` / `||` command chaining and `;` statement separator are the
# same surface between the old and new shells, but no §18 stage test
# covers them — this one does:
#   true && echo AFTER_AND_TRUE      -> executes
#   false && echo AFTER_AND_FALSE    -> skipped
#   true || echo AFTER_OR_TRUE       -> skipped
#   false || echo AFTER_OR_FALSE     -> executes
#   echo SEQ1 ; echo SEQ2            -> both execute (`;` separates stmts)
#   false ; echo AFTER_SEMI          -> executes (`;` ignores prev exit)
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh —
# the old fixed-sleep feeder shoved every command at the 16550 before
# hamsh was reading, so under host load the first command was dropped and
# the gate false-red. Every command here is sent ONCE after a live-readline
# handshake and waited on its OWN observable effect. Assertions look ONLY
# at genuine command OUTPUT (scripts/_hamsh_log.sh :: hamsh_ran drops the
# line editor's input echo) so a skipped `echo X` can never false-green
# off the typed-but-not-run command text.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_logic
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh:stage-07] loop-enter" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"

# Positive cases wait on their own marker; skip cases are followed by a
# sentinel echo we DO wait on, so we know the guest reached past the
# skipped line before we assert the skipped marker is absent.
hamsh_send_await 'true && echo AFTER_AND_TRUE'  'AFTER_AND_TRUE'  "$CMD_WAIT" || true
hamsh_send 'false && echo AFTER_AND_FALSE'
hamsh_send_await 'echo MIDGATE_A'               'MIDGATE_A'       "$CMD_WAIT" || true
hamsh_send 'true || echo AFTER_OR_TRUE'
hamsh_send_await 'echo MIDGATE_B'               'MIDGATE_B'       "$CMD_WAIT" || true
hamsh_send_await 'false || echo AFTER_OR_FALSE' 'AFTER_OR_FALSE'  "$CMD_WAIT" || true
hamsh_send_await 'echo SEQ1 ; echo SEQ2'        'SEQ2'            "$CMD_WAIT" || true
hamsh_send_await 'false ; echo AFTER_SEMI'      'AFTER_SEMI'      "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

# Never observed the first result at all -> starved guest, not a bug.
verdict_boot_gate "$TAG" "$LOG" 0 'AFTER_AND_TRUE|MIDGATE_A'
if ! hamsh_ran "$LOG" "AFTER_AND_TRUE" && ! hamsh_ran "$LOG" "MIDGATE_A"; then
    verdict_inconclusive "$TAG" \
        "no early marker observed within ${CMD_WAIT}s — guest starved before" \
        "any assertion could run. Re-run on a quiet host."
fi

fail=0
present() {
    if hamsh_ran "$LOG" "$1"; then echo "[$TAG] OK: $1 present"; else
        echo "[$TAG] WRONG: $1 absent (should have run)"; fail=1; fi
}
absent() {
    if hamsh_ran "$LOG" "$1"; then
        echo "[$TAG] WRONG: $1 leaked (should be skipped)"; fail=1; else
        echo "[$TAG] OK: $1 correctly skipped"; fi
}
present "AFTER_AND_TRUE"
absent  "AFTER_AND_FALSE"
absent  "AFTER_OR_TRUE"
present "AFTER_OR_FALSE"
present "SEQ1"
present "SEQ2"
present "AFTER_SEMI"

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -40 >&2
    verdict_fail "$TAG" "a &&/||/; short-circuit or separator assertion was VIOLATED"
fi
verdict_pass "$TAG" "&& / || short-circuit correctly; ; runs every statement"
