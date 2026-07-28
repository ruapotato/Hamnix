#!/usr/bin/env bash
# scripts/test_devrandom_chacha.sh — M16.96 regression for the
# ChaCha20 + RDRAND/RDSEED upgrade in /dev/random.
#
# Builds the kernel + userland, plants /bin/test_devrandom_chacha,
# boots QEMU (with -cpu max so RDRAND/RDSEED are exposed), runs the
# binary, parses the histogram line, and asserts:
#   - total bytes counted == 4096
#   - nonzero buckets >= 200 (chi-square would yield > 250 with
#     extremely high probability; 200 is loose to be flake-free)
#   - busiest bucket max <= 4x expected (rules out the xorshift
#     placeholder and any other degenerate distribution)
#   - post-rekey 16-byte stream sum is non-zero
#
# The xorshift64 placeholder this commit retired WOULD fail the
# nonzero_buckets test: its low-byte cycle leaves dozens of buckets
# empty for any 4 KiB sample.
#
# INPUT TIMING: prompt-gated + output-adaptive via scripts/_hamsh_drive.sh
# (replaces the old fixed-sleep feeder that false-red'd under host load).
# -cpu max is passed via QEMU_EXTRA_ARGS.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_devrandom_chacha
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devrandom_chacha.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
# Expose RDRAND/RDSEED to the guest (the seeding path under test).
export QEMU_EXTRA_ARGS="-cpu max ${QEMU_EXTRA_ARGS:-}"

echo "[test_devrandom_chacha] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
bash scripts/build_modules.sh >/dev/null || verdict_inconclusive "$TAG" "build_modules failed"

echo "[test_devrandom_chacha] (2/5) Build tests/test_devrandom_chacha.ad -> $TEST_ELF"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user tests/test_devrandom_chacha.ad "$TEST_ELF" >/dev/null || verdict_inconclusive "$TAG" "test_devrandom_chacha.ad compile failed"

echo "[test_devrandom_chacha] (3/5) Plant /init = hamsh + /bin/test_devrandom_chacha in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"

echo "[test_devrandom_chacha] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[test_devrandom_chacha] (5/5) Boot QEMU + drive the test via hamsh"
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
# wait on its OWN "post" OUTPUT marker (the last line the fixture prints).
# No POST_* survival echo: hamsh echoes typed keystrokes to the same serial
# the log captures, so `grep POST_X` would match the INPUT ECHO of
# `echo POST_X` and prove nothing. The histogram + post-rekey markers are
# all genuine command OUTPUT.
hamsh_send_await '/bin/test_devrandom_chacha' '[test_devrandom_chacha] post ' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[test_devrandom_chacha] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_devrandom_chacha] --- end output ---"

# If the fixture never started, the guest was starved before it ran.
verdict_boot_gate "$TAG" "$LOG" 0 '\[test_devrandom_chacha\] start'

fail=0
grep -a -F -q "[test_devrandom_chacha] start" "$LOG" \
    && echo "[test_devrandom_chacha] OK: fixture ran" \
    || { echo "[test_devrandom_chacha] MISS: fixture banner"; fail=1; }

HIST_LINE=$(grep -a "\[test_devrandom_chacha\] hist" "$LOG" || true)
if [ -z "$HIST_LINE" ]; then
    echo "[test_devrandom_chacha] MISS: hist= line absent"; fail=1
else
    min_val=$(printf '%s\n' "$HIST_LINE" | sed -n 's/.* min=\([0-9]*\).*/\1/p')
    max_val=$(printf '%s\n' "$HIST_LINE" | sed -n 's/.* max=\([0-9]*\).*/\1/p')
    total_val=$(printf '%s\n' "$HIST_LINE" | sed -n 's/.* total=\([0-9]*\).*/\1/p')
    nz_val=$(printf '%s\n' "$HIST_LINE" | sed -n 's/.* nonzero_buckets=\([0-9]*\).*/\1/p')
    echo "[test_devrandom_chacha] parsed: min=$min_val max=$max_val total=$total_val nonzero_buckets=$nz_val"

    if [ -z "$total_val" ] || [ "$total_val" -ne 4096 ]; then
        echo "[test_devrandom_chacha] MISS: total != 4096 (got '$total_val')"; fail=1
    fi
    if [ -z "$nz_val" ] || [ "$nz_val" -lt 200 ]; then
        echo "[test_devrandom_chacha] MISS: nonzero_buckets < 200 (got '$nz_val') — distribution too narrow"; fail=1
    else
        echo "[test_devrandom_chacha] OK: $nz_val/256 buckets non-zero"
    fi
    # Absolute cap on the busiest bucket: with lambda=16 a max > 4*lambda=64
    # is essentially impossible for a healthy stream but a degenerate
    # generator blows straight past it.
    expected=$(( total_val / 256 ))
    [ "$expected" -lt 1 ] && expected=1
    max_bound=$(( 4 * expected ))
    if [ -n "$max_val" ] && [ "$max_val" -gt "$max_bound" ]; then
        echo "[test_devrandom_chacha] MISS: max=$max_val > ${max_bound} (4x expected ${expected}/bucket) — degenerate"; fail=1
    else
        echo "[test_devrandom_chacha] OK: busiest bucket max=$max_val within 4x expected (${expected}/bucket)"
    fi
fi

POST_LINE=$(grep -a "\[test_devrandom_chacha\] post " "$LOG" || true)
if [ -z "$POST_LINE" ]; then
    echo "[test_devrandom_chacha] MISS: post-rekey line absent"; fail=1
else
    post_sum=$(printf '%s\n' "$POST_LINE" | sed -n 's/.* sum16=\([0-9]*\).*/\1/p')
    if [ -z "$post_sum" ] || [ "$post_sum" -eq 0 ]; then
        echo "[test_devrandom_chacha] MISS: post-rekey 16-byte sum is zero"; fail=1
    else
        echo "[test_devrandom_chacha] OK: post-rekey stream sum16=$post_sum"
    fi
fi

if [ "$fail" -ne 0 ]; then
    # The fixture demonstrably RAN (boot_gate saw its start), so a violated
    # histogram/rekey assertion is an OBSERVED /dev/random regression.
    verdict_fail "$TAG" \
        "a ChaCha20 /dev/random histogram or post-rekey assertion was" \
        "OBSERVED violated while the fixture ran — real regression" \
        "(the retired xorshift placeholder would fail exactly this way)."
fi

verdict_pass "$TAG" "ChaCha20 /dev/random: total=4096, >=200 nonzero buckets, bounded max, non-zero post-rekey"
