#!/usr/bin/env bash
# scripts/test_hamsh_expand.sh — QA-N20: UNQUOTED word text glued to a
# `$var` expansion (no whitespace) must fuse into ONE argv word.
#
# The lexer tracks token adjacency (tok_glued) and fuses a run of GLUED
# word-continuation tokens into a single ND_ARGCAT argv word — the
# `$`-adjacency analog of the QA-N7 `=`-fusion. Glue works on EITHER side
# and chained: `pre$s`, `$s.txt`, `$s$s`, `p/$s/q`. SPACE-separated args
# stay separate (`echo a $s b` -> three words).
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh —
# commands sent once after a live-readline handshake, waited on their own
# observable output. Assertions use hamsh_ran (scripts/_hamsh_log.sh); the
# expected concatenation VALUES (Kpreworld, worldworld, …) come only from
# real expansion, never from the typed input echo.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_expand
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

hamsh_send_await 's=world ; echo GOT_PRE Kpre$s'  'GOT_PRE Kpreworld'   "$CMD_WAIT" || true
hamsh_send_await 's=world ; echo GOT_MID K$s.txt' 'GOT_MID Kworld.txt'  "$CMD_WAIT" || true
hamsh_send_await 's=world ; echo GOT_DBL $s$s'    'GOT_DBL worldworld'  "$CMD_WAIT" || true
hamsh_send_await 's=world ; echo GOT_PATH p/$s/q' 'GOT_PATH p/world/q'  "$CMD_WAIT" || true
hamsh_send_await 's=world ; echo GOT_SEP a $s b'  'GOT_SEP a world b'   "$CMD_WAIT" || true
hamsh_send_await 's=world ; echo GOT_DQ "Kq$s"'   'GOT_DQ Kqworld'      "$CMD_WAIT" || true
hamsh_send_await 's=world ; echo GOT_BARE $s'     'GOT_BARE world'      "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

verdict_boot_gate "$TAG" "$LOG" 0 'GOT_PRE Kpreworld|GOT_BARE world'
if ! hamsh_ran "$LOG" "GOT_PRE Kpreworld" && ! hamsh_ran "$LOG" "GOT_BARE world"; then
    verdict_inconclusive "$TAG" \
        "no early marker observed within ${CMD_WAIT}s — guest starved. Re-run quiet."
fi

fail=0
check() {
    if hamsh_ran "$LOG" "$1"; then echo "[$TAG] OK: $2"; else
        echo "[$TAG] WRONG ('$1'): $2"; fail=1; fi
}
check "GOT_PRE Kpreworld"    "text glued before \$var concatenates (Kpre\$s)"
check "GOT_MID Kworld.txt"   "\$var glued to trailing text concatenates (K\$s.txt)"
check "GOT_DBL worldworld"   "two glued \$vars concatenate (\$s\$s)"
check "GOT_PATH p/world/q"   "\$var glued between path segments (p/\$s/q)"
check "GOT_SEP a world b"    "space-separated args stay three words (a \$s b)"
check "GOT_DQ Kqworld"       "double-quoted \"Kq\$s\" still concatenates"
check "GOT_BARE world"       "bare \$s alone expands"

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -30 >&2
    verdict_fail "$TAG" "a \$var glue/concatenation assertion was VIOLATED"
fi
verdict_pass "$TAG" "unquoted text/\$var glue fuses into one argv word; space-separated stays split"
