#!/usr/bin/env bash
# scripts/test_hamsh_papercuts.sh — hamsh interactive-error polish.
#
# A failing builtin must SHOW its diagnosis at the prompt: `cd` to a
# missing directory pulls the kernel's errstr (§16) and run_builtin
# prints `cd: <errstr>` — a bare failing builtin reports cleanly, exactly
# as a failed external prints "command not found" — and the shell
# survives to run the next command.
#
# (Arrow-key history line editing moved to scripts/test_hamsh_lineedit.sh.)
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh: the
# old fixed-sleep feeder could drop the first command under host load and
# false-red. The `cd:` error is printed BY the shell on its own output
# line (not part of any typed input), so a plain egrep of the log is
# unambiguous; the survival marker is checked as genuine command output.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_papercuts
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

hamsh_send 'cd /nope/nope/nope'
hamsh_send_await 'echo PAPERCUT_SURVIVED' 'PAPERCUT_SURVIVED' "$CMD_WAIT" || true

# --- leading-'+' argument word (tokenizer papercut) -----------------
# `find -size +6c`, `git rebase +2`, etc.: a bare word STARTING with '+'
# must lex as a plain ARGUMENT, not the '+' operator. Pre-fix hamsh died
# with "unexpected token after command" and forced the user to quote it
# as '+6c'. The genuine echo output line `PLUSARG +6c` (begin-of-line,
# distinct from the prompt-prefixed input echo) proves +6c reached the
# command intact as a literal arg.
hamsh_send_await 'echo PLUSARG +6c' 'PLUSARG' "$CMD_WAIT" || true
# The '+' OPERATOR must still work — arithmetic tokenization not regressed
# (a space-flanked '+' is the operator; only a GLUED leading '+' is a word).
hamsh_send_await 'if 3 + 4 > 6: echo PLUSOP_OK' 'PLUSOP_OK' "$CMD_WAIT" || true

hamsh_send 'exit'
sleep 2

# The survival sentinel is the observation everything hangs off; absent ->
# starved guest, not a bug.
if ! hamsh_ran "$LOG" "PAPERCUT_SURVIVED"; then
    verdict_inconclusive "$TAG" \
        "the post-error survival sentinel never printed within ${CMD_WAIT}s" \
        "— the guest was starved before the fixture ran. Re-run quiet."
fi

fail=0
# The `cd:` error text is printed by the shell on its own output line and
# is not present verbatim in the typed `cd /nope/...` input.
if grep -a -E -q "cd: .*chdir" "$LOG"; then
    echo "[$TAG] OK: failing cd surfaces the kernel errstr"
else
    echo "[$TAG] WRONG: cd error message not propagated"
    fail=1
fi
echo "[$TAG] OK: shell survived the failed builtin (PAPERCUT_SURVIVED)"

# ANSI/NUL-stripped view for begin-of-line output assertions (the genuine
# command output starts a fresh line; the input echo is prompt-prefixed).
STRIPPED="$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000')"

# Leading-'+' arg reached echo as a literal word (`echo PLUSARG +6c` ->
# output line `PLUSARG +6c`). If the tokenizer had errored, echo would
# never run and this output line would be absent.
if printf '%s\n' "$STRIPPED" | grep -E -q '^PLUSARG \+6c[[:space:]]*$'; then
    echo "[$TAG] OK: leading-'+' word (+6c) lexes as a literal argument"
else
    echo "[$TAG] WRONG: +6c did not reach echo as a literal arg (tokenizer papercut)"
    fail=1
fi
# The tokenizer must not have raised its operator-position error for +6c.
if grep -a -E -q "unexpected token after command" "$LOG"; then
    echo "[$TAG] WRONG: 'unexpected token after command' — leading '+' mis-lexed as operator"
    fail=1
fi
# The '+' operator still works in arithmetic (3 + 4 > 6).
if printf '%s\n' "$STRIPPED" | grep -E -q '^PLUSOP_OK[[:space:]]*$'; then
    echo "[$TAG] OK: space-flanked '+' still tokenizes as the arithmetic operator"
else
    echo "[$TAG] WRONG: arithmetic '+' regressed (3 + 4 > 6 did not evaluate)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- captured (stripped) ---" >&2
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000' | tail -30 >&2
    verdict_fail "$TAG" "a failing builtin did not surface the kernel errstr"
fi
verdict_pass "$TAG" "failing cd surfaces the kernel errstr; shell survives the failed builtin"
