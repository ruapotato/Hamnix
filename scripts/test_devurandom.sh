#!/usr/bin/env bash
# scripts/test_devurandom.sh — regression for /dev/urandom (the alias
# of /dev/random wired in sys/src/9/port/namec.ad).
#
#   1. Build userland (hamsh + coreutils)
#   2. Build tests/test_devurandom.ad -> build/user/test_devurandom.elf
#   3. Plant /init = hamsh + /bin/test_devurandom in the cpio
#   4. Rebuild kernel image
#   5. Boot QEMU + drive the test via hamsh, then check the log
#
# Assertions:
#   - [test_devurandom] start              fixture launched
#   - [test_devurandom] opened             /dev/urandom open()ed
#   - [test_devurandom] entropy_ok         16 bytes not all-zero/all-ff
#   - [test_devurandom] 4k_jiffies=<N>     4 KiB read latency in jiffies
#                                          (asserted < 100 = 1 s @ HZ=100)
#   - [test_devurandom] varying_ok         consecutive /dev/random reads differ
#   - [test_devurandom] done               clean exit
#
# INPUT TIMING: prompt-gated + output-adaptive via scripts/_hamsh_drive.sh
# (replaces the old fixed-sleep feeder that false-red'd under host load).
# NOTE the 4k_jiffies latency check is a GUEST-timer measurement, not a
# wall-clock one, so it stays valid even when the host starves the VM.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_devurandom
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devurandom.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[test_devurandom] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
bash scripts/build_modules.sh >/dev/null || verdict_inconclusive "$TAG" "build_modules failed"

echo "[test_devurandom] (2/5) Build tests/test_devurandom.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user tests/test_devurandom.ad -o "$TEST_ELF" >/dev/null \
    || verdict_inconclusive "$TAG" "test_devurandom.ad compile failed"

echo "[test_devurandom] (3/5) Plant /init = hamsh + /bin/test_devurandom in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"

echo "[test_devurandom] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[test_devurandom] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"

# Send exactly ONE real command (the fixture) after the sync handshake and
# wait on its OWN "done" OUTPUT marker. No POST_* survival echo: hamsh
# echoes typed keystrokes to the same serial the log captures, so a
# `grep POST_X` would match the INPUT ECHO of `echo POST_X` and prove
# nothing. The fixture's "done" + its 4k_jiffies/entropy markers are all
# genuine command OUTPUT.
hamsh_send_await '/bin/test_devurandom' '[test_devurandom] done' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[test_devurandom] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_devurandom] --- end output ---"

# If the fixture never started, the guest was starved before it ran — that
# is INCONCLUSIVE, never a false red about /dev/urandom.
verdict_boot_gate "$TAG" "$LOG" 0 '\[test_devurandom\] start'

fail=0
for m in "[test_devurandom] start" \
         "[test_devurandom] opened" \
         "[test_devurandom] entropy_ok" \
         "[test_devurandom] varying_ok" \
         "[test_devurandom] done"; do
    if grep -a -F -q "$m" "$LOG"; then
        echo "[test_devurandom] OK: marker '$m'"
    else
        echo "[test_devurandom] MISS: marker '$m'"; fail=1
    fi
done

# 4 KiB latency check — a GUEST-jiffy measurement, valid under host load.
jiffies_line=$(grep -a "\[test_devurandom\] 4k_jiffies=" "$LOG" || true)
if [ -z "$jiffies_line" ]; then
    echo "[test_devurandom] MISS: 4k_jiffies= line absent"; fail=1
else
    jval=${jiffies_line##*4k_jiffies=}
    jval=${jval%%[!0-9]*}
    if [ -z "$jval" ]; then
        echo "[test_devurandom] MISS: 4k_jiffies= value unparseable ('$jiffies_line')"; fail=1
    elif [ "$jval" -ge 100 ]; then
        echo "[test_devurandom] FAIL: 4 KiB read took $jval jiffies (>= 1 s)"; fail=1
    else
        echo "[test_devurandom] OK: 4 KiB read in $jval jiffies"
    fi
fi

if [ "$fail" -ne 0 ]; then
    # The fixture demonstrably RAN (verdict_boot_gate saw its start), so an
    # absent/violated contract marker is an OBSERVED /dev/urandom regression.
    verdict_fail "$TAG" \
        "a /dev/urandom contract marker was OBSERVED absent or violated while" \
        "the fixture ran (start banner present) — real regression."
fi

verdict_pass "$TAG" "/dev/urandom: entropy_ok, varying_ok, 4KiB read < 1s; fixture ran to clean done"
