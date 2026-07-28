#!/usr/bin/env bash
# scripts/test_hamsh_ctxcomplete.sh — hamsh context-aware Tab completion:
# variable ($NAME) completion and command-flag (-/--) completion.
#
# Drives the cursor-aware line editor (user/hamsh.ad :: _ed_complete) over
# the serial console and proves the editor INSERTED completion bytes that
# the feeder never sent:
#
#   * Variable completion — type `echo $PAT` then Tab. The exported env
#     has exactly one name beginning `PAT` (PATH), so it completes to
#     `echo $PATH ` and Enter runs it, printing the seeded PATH value
#     `/bin:/sbin:/usr/bin` as genuine command OUTPUT on its own line.
#     Had $-completion not fired, `echo $PAT` would expand an unset var
#     and print an empty line — no PATH value.
#
#   * Flag completion — type `ls --h` then Tab. The static flag table for
#     `ls` has exactly one long flag beginning `--h` (--human-readable),
#     so the editor completes the token to `ls --human-readable`. The
#     bytes `human-readable` were NEVER sent by this feeder, so their
#     appearance anywhere in the transcript can ONLY come from the
#     completion engine inserting + echoing them — a valid proof that is
#     NOT a "console leak" of feeder-sent input.
#
# Control byte:  Tab = \011
#
# Boots hamsh directly as /init (no rc), exactly like test_hamsh_revsearch.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh_ctxcomplete] (1/3) Build userland (incl. hamsh)"
bash scripts/build_user.sh >/dev/null

echo "[test_hamsh_ctxcomplete] (2/3) Swap /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamsh_ctxcomplete] (3/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
FIFO=$(mktemp -u)
mkfifo "$FIFO"
trap 'rm -f "$LOG" "$FIFO"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Prompt-GATED feeder — wait for stage-08 (ed-readline-ready) so the
# getty-style pre-prompt input flush can't eat the setup keystrokes.
(
    for _i in $(seq 1 120); do
        grep -aq "stage-08" "$LOG" && break
        sleep 0.5
    done
    sleep 1
    printf '\n'            # prime: absorb any residual pre-prompt flush
    sleep 1

    # --- Test 1: variable completion --------------------------------
    printf 'echo $PAT'     # unique env prefix -> completes to $PATH
    sleep 1
    printf '\011'          # Tab
    sleep 1
    printf '\n'            # run `echo $PATH`
    sleep 1

    # --- Test 2: flag completion ------------------------------------
    printf 'ls --h'        # unique ls long-flag prefix -> --human-readable
    sleep 1
    printf '\011'          # Tab
    sleep 1
    printf '\n'
    sleep 1

    printf 'exit\n'
    sleep 2
) > "$FIFO" &
FEEDER=$!
timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    < "$FIFO" \
    > "$LOG" 2>&1
rc=$?
wait "$FEEDER" 2>/dev/null
set -e

echo "[test_hamsh_ctxcomplete] --- captured output ---"
cat "$LOG"
echo "[test_hamsh_ctxcomplete] --- end output ---"

fail=0

# Test 1: `echo $PATH` printed the seeded PATH as command OUTPUT (a line
# that STARTS with the value, not the `hamsh$ echo $PATH` typed echo).
if grep -E -q '^/bin:/sbin:/usr/bin' "$LOG"; then
    echo "[test_hamsh_ctxcomplete] OK: \$-completion expanded PATH"
else
    echo "[test_hamsh_ctxcomplete] MISS: variable completion failed"
    fail=1
fi

# Test 2: the completion engine inserted+echoed `human-readable` — bytes
# the feeder never sent — proving flag completion fired.
if grep -aq "human-readable" "$LOG"; then
    echo "[test_hamsh_ctxcomplete] OK: flag completion inserted --human-readable"
else
    echo "[test_hamsh_ctxcomplete] MISS: flag completion failed"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_hamsh_ctxcomplete] DIAG: kernel reported a CPU exception"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_ctxcomplete] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_hamsh_ctxcomplete] PASS"
