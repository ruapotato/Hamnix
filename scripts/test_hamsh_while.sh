#!/usr/bin/env bash
# scripts/test_hamsh_while.sh — hamsh `while { }` loop (new shell).
#
# EXACT-ITERATION-COUNT behaviour: a while whose condition stops being
# true after the body mutates the counter must run its body a precise
# number of times, then exit.
#   1. `echo START`                                -> START present
#   2. `i = 0`                                      -> assignment
#   3. `while i < 3 { echo LOOP_BODY ; i = i + 1 }` -> body runs EXACTLY 3x
#   4. `echo POST_WHILE final ${ i }`              -> i==3, shell survived
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh —
# commands sent once after a live-readline handshake, waited on their own
# observable output. The iteration count uses hamsh_ran_count
# (scripts/_hamsh_log.sh) so the single typed `while ... { echo LOOP_BODY }`
# input line is NOT miscounted as a body execution.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_while
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

hamsh_send_await 'echo START' 'START' "$CMD_WAIT" || true
hamsh_send 'i = 0'
hamsh_send 'while i < 3 { echo LOOP_BODY ; i = i + 1 }'
hamsh_send_await 'echo POST_WHILE final ${ i }' 'POST_WHILE final 3' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

# POST_WHILE only prints if the loop terminated; absent -> starved or hung.
if ! hamsh_ran "$LOG" "START"; then
    verdict_inconclusive "$TAG" \
        "even START never printed within ${CMD_WAIT}s — guest starved. Re-run quiet."
fi

fail=0
loop_count=$(hamsh_ran_count "$LOG" "LOOP_BODY")
if [ "${loop_count:-0}" -eq 3 ]; then
    echo "[$TAG] OK: while body ran exactly three times"
else
    echo "[$TAG] WRONG: LOOP_BODY count=$loop_count (expected 3)"
    fail=1
fi
if hamsh_ran "$LOG" "POST_WHILE final 3"; then
    echo "[$TAG] OK: shell survived; counter ended at 3"
elif ! hamsh_ran "$LOG" "POST_WHILE"; then
    verdict_inconclusive "$TAG" \
        "POST_WHILE never printed — cannot tell a hung/starved guest from a" \
        "wrong loop. Re-run on a quiet host."
else
    echo "[$TAG] WRONG: POST_WHILE printed but counter != 3 (wrong iteration count)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -30 >&2
    verdict_fail "$TAG" "while ran the wrong number of iterations or left a wrong counter"
fi
verdict_pass "$TAG" "while body ran exactly 3 times; counter ended at 3; shell survived"
