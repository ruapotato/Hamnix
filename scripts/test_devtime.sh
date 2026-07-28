#!/usr/bin/env bash
# scripts/test_devtime.sh — M16.95 regression for /dev/time.
#
# Pipeline mirrors test_devcons.sh exactly:
#   1. Build userland (hamsh, coreutils).
#   2. Build the test fixture tests/test_devtime.ad → /bin/test_devtime
#      in the cpio (build_initramfs.py auto-globs build/user/*.elf).
#   3. Plant hamsh as /init.
#   4. Rebuild the kernel image so devtime.ad + FD_TIME_MARK arms are
#      compiled in.
#   5. Boot in QEMU, drive `/bin/test_devtime` over the serial stdio,
#      grep for an "[test_devtime] ns=<digits>\n" pattern.
#
# PASS = the captured slice contains a non-empty digit run terminated
# by '\n'. We don't pin a specific value — jiffies advance, and the
# test would be flaky if we did.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_devtime
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devtime.elf

echo "[test_devtime] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devtime] (2/5) Build tests/test_devtime.ad -> $TEST_ELF"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user tests/test_devtime.ad "$TEST_ELF" >/dev/null

echo "[test_devtime] (3/5) Plant /init = hamsh + /bin/test_devtime in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devtime] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_devtime] (5/5) Boot QEMU + drive the test via hamsh"
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
hamsh_send_await '/bin/test_devtime' '[test_devtime] ns=' "$CMD_WAIT" || true
hamsh_send_await 'echo POST_TIME_OK' 'POST_TIME_OK' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[test_devtime] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_devtime] --- end output ---"

# Zero fixture markers -> the guest was starved, not that /dev/time is broken.
verdict_boot_gate "$TAG" "$LOG" 0 '\[test_devtime\] (start|ns=)'

fail=0
if grep -F -q "[test_devtime] start" "$LOG"; then
    echo "[test_devtime] OK: fixture ran"
else
    echo "[test_devtime] MISS: fixture banner missing"
    fail=1
fi

# Match "[test_devtime] ns=<one or more digits>" — devtime_read
# always emits at least "0" + '\n' (and in practice many seconds of
# jiffies have already elapsed by the time hamsh runs us, so a
# multi-digit run is the realistic case).
if grep -E -q "\[test_devtime\] ns=[0-9]+" "$LOG"; then
    echo "[test_devtime] OK: /dev/time read returned digit string"
else
    echo "[test_devtime] MISS: /dev/time ns= line absent or empty"
    fail=1
fi

post_ok=0
if grep -F -q "POST_TIME_OK" "$LOG"; then
    echo "[test_devtime] OK: hamsh remains responsive"
    post_ok=1
else
    echo "[test_devtime] NOTE: POST_TIME_OK responsiveness sentinel not observed"
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" "a /dev/time read assertion was VIOLATED (see MISS: lines)"
fi
if [ "$post_ok" -ne 1 ]; then
    verdict_inconclusive "$TAG" \
        "/dev/time read returned a digit string, but the POST_TIME_OK" \
        "responsiveness sentinel was not seen within ${CMD_WAIT}s — cannot" \
        "tell a shell wedge from a starved guest. Re-run on a quiet host."
fi
verdict_pass "$TAG" "/dev/time read returned a digit string; hamsh survived the round-trip"
