#!/usr/bin/env bash
# scripts/test_hamsh_exceptions.sh — hamsh structured exception handling.
#
# `try` / `except` / `else` / `finally` blocks + `raise` — the Python-esque
# exception model, married to Plan 9's status+errstr convention. Every form
# is a first-class construct in BOTH the brace one-liner syntax and the
# colon-suite (indentation) syntax; the dual-syntax equivalence itself is
# guarded separately by scripts/test_hamsh_dualsyntax.sh (§N). This gate
# proves the semantics end-to-end on the GUEST:
#
#   * `raise EXPR` unwinds to the nearest enclosing try; a matching
#     `except` handles it and `as e` / the `except NAME:` shorthand binds
#     the raised value.
#   * catch-all `except:` / `except as e:` / bind-shorthand `except NAME:`.
#   * typed/filtered `except NAME as e:` — catches only a matching value
#     (equal, or "NAME:"-prefixed); a non-match re-propagates.
#   * `finally` runs on the normal, caught, AND uncaught-propagating paths.
#   * `else` runs only when the try body raised nothing.
#   * bare `raise` inside a handler RE-raises the in-flight value.
#   * exceptions propagate OUT of function calls (def) and through NESTED
#     try blocks; an uncaught one prints a report + sets nonzero status.
#   * a runtime error (a failed command's nonzero status) is catchable.
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh (a
# fixed-sleep feeder drops the first command and false-reds). Each assertion
# is made on a whole OUTPUT line whose sentinel word never appears in the
# literal typed source, so a begin-of-line grep is unambiguous.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_exceptions
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

# --- 1. catch-all + `as e` bind (brace one-liner) -------------------
hamsh_send_await 'try { raise "boom" } except e { echo E1_$e }' 'E1_boom' "$CMD_WAIT" || true
# --- 2. `except NAME:` bind shorthand (indent form) -----------------
hamsh_send 'try:'
hamsh_send '    raise "kaboom"'
hamsh_send 'except er:'
hamsh_send '    echo E2_$er'
hamsh_send ''
hamsh_send_await 'echo GATE_E2' 'GATE_E2' "$CMD_WAIT" || true
# --- 3. finally on the NORMAL path (both markers) -------------------
hamsh_send_await 'try { echo E3_TRY } finally { echo E3_FIN }' 'E3_FIN' "$CMD_WAIT" || true
# --- 4. finally on the CAUGHT path ----------------------------------
hamsh_send_await 'try { raise "x" } except { echo E4_CAUGHT } finally { echo E4_FIN }' 'E4_FIN' "$CMD_WAIT" || true
# --- 5. finally on the UNCAUGHT-propagating path (try/finally) -------
# E5_FIN prints, then the raise propagates to an uncaught-exception report.
hamsh_send_await 'try { raise "prop" } finally { echo E5_FIN }' 'E5_FIN' "$CMD_WAIT" || true
# --- 6. typed filter: match catches + binds; non-match re-propagates -
# 6a. MATCH, brace form (presence).
hamsh_send_await 'try { raise "ValueError: bad" } except ValueError as e { echo E6_$e }' 'E6_ValueError: bad' "$CMD_WAIT" || true
# 6b. MATCH, indent form (presence — the both-syntaxes coverage).
hamsh_send 'try:'
hamsh_send '    raise "KeyError: k"'
hamsh_send 'except KeyError as e:'
hamsh_send '    echo E6I_$e'
hamsh_send ''
hamsh_send_await 'echo GATE_E6I' 'GATE_E6I' "$CMD_WAIT" || true
# 6c. MISS re-propagates to the outer handler. This is an ABSENCE test
# (E6_WRONG must NOT run), so it MUST be a single physical line — a typed
# echo on a `> ` continuation line is NOT filtered by hamsh_ran and would
# false-red. Inline nested brace form keeps the echo on the `hamsh$ ` prompt.
hamsh_send_await 'try { try { raise "TypeError: nope" } except ValueError as e { echo E6_WRONG } } except as e2 { echo E6_OUTER_$e2 }' 'E6_OUTER_TypeError: nope' "$CMD_WAIT" || true
hamsh_send_await 'echo GATE_E6' 'GATE_E6' "$CMD_WAIT" || true
# --- 7. `else` runs only when nothing raised ------------------------
hamsh_send_await 'try { echo E7_TRY } else { echo E7_ELSE } finally { echo E7_FIN }' 'E7_FIN' "$CMD_WAIT" || true
hamsh_send 'try { raise "z" } except { echo E7_CX } else { echo E7_ELSENO }'
hamsh_send_await 'echo GATE_E7' 'GATE_E7' "$CMD_WAIT" || true
# --- 8. bare `raise` inside a handler RE-raises the in-flight value --
hamsh_send 'try:'
hamsh_send '    try:'
hamsh_send '        raise "reraised"'
hamsh_send '    except e:'
hamsh_send '        raise'
hamsh_send 'except e2:'
hamsh_send '    echo E8_$e2'
hamsh_send ''
hamsh_send_await 'echo GATE_E8' 'GATE_E8' "$CMD_WAIT" || true
# --- 9. exception propagates OUT of a function call -----------------
hamsh_send 'def boomfn():'
hamsh_send '    raise "fromfn"'
hamsh_send ''
hamsh_send 'try { boomfn() } except e { echo E9_$e }'
hamsh_send_await 'echo GATE_E9' 'GATE_E9' "$CMD_WAIT" || true
# --- 10. a runtime error (failed command status) is catchable -------
hamsh_send_await 'try { /bin/false } except { echo E10_CAUGHT }' 'E10_CAUGHT' "$CMD_WAIT" || true
# --- 11. an UNCAUGHT raise prints a report + sets nonzero status -----
hamsh_send_await 'raise "unhandled"' 'uncaught exception' "$CMD_WAIT" || true
hamsh_send_await 'echo E11_STATUS $status' 'E11_STATUS 1' "$CMD_WAIT" || true
# Survival sentinel — proves the shell kept its footing through all of it.
hamsh_send_await 'echo EXC_SURVIVED' 'EXC_SURVIVED' "$CMD_WAIT" || true

hamsh_send 'exit'
sleep 2

if ! hamsh_ran "$LOG" "EXC_SURVIVED"; then
    verdict_inconclusive "$TAG" \
        "the survival sentinel never printed within ${CMD_WAIT}s" \
        "— the guest was starved before the fixture ran. Re-run quiet."
fi

# ANSI/NUL/CR-stripped view: genuine command OUTPUT starts a fresh line;
# the input echo is prompt-prefixed AND still carries the literal `raise`/
# `except` source spelling, so each result line is unique to the output.
CLEAN=$(mktemp)
sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r/\n/g' "$LOG" > "$CLEAN"
ran_bol() { grep -aqE "^$1\$" "$CLEAN"; }

verdict_boot_gate "$TAG" "$LOG" 0 'E1_boom|GATE_E2'
if ! hamsh_ran "$LOG" "E1_boom" && ! hamsh_ran "$LOG" "GATE_E2"; then
    verdict_inconclusive "$TAG" \
        "no early marker observed within ${CMD_WAIT}s — guest starved. Re-run quiet."
fi

fail=0
_want() {  # <literal-line> <human description>
    local re
    re="$(printf '%s' "$1" | sed 's/[.[*+?(){}|^$\\]/\\&/g')"
    if grep -aE -q "^$re\$" "$CLEAN"; then
        echo "[$TAG] OK: $2"
    else
        echo "[$TAG] WRONG: $2 (missing output line '$1')"
        fail=1
    fi
}
_absent() {  # <marker> <human description>
    if hamsh_ran "$LOG" "$1"; then
        echo "[$TAG] WRONG: $2 ($1 leaked)"; fail=1
    else
        echo "[$TAG] OK: $2 ($1 absent)"
    fi
}

_want 'E1_boom' 'catch-all `except e` binds the raised value (brace)'
_want 'E2_kaboom' '`except NAME:` bind shorthand (indent)'
_want 'E3_TRY' 'finally normal path: try body ran'
_want 'E3_FIN' 'finally runs on the normal path'
_want 'E4_CAUGHT' 'finally caught path: except body ran'
_want 'E4_FIN' 'finally runs on the caught path'
_want 'E5_FIN' 'finally runs on the uncaught-propagating path'
_want 'E6_ValueError: bad' 'typed `except NAME as e` matches + binds (brace)'
_want 'E6I_KeyError: k' 'typed `except NAME as e` matches + binds (indent)'
_want 'E6_OUTER_TypeError: nope' 'filter miss re-propagates to the outer handler'
_absent 'E6_WRONG' 'a non-matching filter does not catch'
_want 'E7_TRY' 'else path: try body ran'
_want 'E7_ELSE' 'else runs when nothing raised'
_want 'E7_FIN' 'finally runs after else'
_want 'E7_CX' 'except still catches with an else present'
_absent 'E7_ELSENO' 'else is skipped on the exception path'
_want 'E8_reraised' 'bare `raise` re-raises the in-flight value to the outer try'
_want 'E9_fromfn' 'an exception propagates OUT of a function call'
_want 'E10_CAUGHT' 'a failed-command runtime error is catchable'
_want 'E11_STATUS 1' 'an uncaught raise sets a nonzero status'

# The uncaught-exception REPORT (a distinct diagnostic line, not a marker).
if grep -aqF "uncaught exception" "$CLEAN"; then
    echo "[$TAG] OK: an uncaught raise prints a report"
else
    echo "[$TAG] WRONG: an uncaught raise printed no report"; fail=1
fi

echo "[$TAG] OK: shell survived all exception forms (EXC_SURVIVED)"

rm -f "$CLEAN"
if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -60 >&2
    verdict_fail "$TAG" "an exception-handling assertion was VIOLATED"
fi
verdict_pass "$TAG" "try/except/else/finally + raise (catch-all, bind, typed filter, bare re-raise, propagation, uncaught report) all work"
