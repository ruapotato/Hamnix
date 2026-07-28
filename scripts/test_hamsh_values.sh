#!/usr/bin/env bash
# scripts/test_hamsh_values.sh — HAMSH_SPEC §18 stage 2 acceptance.
#
# Typed values + list interpolation (§3):
#   * args = ["A1","A2"]; echo L $args R -> exactly two argv entries (L A1 A2 R)
#   * a value containing spaces is ONE argument (no word-splitting)
#   * int / string values are distinct and arithmetic / concat / len() work
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh —
# commands sent once after a live-readline handshake, waited on their own
# observable output. Assertions use hamsh_out_eq (scripts/_hamsh_log.sh):
# each expected result is matched only as a WHOLE genuine command-output
# line, never the editor's input echo of the typed command.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_values
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

hamsh_send 'args = ["A1", "A2"]'
hamsh_send_await 'echo L $args R'          'L A1 A2 R'    "$CMD_WAIT" || true
hamsh_send 'phrase = "two words"'
hamsh_send_await 'echo X $phrase Y'        'X two words Y' "$CMD_WAIT" || true
hamsh_send 'n = 10 * 4 + 2'
hamsh_send_await 'echo SUM $n'             'SUM 42'       "$CMD_WAIT" || true
hamsh_send 'g = "ham" + "nix"'
hamsh_send_await 'echo CAT $g'             'CAT hamnix'   "$CMD_WAIT" || true
hamsh_send_await 'echo LEN ${ len(args) }' 'LEN 2'        "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

verdict_boot_gate "$TAG" "$LOG" 0 'L A1 A2 R|SUM 42'
if ! hamsh_out_eq "$LOG" "L A1 A2 R" && ! hamsh_out_eq "$LOG" "SUM 42"; then
    verdict_inconclusive "$TAG" \
        "no early marker observed within ${CMD_WAIT}s — guest starved. Re-run quiet."
fi

fail=0
check() {
    if hamsh_out_eq "$LOG" "$1"; then echo "[$TAG] OK: $2"; else
        echo "[$TAG] WRONG (no output line == '$1'): $2"; fail=1; fi
}
check "L A1 A2 R"      "list interpolation: each element is one arg"
check "X two words Y"  "a value with spaces stays one argument"
check "SUM 42"         "integer arithmetic"
check "CAT hamnix"     "string concatenation with +"
check "LEN 2"          "len() of a list"

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -30 >&2
    verdict_fail "$TAG" "a typed-value / interpolation assertion was VIOLATED"
fi
verdict_pass "$TAG" "list interpolation, no re-splitting, arithmetic, concat, len() all correct"
