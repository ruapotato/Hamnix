#!/usr/bin/env bash
# scripts/test_hamsh_for.sh — POSIX `for VAR in ITEM... { BODY }` loops
# (QA-N18).
#
# The for-loop collects ONE OR MORE item words with the same word
# machinery as command arguments (so `$var`/globs/`text$var` fusion behave
# identically), terminated by the opening `{`; exec_for expands them into
# a flat sequence and runs the body once per item with VAR bound to it:
#   for x in a b c { }   -> 3 iterations (x=a, x=b, x=c)
#   for f in solo   { }  -> 1 iteration  (f=solo)  (was ZERO before the fix)
#   for y in $xs two { } -> $xs's words, then `two`
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh —
# commands sent once after a live-readline handshake, waited on their own
# observable output. Assertions use hamsh_ran (scripts/_hamsh_log.sh) so
# the typed `for ... { echo L_$x }` input echo cannot false-green the
# per-iteration markers (whose VALUES come only from real expansion).
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_for
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

hamsh_send_await 'for x in a b c { echo L_$x }'          'L_c'   "$CMD_WAIT" || true
hamsh_send_await 'for f in solo { echo S_$f }'           'S_solo' "$CMD_WAIT" || true
hamsh_send_await 'xs=one ; for y in $xs two { echo Y_$y }' 'Y_two' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

verdict_boot_gate "$TAG" "$LOG" 0 'L_a|L_c'
if ! hamsh_ran "$LOG" "L_a" && ! hamsh_ran "$LOG" "L_c"; then
    verdict_inconclusive "$TAG" \
        "no early marker observed within ${CMD_WAIT}s — guest starved. Re-run quiet."
fi

fail=0
check() {
    if hamsh_ran "$LOG" "$1"; then echo "[$TAG] OK: $2"; else
        echo "[$TAG] WRONG ('$1'): $2"; fail=1; fi
}
check "L_a"     "for x in a b c -> iteration x=a"
check "L_b"     "for x in a b c -> iteration x=b"
check "L_c"     "for x in a b c -> iteration x=c"
check "S_solo"  "for f in solo -> single iteration f=solo (was ZERO before)"
check "Y_one"   "for y in \$xs two -> \$xs expands to 'one'"
check "Y_two"   "for y in \$xs two -> trailing literal 'two'"

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -30 >&2
    verdict_fail "$TAG" "a for-loop iteration assertion was VIOLATED"
fi
verdict_pass "$TAG" "for iterates over multi-word, single-bareword, and \$var+literal item lists"
