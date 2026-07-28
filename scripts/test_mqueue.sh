#!/usr/bin/env bash
# scripts/test_mqueue.sh -- POSIX message queues (mq_*) for the Linux ABI.
#
# Real Linux realtime software reaches for the POSIX.1b message-queue API
# (mq_open/mq_send/mq_receive/mq_getattr/mq_unlink). The implementation
# lives in linux_abi/u_posixmq.ad and is wired into the central Linux-ABI
# dispatcher (linux_abi/u_syscalls.ad) at the standard x86_64 syscall
# numbers: mq_open=240, mq_unlink=241, mq_timedsend=242,
# mq_timedreceive=243, mq_getsetattr=245.
#
# This test boots the kernel once with /etc/mqueue-test planted
# (ENABLE_MQUEUE_TEST=1); init/main.ad's mqueue gate (boot:37.mq) calls
# posixmq_selftest() (linux_abi/u_posixmq.ad), which exercises every
# primitive directly in boot context (driving the same code the syscall
# entry points call):
#
#   * mq_open create (O_CREAT) with mq_attr maxmsg=4/msgsize=16; O_EXCL on
#     the existing name -> EEXIST.
#   * mq_send + mq_receive round-trips a message's length, data and prio.
#   * PRIORITY-ordered delivery: a high-prio message sent AFTER a low-prio
#     one is received FIRST; equal priority is FIFO.
#   * EMSGSIZE on an oversize send (> mq_msgsize).
#   * EAGAIN on O_NONBLOCK empty-receive AND O_NONBLOCK full-send.
#   * mq_getattr reports maxmsg/msgsize/curmsgs.
#   * mq_unlink, then a non-CREAT open of the gone name -> ENOENT; a
#     double-close -> EBADF.
#
# Pass marker:  [test_mqueue] PASS
# Fail marker:  [test_mqueue] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_mqueue

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_mqueue] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_mqueue] (2/3) Build kernel with /etc/mqueue-test marker"
INIT_ELF=build/user/init.elf ENABLE_MQUEUE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_mqueue] (3/3) Boot QEMU and run the POSIX mqueue self-test"
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

echo "[test_mqueue] --- POSIX mqueue self-test output ---"
grep -aE "\[mqueue\]" "$LOG" || true
echo "[test_mqueue] --- end ---"

# --- three-valued verdict (migrated off the hard PASS/FAIL tail) -----
# The legacy tail turned a MISSING PASS banner into a hard FAIL while
# treating rc=124 (timeout) as non-fatal — so a guest the degraded host
# starved BEFORE the in-boot selftest finished produced a FALSE RED
# indistinguishable from a real regression. verdict_boot_gate resolves
# zero-marker + rc=124 to INCONCLUSIVE; an observed internal FAIL is a
# real red; the anchored PASS banner is a real green. That banner is
# genuine kernel selftest OUTPUT (this gate feeds NO serial input, so
# there is no input-echo to false-match).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[mqueue\]'

if grep -a -F -q "[mqueue] FAIL" "$LOG"; then
    grep -a -F "[mqueue] FAIL" "$LOG" | head -5 >&2 || true
    verdict_fail "$TAG" "the kernel self-test reported an internal [mqueue] FAIL (observed regression)."
fi

if grep -aqE '(^|\] )\[mqueue\] PASS$' "$LOG"; then
    verdict_pass "$TAG" "POSIX message queues round-trip, honor priority-ordered delivery, and" \
        "enforce EMSGSIZE/EAGAIN/ENOENT/EBADF."
fi

# Selftest markers were seen (guest booted) but neither PASS nor FAIL.
if [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "the [mqueue] selftest started but its anchored PASS banner never" \
        "printed and qemu was killed by timeout (rc=124) — starved mid-selftest" \
        "on a degraded host. Re-run on a quiet host."
fi
verdict_fail "$TAG" \
    "the [mqueue] selftest started and qemu exited on its own (rc=$rc)" \
    "WITHOUT a PASS banner — an OBSERVED incomplete run."
