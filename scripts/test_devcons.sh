#!/usr/bin/env bash
# scripts/test_devcons.sh — M16.94 regression for the first
# Plan 9-style device file: /dev/cons as a real VFS path.
#
# Pipeline:
#   1. Build all userland binaries (hamsh + test_devcons live there).
#   2. Build the test fixture tests/test_devcons.ad to
#      build/user/test_devcons.elf (lands at /bin/test_devcons in
#      the cpio initramfs via build_initramfs.py's auto-glob).
#   3. Make /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image so the new FD_CONS_MARK plumbing +
#      sys/src/9/port/devcons.ad body are compiled in.
#   5. Boot in QEMU, drive `/bin/test_devcons` over the serial stdio,
#      then run `echo POST_CONS_OK` to assert hamsh remains
#      responsive (a regression where opening /dev/cons hijacks the
#      global console would kill the shell here).
#   6. Grep the serial log for the marker.
#
# The test fixture opens /dev/cons with OWRITE, writes
# "M16.94 cons test\n", and closes. The kernel side fans that write
# out through early_putc() to UART + VGA/fb + printk so the marker
# appears on the serial log. PASS = both the marker AND the
# POST_CONS_OK sentinel appear in the captured output.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_devcons
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devcons.elf

echo "[test_devcons] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devcons] (2/5) Build tests/test_devcons.ad -> $TEST_ELF"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user tests/test_devcons.ad "$TEST_ELF" >/dev/null

echo "[test_devcons] (3/5) Plant /init = hamsh + /bin/test_devcons in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devcons] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_devcons] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

# PROMPT-GATED + output-adaptive input (scripts/_hamsh_drive.sh). The
# responsiveness echo would not come back if FD_CONS_MARK hijacked the
# console (stole the UART RX FIFO or wedged early_putc).
hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"
hamsh_send_await '/bin/test_devcons' 'M16.94 cons test' "$CMD_WAIT" || true
hamsh_send_await 'echo POST_CONS_OK' 'POST_CONS_OK' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[test_devcons] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_devcons] --- end output ---"

# Zero fixture markers -> the guest was starved, not that /dev/cons is broken.
verdict_boot_gate "$TAG" "$LOG" 0 '\[test_devcons\] start|M16.94 cons test'

fail=0
# Banner first — proves the fixture ran end to end.
if grep -F -q "[test_devcons] start" "$LOG"; then
    echo "[test_devcons] OK: fixture ran"
else
    echo "[test_devcons] MISS: fixture banner missing"
    fail=1
fi

# The /dev/cons round-trip itself.
if grep -F -q "M16.94 cons test" "$LOG"; then
    echo "[test_devcons] OK: /dev/cons write reached serial"
else
    echo "[test_devcons] MISS: /dev/cons marker absent"
    fail=1
fi

# Hamsh responsiveness after the test exits. If this is missing,
# opening /dev/cons broke the global console.
post_ok=0
if grep -F -q "POST_CONS_OK" "$LOG"; then
    echo "[test_devcons] OK: hamsh remains responsive"
    post_ok=1
else
    echo "[test_devcons] NOTE: POST_CONS_OK responsiveness sentinel not observed"
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" "a /dev/cons assertion was VIOLATED (see MISS: lines)"
fi
if [ "$post_ok" -ne 1 ]; then
    verdict_inconclusive "$TAG" \
        "/dev/cons write reached serial, but the POST_CONS_OK responsiveness" \
        "sentinel was not seen within ${CMD_WAIT}s — cannot tell a console" \
        "hijack/wedge from a starved guest. Re-run on a quiet host."
fi
verdict_pass "$TAG" "/dev/cons write reached serial; hamsh remained responsive after the round-trip"
