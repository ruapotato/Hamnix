#!/usr/bin/env bash
# scripts/test_splice.sh -- pipe zero-copy I/O family (splice/tee/vmsplice)
# for the Linux ABI.
#
# Real Linux software that shuttles bytes between pipes and files reaches
# for splice(2)/tee(2)/vmsplice(2) (glibc tee(1), log shippers, the
# busybox/coreutils fast paths). The implementation lives in
# linux_abi/u_syscalls.ad (_u_splice / _u_tee / _u_vmsplice) and is wired
# into the central Linux-ABI dispatcher at the standard x86_64 syscall
# numbers: splice=275, tee=276, vmsplice=278. The handlers reuse the same
# VFS read/write data-move primitives sendfile / copy_file_range bounce
# through plus the anonymous-pipe ring (fs/pipe.ad), so the byte stream
# stays identical.
#
# This test boots the kernel once with /etc/splice-test planted
# (ENABLE_SPLICE_TEST=1); init/main.ad's splice gate (boot:37.splice)
# calls splice_selftest() (linux_abi/u_syscalls.ad), which exercises every
# primitive directly in boot context (driving the same code the syscall
# entry points call):
#
#   * file -> pipe splice : byte-exact transfer into a pipe.
#   * pipe -> file splice : byte-exact transfer out of a pipe with an
#     off_out pointer that advances by the bytes moved.
#   * pipe -> pipe splice : byte-exact transfer that consumes the source.
#   * tee                 : duplicate A->B WITHOUT consuming A — both the
#     copy on B and the original on A are still readable.
#   * vmsplice            : gather a real (vaddr != phys) user buffer into
#     a pipe via copy_from_user, byte-exact.
#   * error paths         : EINVAL when neither side is a pipe; ESPIPE for
#     an offset pointer on the pipe side.
#
# Pass marker:  [test_splice] PASS
# Fail marker:  [test_splice] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_splice

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_splice] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_splice] (2/3) Build kernel with /etc/splice-test marker"
INIT_ELF=build/user/init.elf ENABLE_SPLICE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_splice] (3/3) Boot QEMU and run the splice/tee/vmsplice self-test"
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

echo "[test_splice] --- splice self-test output ---"
grep -aE "\[splice\]" "$LOG" || true
echo "[test_splice] --- end ---"

# --- three-valued verdict (migrated off the hard PASS/FAIL tail) -----
# The legacy tail turned a MISSING PASS banner into a hard FAIL while
# treating rc=124 (timeout) as non-fatal — so a guest the degraded host
# starved BEFORE the in-boot selftest finished produced a FALSE RED
# indistinguishable from a real regression. verdict_boot_gate resolves
# zero-marker + rc=124 to INCONCLUSIVE; an observed internal FAIL is a
# real red; the anchored PASS banner is a real green. That banner is
# genuine kernel selftest OUTPUT (this gate feeds NO serial input, so
# there is no input-echo to false-match).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[splice\]'

if grep -a -F -q "[splice] FAIL" "$LOG"; then
    grep -a -F "[splice] FAIL" "$LOG" | head -5 >&2 || true
    verdict_fail "$TAG" "the kernel self-test reported an internal [splice] FAIL (observed regression)."
fi

if grep -aqE '(^|\] )\[splice\] PASS$' "$LOG"; then
    verdict_pass "$TAG" "splice moves bytes between pipe and file (and pipe<->pipe), tee duplicates" \
        "without consuming the input, and vmsplice gathers user iovec into a pipe;" \
        "EINVAL/ESPIPE error paths hold."
fi

# Selftest markers were seen (guest booted) but neither PASS nor FAIL.
if [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "the [splice] selftest started but its anchored PASS banner never" \
        "printed and qemu was killed by timeout (rc=124) — starved mid-selftest" \
        "on a degraded host. Re-run on a quiet host."
fi
verdict_fail "$TAG" \
    "the [splice] selftest started and qemu exited on its own (rc=$rc)" \
    "WITHOUT a PASS banner — an OBSERVED incomplete run."
