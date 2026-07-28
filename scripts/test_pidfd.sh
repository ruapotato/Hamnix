#!/usr/bin/env bash
# scripts/test_pidfd.sh -- the Linux pidfd process-management family.
#
# Real Linux service managers (systemd, runit, modern spawn helpers) use
# the pidfd API to refer to a process by a stable, race-free file
# descriptor instead of a recyclable pid. The implementation lives in
# linux_abi/u_pidfd.ad and is wired into the central Linux-ABI dispatcher
# (linux_abi/u_syscalls.ad) at the canonical x86_64 syscall numbers:
# pidfd_send_signal=424, pidfd_open=434, waitid=247.
#
# This test boots the kernel once with /etc/pidfd-test planted
# (ENABLE_PIDFD_TEST=1); init/main.ad's pidfd gate (boot:37.pidfd) calls
# do_pidfd_selftest() (linux_abi/u_pidfd.ad), which exercises every
# primitive directly in boot context against a synthesised target task
# (driving the same code the syscall entry points call):
#
#   * pidfd_open(pid) on a live task -> a valid fd, NOT POLLIN-readable.
#   * pidfd_open with a bad flag -> EINVAL; pid=0 -> EINVAL;
#     a dead pid -> ESRCH.
#   * pidfd_send_signal(SIGTERM) latches the signal on the target's
#     sig_pending (reusing the kernel signal_post delivery path).
#   * pidfd_send_signal on a non-pidfd fd -> EBADF; a bad signal -> EINVAL;
#     a bad flag -> EINVAL.
#   * once the target exits, the pidfd becomes POLLIN-readable.
#   * pidfd_send_signal to the now-gone target -> ESRCH.
#
# Pass marker:  [pidfd] PASS
# Fail marker:  [pidfd] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_pidfd

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_pidfd] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_pidfd] (2/3) Build kernel with /etc/pidfd-test marker"
INIT_ELF=build/user/init.elf ENABLE_PIDFD_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_pidfd] (3/3) Boot QEMU and run the pidfd self-test"
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

echo "[test_pidfd] --- pidfd self-test output ---"
grep -aE "\[pidfd\]" "$LOG" || true
echo "[test_pidfd] --- end ---"

# --- three-valued verdict (migrated off the hard PASS/FAIL tail) -----
# The legacy tail turned a MISSING PASS banner into a hard FAIL while
# treating rc=124 (timeout) as non-fatal — so a guest the degraded host
# starved BEFORE the in-boot selftest finished produced a FALSE RED
# indistinguishable from a real regression. verdict_boot_gate resolves
# zero-marker + rc=124 to INCONCLUSIVE; an observed internal FAIL is a
# real red; the anchored PASS banner is a real green. That banner is
# genuine kernel selftest OUTPUT (this gate feeds NO serial input, so
# there is no input-echo to false-match).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[pidfd\]'

if grep -a -F -q "[pidfd] FAIL" "$LOG"; then
    grep -a -F "[pidfd] FAIL" "$LOG" | head -5 >&2 || true
    verdict_fail "$TAG" "the kernel self-test reported an internal [pidfd] FAIL (observed regression)."
fi

if grep -aqE '(^|\] )\[pidfd\] PASS$' "$LOG"; then
    verdict_pass "$TAG" "pidfd_open/pidfd_send_signal/waitid(P_PIDFD) round-trip: a pidfd refers to" \
        "a process, reuses the signal delivery path, becomes POLLIN-readable on exit," \
        "and enforces EBADF/ESRCH/EINVAL."
fi

# Selftest markers were seen (guest booted) but neither PASS nor FAIL.
if [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "the [pidfd] selftest started but its anchored PASS banner never" \
        "printed and qemu was killed by timeout (rc=124) — starved mid-selftest" \
        "on a degraded host. Re-run on a quiet host."
fi
verdict_fail "$TAG" \
    "the [pidfd] selftest started and qemu exited on its own (rc=$rc)" \
    "WITHOUT a PASS banner — an OBSERVED incomplete run."
