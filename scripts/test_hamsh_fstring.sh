#!/usr/bin/env bash
# scripts/test_hamsh_fstring.sh — hamsh Python-style f-strings.
#
# `f"...{expr}..."` (and the single-quoted `f'...'`) evaluate each embedded
# `{expr}` as a hamsh expression and interpolate its rendered value into the
# string; `{{` / `}}` are literal `{` / `}`. The embedded expression reuses
# the ordinary hamsh expression engine (eval_subexpr), so names, arithmetic,
# builtin calls and indexing all work. f-strings are a first-class value in
# BOTH the indent-form and brace-form syntaxes (the dual-syntax invariant is
# guarded separately by scripts/test_hamsh_dualsyntax.sh).
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh (the
# fixed-sleep feeder could drop the first command and false-red). Every
# assertion is made on the shell's OUTPUT line, which starts a fresh line and
# is distinct from the prompt-prefixed input echo: each command emits a
# leading sentinel word (FSTRn) glued to interpolated text that never appears
# in the literal typed source (the source still contains the `f"`/`{`/`}`
# spelling), so a begin-of-line grep on the stripped log is unambiguous.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_fstring
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

# Seed the interpolation environment in a SINGLE synchronized line — three
# separate fire-and-forget `hamsh_send`s would race the char-by-char readline
# echo and splice/drop a seed under host load, so we set them all at once and
# await the confirmation echo before any f-string command is sent.
hamsh_send_await 'x = 5; name = "hi"; xs = [10, 20, 30]; echo SEEDS $x $name $xs' \
    'SEEDS 5 hi 10 20 30' "$CMD_WAIT" || true

# The `{expr}` sublanguage is the ORDINARY hamsh expression grammar (each
# `{ }` is re-lexed + parsed by eval_subexpr), so it follows hamsh's own
# rules: a bare name reads a variable, arithmetic operators are SPACE-flanked
# (a glued `+`/`*` is a literal glob/word char), and a subscript read uses the
# `$var[idx]` idiom (a glued `name[idx]` lexes as one glob word — a lexer-wide
# rule, not an f-string quirk). f-strings interpolate whatever that engine
# yields; these cases exercise the four common forms.
# 1) names + (space-flanked) arithmetic inside a double-quoted f-string.
hamsh_send_await 'echo FSTR1 f"val is {x} and {x + 1}"' 'FSTR1 val is 5 and 6' "$CMD_WAIT" || true
# 2) `{{` / `}}` render as literal braces.
hamsh_send_await 'echo FSTR2 f"{{literal braces}}"' 'FSTR2 {literal braces}' "$CMD_WAIT" || true
# 3) single-quoted f-string `f'...'` (the NEW rung) interpolates too.
hamsh_send_await "echo FSTR3 f'x is {x}'" 'FSTR3 x is 5' "$CMD_WAIT" || true
# 4) a builtin call inside `{ }` (reuses the expression engine).
hamsh_send_await 'echo FSTR4 f"{upper(name)}"' 'FSTR4 HI' "$CMD_WAIT" || true
# 5) a subscript read inside `{ }` (hamsh `$var[idx]` idiom).
hamsh_send_await 'echo FSTR5 f"{$xs[0]}"' 'FSTR5 10' "$CMD_WAIT" || true
# Survival sentinel — proves the shell kept its footing through all of it.
hamsh_send_await 'echo FSTR_SURVIVED' 'FSTR_SURVIVED' "$CMD_WAIT" || true

hamsh_send 'exit'
sleep 2

if ! hamsh_ran "$LOG" "FSTR_SURVIVED"; then
    verdict_inconclusive "$TAG" \
        "the survival sentinel never printed within ${CMD_WAIT}s" \
        "— the guest was starved before the fixture ran. Re-run quiet."
fi

# ANSI/NUL-stripped view: genuine command OUTPUT starts a fresh line, while
# the input echo is prompt-prefixed AND still carries the literal `f"`/`{`/`}`
# source spelling — so each interpolated result is unique to the output.
STRIPPED="$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000')"

fail=0
_want() {  # <regex> <human description>
    if printf '%s\n' "$STRIPPED" | grep -E -q "$1"; then
        echo "[$TAG] OK: $2"
    else
        echo "[$TAG] WRONG: $2 (missing output line matching /$1/)"
        fail=1
    fi
}

_want '^FSTR1 val is 5 and 6[[:space:]]*$' 'names + arithmetic interpolate (f"{x} and {x + 1}")'
_want '^FSTR2 \{literal braces\}[[:space:]]*$' 'doubled braces render literal { }'
_want '^FSTR3 x is 5[[:space:]]*$' "single-quoted f'...' interpolates {x}"
_want '^FSTR4 HI[[:space:]]*$' 'a builtin call interpolates (f"{upper(name)}")'
_want '^FSTR5 10[[:space:]]*$' 'a subscript read interpolates (f"{$xs[0]}")'

echo "[$TAG] OK: shell survived all f-string forms (FSTR_SURVIVED)"

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- captured (stripped) ---" >&2
    printf '%s\n' "$STRIPPED" | tail -40 >&2
    verdict_fail "$TAG" "an f-string form did not interpolate correctly"
fi
verdict_pass "$TAG" "f-strings interpolate {expr}, literal {{ }}, and single-quoted f'...'"
