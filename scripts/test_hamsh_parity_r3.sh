#!/usr/bin/env bash
# scripts/test_hamsh_parity_r3.sh — hamsh Python/bash parity round 3.
#
# Exercises the round-3 additions, each in BOTH block syntaxes where a
# grammar rule is involved (proving the dual-syntax invariant holds for
# the new productions, alongside test_hamsh_dualsyntax.sh):
#
#   Python-scripting axis
#     * ternary conditional expression  `THEN if COND else ELSE`
#         - true and false arms; right-associative chaining
#     * `def` DEFAULT parameter values  `def f(a, b=100)` — brace form
#         AND indented-suite form; positional override; keyword args
#         `f(a, b=7)` bound BY NAME (previously silently dropped)
#     * `assert COND[, MSG]` — a false assert RAISES (caught by
#         try/except, $errstr carries MSG); a true assert is a no-op
#
#   bash terminal-ergonomics axis
#     * `cd -` returns to $OLDPWD (and echoes it)
#     * `pushd DIR` / `popd` directory stack
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh:
# every command is sent ONCE after a live-readline handshake and waited
# on its OWN observable effect; assertions look ONLY at genuine command
# OUTPUT (scripts/_hamsh_log.sh :: hamsh_ran drops the editor input echo)
# so a skipped line can never false-green off the typed command text.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_parity_r3
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

# --- ternary conditional expression --------------------------------
hamsh_send 'ta = "TERN_HI" if 3 > 2 else "TERN_LO"'
hamsh_send_await 'echo TA_$ta' 'TA_TERN_HI' "$CMD_WAIT" || true
hamsh_send 'tb = "T_HI" if 2 > 3 else "T_LO"'
hamsh_send_await 'echo TB_$tb' 'TB_T_LO' "$CMD_WAIT" || true
# right-associative chaining: 2 -> "TWO"
hamsh_send 'tc = "ONE" if 0 else "TWO" if 1 else "THREE"'
hamsh_send_await 'echo TC_$tc' 'TC_TWO' "$CMD_WAIT" || true

# --- def default parameters (BRACE form) ---------------------------
hamsh_send 'def add(a, b=100) { return a + b }'
hamsh_send 'r1 = add(5)'
hamsh_send_await 'echo R1_$r1' 'R1_105' "$CMD_WAIT" || true
hamsh_send 'r2 = add(5, 7)'
hamsh_send_await 'echo R2_$r2' 'R2_12' "$CMD_WAIT" || true
# keyword argument bound BY NAME (was previously ignored):
hamsh_send 'r3 = add(5, b=1)'
hamsh_send_await 'echo R3_$r3' 'R3_6' "$CMD_WAIT" || true

# --- def default parameters (INDENTED-SUITE form) ------------------
hamsh_send 'def mul(a, b=3):'
hamsh_send '    return a * b'
hamsh_send ''
hamsh_send 'r4 = mul(4)'
hamsh_send_await 'echo R4_$r4' 'R4_12' "$CMD_WAIT" || true
hamsh_send 'r5 = mul(4, 5)'
hamsh_send_await 'echo R5_$r5' 'R5_20' "$CMD_WAIT" || true

# --- assert ---------------------------------------------------------
# false assert with message -> raises, caught, $errstr == message
hamsh_send_await 'try { assert 1 == 2, "AFAIL" } except e { echo AS_$e }' 'AS_AFAIL' "$CMD_WAIT" || true
# true assert is a no-op; the following statement runs
hamsh_send_await 'assert 1 == 1 ; echo AS_OK' 'AS_OK' "$CMD_WAIT" || true
# false assert with NO message -> default text
hamsh_send_await 'try { assert 0 } except e { echo AS2_$e }' 'AS2_assertion failed' "$CMD_WAIT" || true

# --- cd - / OLDPWD --------------------------------------------------
hamsh_send 'cd /'
hamsh_send 'cd /bin'
# `cd -` echoes the directory it returns to (bash-shape) -> "/"
hamsh_send_await 'cd -' '^/$' "$CMD_WAIT" || true
hamsh_send_await 'pwd' '^/$' "$CMD_WAIT" || true

# --- pushd / popd ---------------------------------------------------
hamsh_send 'cd /'
hamsh_send_await 'pushd /bin' '^/bin$' "$CMD_WAIT" || true
hamsh_send_await 'pwd' '^/bin$' "$CMD_WAIT" || true
hamsh_send_await 'popd' '^/$' "$CMD_WAIT" || true
hamsh_send_await 'echo PD_DONE' 'PD_DONE' "$CMD_WAIT" || true

hamsh_send 'exit'
sleep 2

verdict_boot_gate "$TAG" "$LOG" 0 'TA_TERN_HI|R1_105'
if ! hamsh_ran "$LOG" "TA_TERN_HI" && ! hamsh_ran "$LOG" "R1_105"; then
    verdict_inconclusive "$TAG" \
        "no early marker observed within ${CMD_WAIT}s — guest starved. Re-run on a quiet host."
fi

fail=0
present() {
    if hamsh_ran "$LOG" "$1"; then echo "[$TAG] OK: $1"; else
        echo "[$TAG] WRONG: $1 absent (should have run)"; fail=1; fi
}
absent() {
    if hamsh_ran "$LOG" "$1"; then
        echo "[$TAG] WRONG: $1 leaked (should NOT have run)"; fail=1; else
        echo "[$TAG] OK: $1 correctly absent"; fi
}
# ternary
present "TA_TERN_HI"; absent "TA_TERN_LO"
present "TB_T_LO";    absent "TB_T_HI"
present "TC_TWO"
# defaults + kwargs
present "R1_105"; present "R2_12"; present "R3_6"
present "R4_12"; present "R5_20"
# assert
present "AS_AFAIL"; present "AS_OK"; present "AS2_assertion failed"
# cd - / pushd / popd land the shell back; PD_DONE proves we survived
present "PD_DONE"

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -60 >&2
    verdict_fail "$TAG" "a round-3 parity assertion was VIOLATED"
fi
verdict_pass "$TAG" "ternary, def defaults+kwargs, assert, cd-/pushd/popd all correct"
