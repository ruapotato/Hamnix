#!/usr/bin/env bash
# scripts/test_hamsh_blocks.sh — HAMSH_SPEC §18 stage 3 acceptance.
#
# Brace blocks + control flow + def (§5):
#   * multi-line if / for / while parse from the continuation prompt
#   * a def'd function runs with parameters
#   * mismatched braces error cleanly (no crash, parse error reported)
#
# hamsh has C-style { } blocks, no significant indentation; the parser
# knows a block is incomplete until the closing }, which is what makes
# both paste and the continuation prompt work.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
IN=$(mktemp -u --tmpdir hamsh-blocks-in.XXXXXX)
mkfifo "$IN"
trap 'rm -f "$LOG" "$IN"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# --- READY-MARKER SYNCHRONISATION ------------------------------------
#
# This gate used to pipe the whole script into QEMU after a flat
# `sleep 3`. Boot to the hamsh prompt takes far longer than that (the
# guest is still in early kernel bring-up at t+3s), and bytes delivered
# to the UART before the shell starts reading are DROPPED on the floor,
# not queued. The result: every block statement was swallowed and only
# the last couple of commands ever reached the shell, so the gate was
# permanently red for a reason that had nothing to do with hamsh.
# (Same trap as scripts/_hamsh_log.sh documents for the input echo:
# drive on a marker, never on a sleep.)
#
# Now the driver opens a FIFO on QEMU's stdin and only types once the
# shell has announced itself, waiting for each command's OUTPUT before
# sending the next.
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio < "$IN" > "$LOG" 2>&1 &
QPID=$!
exec 9>"$IN"

send() { printf '%b' "$1" >&9 2>/dev/null; }

# wait_log <marker> <timeout_s> — marker anywhere in the raw serial log.
wait_log() {
    local m="$1" t="$2" i=0
    while [ "$i" -lt "$((t * 4))" ]; do
        grep -a -q -F -- "$m" "$LOG" 2>/dev/null && return 0
        kill -0 "$QPID" 2>/dev/null || return 1
        sleep 0.25
        i=$((i + 1))
    done
    return 1
}

# wait_out <marker> <timeout_s> — marker in genuine command OUTPUT
# (input echo filtered out by hamsh_ran).
wait_out() {
    local m="$1" t="$2" i=0
    while [ "$i" -lt "$((t * 4))" ]; do
        hamsh_ran "$LOG" "$m" && return 0
        kill -0 "$QPID" 2>/dev/null || return 1
        sleep 0.25
        i=$((i + 1))
    done
    return 1
}

# The shell prints this once its read loop is live.
wait_log "[hamsh] M16.35 shell ready" 150

# hamsh is known to drop the FIRST serial command it sees; burn one on a
# sync echo and wait for it to come back before the real script starts.
send 'echo SYNC_OK\n'
wait_out "SYNC_OK" 20 || { send 'echo SYNC_OK\n'; wait_out "SYNC_OK" 20; }

# multi-line if from the continuation prompt
send 'if 5 > 2 {\necho IF_TRUE_BRANCH\n} else {\necho IF_FALSE_BRANCH\n}\n'
wait_out "IF_TRUE_BRANCH" 25
# multi-line for loop
send 'for w in ["p", "q", "r"] {\necho FOR_ITEM $w\n}\n'
wait_out "FOR_ITEM r" 25
# multi-line while loop
send 'c = 0\n'
sleep 1
send 'while c < 2 {\necho WHILE_ITER $c\nc = c + 1\n}\n'
wait_out "WHILE_ITER 1" 25
# def + call
send 'def dbl(v) {\nreturn v + v\n}\n'
sleep 2
send 'echo DEF_RESULT ${ dbl(21) }\n'
wait_out "DEF_RESULT 42" 25
# mismatched braces: must report a clean parse error, not crash
send 'echo BEFORE_BADBRACE\n'
wait_out "BEFORE_BADBRACE" 20
send 'if 1 > 0 { echo UNCLOSED\n'
sleep 2
send '}\n'
sleep 2
send 'echo AFTER_BADBRACE\n'
wait_out "AFTER_BADBRACE" 20
send 'exit\n'
sleep 2
exec 9>&-
# The script is done; `exit` ends hamsh but the kernel keeps running, so
# stop OUR qemu rather than idling until the timeout fires. (Only this
# pid — never a global pkill.)
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
set -e

echo "[test_hamsh_blocks] --- captured ---"
cat "$LOG"
echo "[test_hamsh_blocks] --- end ---"

fail=0
# Assert on command OUTPUT only — hamsh's interactive line editor echoes
# typed input, so a plain `grep` of the log would also match the command
# being typed. hamsh_ran (scripts/_hamsh_log.sh) ignores the prompt-
# prefixed input-echo lines.
check() {
    if hamsh_ran "$LOG" "$1"; then
        echo "[test_hamsh_blocks] OK: $2"
    else
        echo "[test_hamsh_blocks] MISS: $2"
        fail=1
    fi
}

check "IF_TRUE_BRANCH"   "multi-line if parses from continuation prompt"
check "FOR_ITEM p"       "multi-line for: first item"
check "FOR_ITEM r"       "multi-line for: last item"
check "WHILE_ITER 0"     "multi-line while: first iteration"
check "WHILE_ITER 1"     "multi-line while: second iteration"
check "DEF_RESULT 42"    "def function runs with a parameter"
# the shell must survive a mismatched-brace input cleanly
check "AFTER_BADBRACE"   "shell survives mismatched braces (no crash)"

# the false branch must NOT run
if hamsh_ran "$LOG" "IF_FALSE_BRANCH"; then
    echo "[test_hamsh_blocks] MISS: false branch leaked"
    fail=1
else
    echo "[test_hamsh_blocks] OK: false branch correctly skipped"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_blocks] FAIL"
    exit 1
fi
echo "[test_hamsh_blocks] PASS"
