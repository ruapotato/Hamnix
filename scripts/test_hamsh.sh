#!/usr/bin/env bash
# scripts/test_hamsh.sh - end-to-end test for the M16.35 Hamnix shell.
#
# Boots a kernel whose /init is build/user/hamsh.elf, pipes a short
# sequence of commands (help → hello → exit) into QEMU's serial
# stdio, and greps the captured serial log for evidence that:
#
#   1. the hamsh banner appeared        → main() ran
#   2. the help builtin output appeared → lex + builtin dispatch
#   3. the hello child banner appeared → SYS_SPAWN + ELF load worked
#   4. the kernel halted "no live tasks" → the `exit` builtin unwound
#                                          the read-eval loop cleanly
#                                          (the rewritten shell prints
#                                          no "bye" banner)
#
# Inputs are spaced out with sleeps because the 16550 RX FIFO is only
# 16 bytes and there is no kernel-side software buffer yet (M16.34);
# letting each command drain through SYS_READ before sending the next
# avoids dropped chars. Same trick scripts/test_stdin.sh uses.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh] (1/5) Build userland (incl. user/hamsh.ad)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_hamsh] (2/5) Swap /init = $HAMSH_ELF in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_hamsh] (3/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

echo "[test_hamsh] (4/5) Boot QEMU + drive shell via piped stdin"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Give the kernel ~3 s to finish all the smoke tests before the shell
# starts SYS_READ. Then send each command with a pause so the previous
# child has finished and the prompt is back.
(
    sleep 3
    printf 'help\n'
    sleep 1
    printf 'hello\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 15s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_hamsh] --- captured output ---"
cat "$LOG"
echo "[test_hamsh] --- end output ---"

fail=0
for needle in \
    "[hamsh] M16.35 shell ready" \
    "hamsh — the Hamnix shell." \
    "[/hello] hello from a second ELF"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_hamsh] OK: '$needle'"
    else
        echo "[test_hamsh] MISS: '$needle'"
        fail=1
    fi
done

# `exit` unwinds the read-eval loop cleanly: the shell (pid 1) exits,
# so the kernel halts with "no live tasks" — the new shell prints no
# "bye" banner (the old one did). This proves `exit` returned.
if grep -F -q "no live tasks" "$LOG"; then
    echo "[test_hamsh] OK: 'exit' unwound the shell cleanly"
else
    echo "[test_hamsh] MISS: shell did not exit cleanly"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamsh] PASS"
