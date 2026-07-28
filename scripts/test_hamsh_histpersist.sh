#!/usr/bin/env bash
# scripts/test_hamsh_histpersist.sh — hamsh interactive history persistence
# across sessions (save on exit + reload at startup).
#
# hamsh mirrors its interactive history ring to $HOME/.hamsh_history: it
# writes the live ring on a clean `exit` and reloads it at startup, so
# Up-arrow / Ctrl-R recall spans previous sessions. This gate proves the
# ROUND TRIP inside one boot using two NESTED shell sessions that share
# the (tmpfs) filesystem:
#
#   1. PID 1 hamsh (booted as /init) reaches its interactive prompt.
#   2. Launch a nested `hamsh` (found on PATH at /bin/hamsh). In it run
#      `echo histseed_cmd`, then `exit` — the nested shell SAVES its
#      history (the `echo histseed_cmd` line) to $HOME/.hamsh_history and
#      returns control to PID 1.
#   3. Launch a SECOND nested `hamsh`. It RELOADS the saved history at
#      startup, so pressing Up-arrow recalls `echo histseed_cmd`; Enter
#      re-runs it. Its output `histseed_cmd` therefore appears a SECOND
#      time — proving the recalled line came from the persisted file, not
#      from the (fresh) second shell's own in-memory history.
#
# Discriminator (same as test_hamsh_revsearch): a marker on its OWN line
# (no `hamsh$ ` before it) is genuine command OUTPUT. `histseed_cmd`
# appearing >= 2 times at line-start means the recall in the second,
# independent shell process really ran the command reloaded from disk.
# Had persistence failed, the second shell's history would be empty, the
# Up-arrow would be a no-op, and `histseed_cmd` would appear only once.
#
# Control bytes via printf octal escapes:  Up-arrow = ESC [ A = \033[A
#
# Boots hamsh directly as /init (no rc) so only the interactive path is
# exercised, exactly like test_hamsh_revsearch.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh_histpersist] (1/3) Build userland (incl. hamsh)"
bash scripts/build_user.sh >/dev/null

echo "[test_hamsh_histpersist] (2/3) Swap /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamsh_histpersist] (3/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
FIFO=$(mktemp -u)
mkfifo "$FIFO"
trap 'rm -f "$LOG" "$FIFO"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Prompt-GATED feeder. EACH hamsh session (PID 1 and both nested shells)
# runs its OWN getty-style pre-prompt input flush at its first prompt,
# which DISCARDS bytes queued when the prompt opens. So we gate every
# session's first input on that session's `[hamsh:stage-08]` marker
# (emitted right before its flush) appearing in LOG, then wait out the
# short flush window before feeding. A fixed `sleep` alone races the
# nested shells' flush and gets the setup keystrokes eaten.
wait_stage08() {   # wait until LOG holds at least $1 stage-08 markers
    local want="$1" _i
    for _i in $(seq 1 120); do
        [ "$(grep -ac 'stage-08' "$LOG")" -ge "$want" ] && return 0
        sleep 0.5
    done
    return 0
}
(
    # PID 1 ready.
    wait_stage08 1
    sleep 2
    printf '\n'            # prime: absorb any residual pre-prompt flush
    sleep 1

    # --- Session A: seed + save on exit -----------------------------
    printf 'hamsh\n'       # launch a nested interactive shell
    wait_stage08 2         # session A reached its first prompt...
    sleep 2                # ...let its flush window drain
    printf 'echo histseed_cmd\n'
    sleep 2
    printf 'exit\n'        # nested shell SAVES history, returns to PID 1
    sleep 2

    # --- Session B: reload + recall via Up-arrow --------------------
    # Session A's persisted history is [ `echo histseed_cmd`, `exit` ]
    # (the `exit` command is itself recorded, like every shell). So in
    # the fresh session B the NEWEST entry is `exit`; a first Up recalls
    # it and a second Up steps back to `echo histseed_cmd`, which Enter
    # then re-runs — proving the recalled line came from the reloaded
    # file, in a different process than where it was first typed.
    printf 'hamsh\n'       # second nested shell RELOADS the saved history
    wait_stage08 3         # session B reached its first prompt...
    sleep 2                # ...let its flush window drain
    printf '\033[A'        # Up-arrow #1 -> `exit` (newest persisted line)
    sleep 1
    printf '\033[A'        # Up-arrow #2 -> `echo histseed_cmd`
    sleep 1
    printf '\n'            # run the recalled command
    sleep 2
    printf 'exit\n'        # leave session B
    sleep 2

    printf 'exit\n'        # leave PID 1
    sleep 2
) > "$FIFO" &
FEEDER=$!
timeout 90s qemu-system-x86_64 \
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

echo "[test_hamsh_histpersist] --- captured output ---"
cat "$LOG"
echo "[test_hamsh_histpersist] --- end output ---"

fail=0

# A line whose ENTIRE content is <marker> (nothing before it on the line)
# is genuine command output; a `hamsh$ `-prefixed line is only the typed
# echo. `histseed_cmd` at line-start >= 2 times => the second (fresh)
# shell reloaded the persisted history and re-ran the recalled command.
ran_count() { grep -E -c "^$1( |\$|\r)" "$LOG" || true; }

hits=$(ran_count "histseed_cmd")
if [ "${hits:-0}" -ge 2 ]; then
    echo "[test_hamsh_histpersist] OK: history persisted + reloaded (histseed_cmd x$hits)"
else
    echo "[test_hamsh_histpersist] MISS: cross-session recall failed (histseed_cmd x${hits:-0})"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_hamsh_histpersist] DIAG: kernel reported a CPU exception"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_histpersist] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_hamsh_histpersist] PASS"
