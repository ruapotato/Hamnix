#!/usr/bin/env bash
# scripts/test_hamsh_assign.sh — POSIX `VAR=value` assignment syntax.
#
# A `=` GLUED to the LHS name (no surrounding space) lexes as
# OP_ASSIGN_LIT and its RHS is a LITERAL command word, not an expression
# — so `/`, `:`, `.` are literal, `'...'` is literal, `"..."` still
# interpolates `$vars`, and `$VAR` expands. A SPACED `=` (`n = 10 * 4`)
# keeps arithmetic-expression semantics. `export VAR=value` assigns AND
# exports. An arg-position glued `=` (`echo a=b`) is a LITERAL word, not
# an assignment (QA-N7/N13/N16 regression guards).
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh —
# commands sent once after a live-readline handshake, waited on their own
# observable output. Assertions use hamsh_ran (scripts/_hamsh_log.sh): the
# arg-position cases (`echo GOT_AB a=b`) print text byte-identical to the
# typed input, so dropping the prompt-echo line is REQUIRED to prove the
# echo actually ran rather than matching the keystroke echo.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_assign
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

# Each case is SELF-CONTAINED on ONE line (assign ; echo) and waited on
# its own read-back marker.
hamsh_send_await 'DIR=/home/live ; echo GOT_DIR $DIR'            'GOT_DIR /home/live'        "$CMD_WAIT" || true
hamsh_send_await 'P=/bin:/sbin:/usr/bin ; echo GOT_P $P'        'GOT_P /bin:/sbin:/usr/bin' "$CMD_WAIT" || true
hamsh_send_await 'export EV=exported_val ; echo GOT_EV $EV'     'GOT_EV exported_val'       "$CMD_WAIT" || true
hamsh_send_await 'DIR=/home/live ; Q="dir is $DIR" ; echo GOT_Q $Q' 'GOT_Q dir is /home/live' "$CMD_WAIT" || true
hamsh_send_await "L='raw dollar' ; echo GOT_L \$L"             'GOT_L raw dollar'          "$CMD_WAIT" || true
hamsh_send_await 'n = 10 * 4 + 2 ; echo GOT_N $n'              'GOT_N 42'                  "$CMD_WAIT" || true
hamsh_send_await 'echo GOT_AB a=b'                             'GOT_AB a=b'                "$CMD_WAIT" || true
hamsh_send_await 'V=hello ; echo GOT_PV p=$V'                  'GOT_PV p=hello'            "$CMD_WAIT" || true
hamsh_send_await 'W=/x/y ; echo GOT_W $W'                      'GOT_W /x/y'                "$CMD_WAIT" || true
hamsh_send_await 'export E=z ; echo GOT_E got=$E'             'GOT_E got=z'               "$CMD_WAIT" || true
hamsh_send_await 'echo GOT_XYZ x=y=z'                         'GOT_XYZ x=y=z'             "$CMD_WAIT" || true
hamsh_send_await 'echo GOT_PQR p:q=r'                         'GOT_PQR p:q=r'             "$CMD_WAIT" || true
hamsh_send_await 'echo GOT_EQX =x'                            'GOT_EQX =x'                "$CMD_WAIT" || true
hamsh_send_await 'echo GOT_EQ3X ===x'                        'GOT_EQ3X ===x'             "$CMD_WAIT" || true
hamsh_send_await 'echo GOT_ABC3 abc==='                      'GOT_ABC3 abc==='           "$CMD_WAIT" || true
hamsh_send_await 'echo GOT_FOO2 foo=='                       'GOT_FOO2 foo=='            "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

verdict_boot_gate "$TAG" "$LOG" 0 'GOT_DIR /home/live|GOT_P /bin'
if ! hamsh_ran "$LOG" "GOT_DIR /home/live" && ! hamsh_ran "$LOG" "GOT_P /bin"; then
    verdict_inconclusive "$TAG" \
        "no early marker observed within ${CMD_WAIT}s — guest starved. Re-run quiet."
fi

fail=0
check() {
    if hamsh_ran "$LOG" "$1"; then echo "[$TAG] OK: $2"; else
        echo "[$TAG] WRONG ('$1'): $2"; fail=1; fi
}
check "GOT_DIR /home/live"          "VAR=/path is a literal string (no division)"
check "GOT_P /bin:/sbin:/usr/bin"   "PATH-list RHS with glued ':' is literal"
check "GOT_EV exported_val"         "export VAR=value assigns the value"
check "GOT_Q dir is /home/live"     "double-quoted RHS interpolates \$vars"
check "GOT_L raw dollar"            "single-quoted RHS is literal (no interp)"
check "GOT_N 42"                    "spaced '=' still evaluates arithmetic"
check "GOT_AB a=b"                  "arg-position glued '=' is a literal word (echo a=b)"
check "GOT_PV p=hello"              "arg-position glued '=' expands \$var in RHS"
check "GOT_W /x/y"                  "leading VAR=value assignment still works"
check "GOT_E got=z"                 "export VAR=value + arg-position got=\$E"
check "GOT_XYZ x=y=z"               "arg-position chained glued '=' (x=y=z) is one word"
check "GOT_PQR p:q=r"               "arg-position glued ':'+'=' (p:q=r) is one word"
check "GOT_EQX =x"                  "leading '=' word (=x) is a literal arg (QA-N13)"
check "GOT_EQ3X ===x"               "multiple leading '=' (===x) is a literal arg (QA-N13)"
check "GOT_ABC3 abc==="             "trailing '='-run (abc===) is a literal arg (QA-N16)"
check "GOT_FOO2 foo=="              "trailing '='-run (foo==) is a literal arg (QA-N16)"

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -40 >&2
    verdict_fail "$TAG" "an assignment / arg-position glued-'=' assertion was VIOLATED"
fi
verdict_pass "$TAG" "VAR=value literal RHS, quoting, export, arithmetic, and arg-position glued '=' all correct"
