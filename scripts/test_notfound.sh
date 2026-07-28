#!/usr/bin/env bash
# scripts/test_notfound.sh — regression guard for "a not-found command
# at the hamsh prompt hangs the whole system".
#
# History: run_one_command_x() returned 127 (a wait-STATUS) on a
# not-found command even on the do_wait==0 path, where the caller
# expects a PID-or-negative. _run_prebuilt_command's foreground branch
# then handed 127 to launch_foreground_pid() as if it were a live PID,
# and that function spun forever in sys_waitpid_jc(127, …) — the shell
# never returned to the prompt. To a user the whole system looked hung.
#
# This test boots hamsh, types a bogus command, then `echo` a marker.
# If the marker comes back the not-found path returned to the prompt
# (fixed); if it never appears the shell wedged (regression).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_notfound] (1/4) Build userland (incl. user/hamsh.ad)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_notfound] (2/4) Swap /init = $HAMSH_ELF in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_notfound] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

echo "[test_notfound] (4/4) Boot QEMU + type a bogus command, then echo a marker"
LOG=$(mktemp)
FIFO=$(mktemp -u)
mkfifo "$FIFO"
trap 'rm -f "$LOG" "$FIFO"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Gate keystrokes on the boot-ready marker, NOT a fixed sleep: the 16550
# RX FIFO is only 16 bytes with no software buffer, so bytes sent before
# the shell is reading get dropped. Wait until the shell prints its ready
# banner (watching the log QEMU is writing), THEN drive the prompt.
set +e
(
    for _ in $(seq 1 300); do
        if grep -aq "M16.35 shell ready" "$LOG" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    sleep 1
    printf 'lsblkk\n'
    sleep 2
    printf 'echo NOTFOUND_SURVIVED\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) > "$FIFO" &
driver_pid=$!

timeout 40s qemu-system-x86_64 \
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
wait "$driver_pid" 2>/dev/null
set -e

echo "[test_notfound] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_notfound] --- end output ---"

fail=0

# The shell must have actually reported the command as not found (proves
# we exercised the not-found path, not a typo that happened to match).
if grep -a -F -q "command not found: lsblkk" "$LOG"; then
    echo "[test_notfound] OK: not-found path was exercised"
else
    echo "[test_notfound] MISS: never saw 'command not found: lsblkk'"
    fail=1
fi

# The marker echoed AFTER the bogus command must come back — i.e. the
# shell returned to the prompt instead of wedging.
if grep -a -F -q "NOTFOUND_SURVIVED" "$LOG"; then
    echo "[test_notfound] OK: shell survived the not-found command"
else
    echo "[test_notfound] MISS: shell wedged after not-found command (HANG)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_notfound] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_notfound] PASS"
