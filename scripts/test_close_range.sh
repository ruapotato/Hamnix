#!/usr/bin/env bash
# scripts/test_close_range.sh -- close_range(2) + statx(2) for the Linux ABI.
#
# Modern glibc/coreutils reach for close_range(2) (nr 436) to drop a span of
# inherited fds in one trap, and call statx(2) (nr 332) instead of fstat for
# file metadata. Both handlers live in linux_abi/u_syscalls.ad (_u_close_range
# / _u_statx) and are wired into the central Linux-ABI dispatcher at their
# standard x86_64 syscall numbers. close_range routes each live fd through the
# same _u_close path a plain close(2) uses (so the per-fd teardown matches);
# statx fills the struct statx from the same per-backend metadata real fstat
# produces.
#
# This boots the kernel once with /etc/closerange-test planted
# (ENABLE_CLOSERANGE_TEST=1); init/main.ad's gate (boot:37.closerange) calls
# close_range_selftest() (linux_abi/u_syscalls.ad), which drives, in boot
# context, the SAME code the syscall entry points call:
#
#   * statx          : statx a known 8-byte file by path (AT_FDCWD); assert
#                      stx_mask carries STATX_BASIC_STATS, stx_size == 8, and
#                      the mode's S_IFMT bits are S_IFREG.
#   * tee + splice   : tee a payload pipe A -> pipe B (A stays intact), then
#                      splice B -> a file and read it back byte-for-byte.
#   * close_range    : dup a base fd four times, close_range the whole span,
#                      and assert every fd in it is closed (fds outside stay
#                      open); a second close_range over the empty span is a
#                      no-op success; an inverted range is EINVAL.
#
# Pass marker:  [test_close_range] PASS
# Fail marker:  [test_close_range] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_close_range

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_close_range] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_close_range] (2/3) Build kernel with /etc/closerange-test marker"
INIT_ELF=build/user/init.elf ENABLE_CLOSERANGE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_close_range] (3/3) Boot QEMU and run the close_range/statx self-test"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_close_range] --- close_range self-test output ---"
grep -aE "\[closerange\]" "$LOG" || true
echo "[test_close_range] --- end ---"

# --- three-valued verdict (migrated off the hard PASS/FAIL tail) -----
# The legacy tail turned a MISSING PASS banner into a hard FAIL while
# treating rc=124 (timeout) as non-fatal — so a guest the degraded host
# starved BEFORE the in-boot selftest finished produced a FALSE RED
# indistinguishable from a real regression. verdict_boot_gate resolves
# zero-marker + rc=124 to INCONCLUSIVE; an observed internal FAIL is a
# real red; the anchored PASS banner is a real green. The banner is
# genuine kernel selftest OUTPUT (this gate feeds NO serial input, so
# there is no input-echo to false-match).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[closerange\]'

if grep -a -F -q "[closerange] FAIL" "$LOG"; then
    grep -a -F "[closerange] FAIL" "$LOG" | head -5 >&2 || true
    verdict_fail "$TAG" "the kernel self-test reported an internal [closerange] FAIL (observed regression)."
fi

if grep -aqE '(^|\] )\[closerange\] PASS$' "$LOG"; then
    verdict_pass "$TAG" "statx reports size/mode/type, tee+splice moves bytes" \
        "pipe->pipe->file, and close_range closes a span of dup'd fds" \
        "(idempotent re-run + EINVAL on an inverted range)."
fi

# Selftest markers were seen (guest booted) but neither PASS nor FAIL.
if [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "the [closerange] selftest started but its anchored PASS banner never" \
        "printed and qemu was killed by timeout (rc=124) — starved mid-selftest" \
        "on a degraded host. Re-run on a quiet host."
fi
verdict_fail "$TAG" \
    "the [closerange] selftest started and qemu exited on its own (rc=$rc)" \
    "WITHOUT a PASS banner — an OBSERVED incomplete run."
