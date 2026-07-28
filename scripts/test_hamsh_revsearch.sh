#!/usr/bin/env bash
# scripts/test_hamsh_revsearch.sh — hamsh interactive editor kill-keys +
# reverse incremental history search (Ctrl-R).
#
# Drives the cursor-aware line editor (user/hamsh.ad :: ed_readline) over
# the serial console with raw control bytes and asserts the EDITED /
# RECALLED command is what actually runs. Same discriminator as
# test_hamsh_lineedit: a marker on its own line (no `hamsh$ ` before it)
# is genuine command OUTPUT, proving the command really ran — not the
# input being echoed back.
#
# COVERAGE
#   * Ctrl-R (0x12) reverse incremental search — run two commands, then
#     Ctrl-R + a substring of the older one + Enter recalls and re-runs
#     it (its output must appear a SECOND time).
#   * Ctrl-U (0x15) kill-to-start — type junk, Ctrl-U wipes the whole
#     line, then a real command is typed and runs (the junk never runs).
#   * Ctrl-W (0x17) kill-word — type `echo keepme deleteme`, Ctrl-W drops
#     the last word, Enter -> only `keepme` is echoed.
#
# Control bytes via printf octal escapes:
#   Ctrl-R = \022   Ctrl-U = \025   Ctrl-W = \027
#
# Boots hamsh directly as /init (no rc) so only the interactive editor
# path is exercised, exactly like test_hamsh_lineedit.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh_revsearch] (1/3) Build userland (incl. hamsh)"
bash scripts/build_user.sh >/dev/null

echo "[test_hamsh_revsearch] (2/3) Swap /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamsh_revsearch] (3/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
FIFO=$(mktemp -u)
mkfifo "$FIFO"
trap 'rm -f "$LOG" "$FIFO"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Prompt-GATED feeder. The interactive editor's first ed_readline runs a
# getty-style "pre-prompt input flush" that DISCARDS whatever bytes are
# queued when the prompt opens (to eat UEFI/RS-232 straggler noise). On a
# slow/loaded boot that flush would swallow the setup commands sent after
# a fixed `sleep`. So we wait for the `[hamsh:stage-08]` (ed-readline-first)
# marker to appear in LOG — the flush has run by then — before feeding any
# real input. A single priming newline absorbs any residual flush window.
(
    for _i in $(seq 1 120); do
        grep -aq "stage-08" "$LOG" && break
        sleep 0.5
    done
    sleep 1
    printf '\n'            # prime: absorb any residual pre-prompt flush
    sleep 1

    # --- Test 1: Ctrl-R reverse incremental search ------------------
    # Run two distinct commands, then Ctrl-R, type a substring of the
    # OLDER one (`zulu`), and Enter. The search accepts + submits the
    # matched line, so `zulumark` is echoed a SECOND time.
    printf 'echo zulumark\n'
    sleep 1
    printf 'echo yankmark\n'
    sleep 1
    printf '\022'          # Ctrl-R — enter reverse search
    sleep 1
    printf 'zulu'          # incremental query -> matches `echo zulumark`
    sleep 1
    printf '\n'            # accept the match AND submit it
    sleep 1

    # --- Test 2: Ctrl-U kill-to-start -------------------------------
    # Type junk (cursor at end), Ctrl-U wipes the whole line, then type
    # a real command. The junk must NEVER run as a command.
    printf 'garbagexyz'
    sleep 1
    printf '\025'          # Ctrl-U — kill from start to cursor (whole line)
    sleep 1
    printf 'echo cleanline\n'
    sleep 1

    # --- Test 3: Ctrl-W kill-word -----------------------------------
    # `echo keepme deleteme`, Ctrl-W drops the trailing `deleteme`
    # word, Enter -> echo prints only `keepme`.
    printf 'echo keepme deleteme'
    sleep 1
    printf '\027'          # Ctrl-W — kill the word before the cursor
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

echo "[test_hamsh_revsearch] --- captured output ---"
cat "$LOG"
echo "[test_hamsh_revsearch] --- end output ---"

fail=0

# A line whose ENTIRE content is <marker> (nothing before it on the
# line) is genuine command output; a line with `hamsh$ ` before it is
# only the input being echoed. See test_hamsh_lineedit for the rationale.
ran() { grep -E -q "^$1( |\$|\r)" "$LOG"; }
ran_count() { grep -E -c "^$1( |\$|\r)" "$LOG" || true; }

# Test 1: Ctrl-R recalled and re-ran `echo zulumark`, so `zulumark`
# appears as command output at least TWICE (the original + the recall).
hits=$(ran_count "zulumark")
if [ "${hits:-0}" -ge 2 ]; then
    echo "[test_hamsh_revsearch] OK: Ctrl-R recalled history (zulumark x$hits)"
else
    echo "[test_hamsh_revsearch] MISS: Ctrl-R search failed (zulumark x${hits:-0})"
    fail=1
fi

# Test 2: Ctrl-U wiped the junk line — `cleanline` ran and the junk
# `garbagexyz` never ran as a command. (The junk chars appear in the
# typed-back ECHO, so we assert it never produced a "not found" error
# line and never ran as its own output line — `ran` matches only a
# marker at the START of a line, which the `hamsh$ `-prefixed echo is
# not.)
if ran "cleanline" && ! ran "garbagexyz" \
   && ! grep -aiq "garbagexyz.*not found" "$LOG"; then
    echo "[test_hamsh_revsearch] OK: Ctrl-U killed the line -> cleanline"
else
    echo "[test_hamsh_revsearch] MISS: Ctrl-U kill-to-start failed"
    fail=1
fi

# Test 3: Ctrl-W dropped `deleteme` — echo printed only `keepme` and
# never the two-word `keepme deleteme`.
if ran "keepme" && ! ran "keepme deleteme"; then
    echo "[test_hamsh_revsearch] OK: Ctrl-W killed the word -> keepme"
else
    echo "[test_hamsh_revsearch] MISS: Ctrl-W kill-word failed"
    fail=1
fi

# The shell must have survived all the editing and exited cleanly. The
# `exit` builtin ends PID 1 with code 0; depending on what other kernel
# threads remain, the kernel either panics "no live tasks" or simply
# reports the task's clean exit and idles (so a 60s qemu timeout with a
# clean exit is NOT a failure — the feature assertions above are the
# real gate).
if grep -F -q "no live tasks" "$LOG" \
   || grep -aE -q "pid [0-9]+ exited \(code=0\)" "$LOG"; then
    echo "[test_hamsh_revsearch] OK: shell exited cleanly after editing"
else
    echo "[test_hamsh_revsearch] MISS: shell did not exit cleanly"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_hamsh_revsearch] DIAG: kernel reported a CPU exception"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_revsearch] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_hamsh_revsearch] PASS"
