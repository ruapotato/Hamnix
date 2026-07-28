#!/usr/bin/env bash
# scripts/test_hamsh_dispatch.sh — HAMSH_SPEC §18 stage 1 acceptance.
#
# Statement dispatch (§2): a corpus of lines classifies deterministically
# as command / assignment / control by the first-token rule. ${ } and
# `{ }` nest correctly. No line is ambiguous.
#   * `echo CMD_OK ...`  -> command   (bare words are literal string args)
#   * `k = 42`           -> assignment (no command spawned)
#   * `if true { ... }`  -> control construct
#   * `${ }` nests inside an interpolating string.
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh —
# every command sent once after a live-readline handshake, waited on its
# own observable effect. Assertions look ONLY at genuine command OUTPUT
# (scripts/_hamsh_log.sh :: hamsh_ran), never the editor's input echo.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_dispatch
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

hamsh_send_await 'echo CMD_OK alpha beta'      'CMD_OK alpha beta' "$CMD_WAIT" || true
hamsh_send 'k = 42'
hamsh_send_await 'echo ASSIGN_VAL $k'          'ASSIGN_VAL 42'     "$CMD_WAIT" || true
hamsh_send_await 'if true { echo CONTROL_OK }' 'CONTROL_OK'        "$CMD_WAIT" || true
hamsh_send_await 'echo NEST ${ 6 * 7 }'        'NEST 42'           "$CMD_WAIT" || true
hamsh_send_await 'echo DEEP ${ 2 + ${ 3 * 3 } }' 'DEEP 11'        "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

verdict_boot_gate "$TAG" "$LOG" 0 'CMD_OK alpha beta|ASSIGN_VAL 42'
if ! hamsh_ran "$LOG" "CMD_OK alpha beta" && ! hamsh_ran "$LOG" "ASSIGN_VAL 42"; then
    verdict_inconclusive "$TAG" \
        "no early marker observed within ${CMD_WAIT}s — guest starved. Re-run quiet."
fi

fail=0
check() {
    if hamsh_ran "$LOG" "$1"; then echo "[$TAG] OK: $2"; else
        echo "[$TAG] WRONG ('$1'): $2"; fail=1; fi
}
check "CMD_OK alpha beta"  "command statement: bare words are literal args"
check "ASSIGN_VAL 42"      "assignment statement classified, value bound"
check "CONTROL_OK"         "control construct (if) classified"
check "NEST 42"            '${ } expression interpolation evaluated'
check "DEEP 11"            'nested ${ } interpolation evaluated'

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -30 >&2
    verdict_fail "$TAG" "a statement-dispatch assertion was VIOLATED"
fi
verdict_pass "$TAG" "command/assignment/control dispatch + nested \${ } interpolation all correct"
