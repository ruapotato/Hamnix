#!/usr/bin/env bash
# scripts/test_hamsh_if.sh — hamsh `if { } else { }` (new shell).
#
# Single-line interactive C-style brace blocks (HAMSH_SPEC §5):
#   1. `if 1 > 0 { echo IF_TRUE_PATH }`      -> IF_TRUE_PATH appears
#   2. `if 1 > 2 { echo IF_FALSE_PATH }`     -> IF_FALSE_PATH must NOT appear
#   3. `if 0 > 1 { echo IFE_THEN } else { echo IFE_ELSE }` -> IFE_ELSE only
#   4. `echo POST_IF`                        -> shell survived
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh —
# commands sent once after a live-readline handshake, waited on their own
# observable output. Assertions use hamsh_ran (scripts/_hamsh_log.sh) so a
# skipped branch's `echo X` can never false-green off the typed input echo.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_if
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

hamsh_send_await 'if 1 > 0 { echo IF_TRUE_PATH }' 'IF_TRUE_PATH' "$CMD_WAIT" || true
hamsh_send 'if 1 > 2 { echo IF_FALSE_PATH }'
hamsh_send_await 'echo MIDGATE_IF' 'MIDGATE_IF' "$CMD_WAIT" || true
hamsh_send_await 'if 0 > 1 { echo IFE_THEN } else { echo IFE_ELSE }' 'IFE_ELSE' "$CMD_WAIT" || true
hamsh_send_await 'echo POST_IF' 'POST_IF' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

verdict_boot_gate "$TAG" "$LOG" 0 'IF_TRUE_PATH|MIDGATE_IF'
if ! hamsh_ran "$LOG" "IF_TRUE_PATH" && ! hamsh_ran "$LOG" "MIDGATE_IF"; then
    verdict_inconclusive "$TAG" \
        "no early marker observed within ${CMD_WAIT}s — guest starved. Re-run quiet."
fi

fail=0
if hamsh_ran "$LOG" "IF_TRUE_PATH"; then echo "[$TAG] OK: if-true body executed"; else
    echo "[$TAG] WRONG: if-true body did not run"; fail=1; fi
if hamsh_ran "$LOG" "IF_FALSE_PATH"; then
    echo "[$TAG] WRONG: if-false body leaked (should be skipped)"; fail=1; else
    echo "[$TAG] OK: if-false body correctly skipped"; fi
if hamsh_ran "$LOG" "IFE_ELSE" && ! hamsh_ran "$LOG" "IFE_THEN"; then
    echo "[$TAG] OK: false condition took the else branch"; else
    echo "[$TAG] WRONG: if/else branch selection wrong"; fail=1; fi
if hamsh_ran "$LOG" "POST_IF"; then echo "[$TAG] OK: shell survived the if blocks"; else
    echo "[$TAG] WRONG: shell did not survive (POST_IF absent)"; fail=1; fi

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -30 >&2
    verdict_fail "$TAG" "an if/else branch-selection assertion was VIOLATED"
fi
verdict_pass "$TAG" "if-true runs, if-false skips, false takes else, shell survives"
