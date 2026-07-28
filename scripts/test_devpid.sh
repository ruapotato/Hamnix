#!/usr/bin/env bash
# scripts/test_devpid.sh — M16.95 regression for /dev/pid.
#
# Mirrors test_devcons.sh / test_devtime.sh: rebuild user + kernel,
# boot QEMU, run /bin/test_devpid, assert a positive-integer pid + '\n'
# came out.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_devpid
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devpid.elf

echo "[test_devpid] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devpid] (2/5) Build tests/test_devpid.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devpid.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_devpid] (3/5) Plant /init = hamsh + /bin/test_devpid in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devpid] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_devpid] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

# PROMPT-GATED + output-adaptive input (scripts/_hamsh_drive.sh): wait for the
# shell-ready marker, prove a live readline, then drive the fixture and wait
# on its own markers rather than a fixed sleep that races a load-starved boot.
hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"
hamsh_send_await '/bin/test_devpid' '[test_devpid] pid=' "$CMD_WAIT" || true
hamsh_send_await 'echo POST_PID_OK' 'POST_PID_OK' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[test_devpid] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_devpid] --- end output ---"

# Zero fixture markers -> the guest was starved, not that /dev/pid is broken.
verdict_boot_gate "$TAG" "$LOG" 0 '\[test_devpid\] (start|pid=)'

fail=0
if grep -F -q "[test_devpid] start" "$LOG"; then
    echo "[test_devpid] OK: fixture ran"
else
    echo "[test_devpid] MISS: fixture banner missing"
    fail=1
fi

# Positive integer pid. The kernel never hands out pid 0 to a user
# task (slot 0 is the idle/boot kthread), so we require [1-9] then any
# trailing digits.
if grep -E -q "\[test_devpid\] pid=[1-9][0-9]*" "$LOG"; then
    echo "[test_devpid] OK: /dev/pid read returned positive integer"
else
    echo "[test_devpid] MISS: /dev/pid line absent or non-positive"
    fail=1
fi

post_ok=0
if grep -F -q "POST_PID_OK" "$LOG"; then
    echo "[test_devpid] OK: hamsh remains responsive"
    post_ok=1
else
    echo "[test_devpid] NOTE: POST_PID_OK responsiveness sentinel not observed"
fi

# An OBSERVED violation of the /dev/pid read itself is a real FAIL.
if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" "a /dev/pid read assertion was VIOLATED (see MISS: lines)"
fi
# Primary assertion held, but the post-round-trip responsiveness echo never
# came back. We CANNOT distinguish a genuine shell wedge from host/runner
# starvation or a serial log truncated when QEMU was killed — that is
# absence of evidence, so INCONCLUSIVE, never a false red.
if [ "$post_ok" -ne 1 ]; then
    verdict_inconclusive "$TAG" \
        "/dev/pid read returned a positive integer, but the POST_PID_OK" \
        "responsiveness sentinel was not seen within ${CMD_WAIT}s — cannot" \
        "tell a shell wedge from a starved guest. Re-run on a quiet host."
fi
verdict_pass "$TAG" "/dev/pid read returned a positive integer; hamsh survived the round-trip"
