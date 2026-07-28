#!/usr/bin/env bash
# scripts/test_errstr.sh - Phase B / M16.93 regression for SYS_ERRSTR
# (Plan 9-shape error reporting, syscall number 265).
#
# Pipeline:
#   1. Build all userland binaries (hamsh + test_errstr live there).
#   2. Build the test fixture tests/test_errstr.ad to
#      build/user/test_errstr.elf (lands at /bin/test_errstr in the
#      cpio initramfs via build_initramfs.py's auto-glob).
#   3. Make /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image so the new SYS_ERRSTR (265) +
#      Phase B stubs are compiled in.
#   5. Boot in QEMU, drive `/bin/test_errstr` over the serial stdio,
#      then `exit`.
#   6. Grep the serial log for the recovered error string.
#
# The test fixture opens /nonexistent/path (forcing a SYS_OPEN ->
# -ENOENT failure with set_current_errstr("file does not exist")),
# then SYS_ERRSTR's the message back into a 128-byte buffer and
# writes it to stdout. PASS = the serial log contains the canonical
# "[test_errstr] got: file does not exist" line.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_errstr
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_errstr.elf

echo "[test_errstr] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_errstr] (2/5) Build tests/test_errstr.ad -> $TEST_ELF"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user tests/test_errstr.ad "$TEST_ELF" >/dev/null

echo "[test_errstr] (3/5) Plant /init = hamsh + /bin/test_errstr in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_errstr] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_errstr] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

# PROMPT-GATED + output-adaptive input (scripts/_hamsh_drive.sh).
hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"
hamsh_send_await '/bin/test_errstr' '[test_errstr] got:' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[test_errstr] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_errstr] --- end output ---"

# Zero fixture markers -> the guest was starved, not that SYS_ERRSTR is broken.
verdict_boot_gate "$TAG" "$LOG" 0 '\[test_errstr\] (start|got:)'

fail=0
# Banner first — proves the binary ran end to end.
if grep -F -q "[test_errstr] start" "$LOG"; then
    echo "[test_errstr] OK: fixture ran"
else
    echo "[test_errstr] MISS: fixture banner missing"
    fail=1
fi

# The actual SYS_ERRSTR round-trip. The error string is installed
# from arch/x86/kernel/syscall.ad's SYS_OPEN failure branch; the
# fixture reads it back and prints "[test_errstr] got: <string>".
if grep -F -q "[test_errstr] got: file does not exist" "$LOG"; then
    echo "[test_errstr] OK: SYS_ERRSTR returned the installed error"
else
    echo "[test_errstr] MISS: error string not echoed correctly"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" "the SYS_ERRSTR round-trip assertion was VIOLATED (see MISS: lines)"
fi
verdict_pass "$TAG" "SYS_ERRSTR returned the installed 'file does not exist' error string"
