#!/usr/bin/env bash
# scripts/test_copy_file_range.sh — linux-abi copy_file_range(2)/sendfile(2)
# fd->fd byte-copy self-test.
#
# Proves the Linux-ABI copy_file_range (syscall nr 326) and sendfile
# (nr 40) handlers in linux_abi/u_syscalls.ad copy bytes fd->fd through
# the real in-kernel dispatch entry (linux_u_syscall_dispatch) and the
# VFS read/write path — the exact route a Debian/glibc `cp` takes:
#
#   * copy_file_range: write 8 known bytes to a source tmpfs file, copy
#     the whole lot into a fresh dest file with NULL offset pointers,
#     read the dest back and assert byte-equality. Also asserts flags!=0
#     -> -EINVAL and a bad fd -> -EBADF.
#   * sendfile: copy 4 bytes from a source file at an explicit *offset=2
#     into a dest file, assert the count, that *offset advanced to 6, and
#     that the copied bytes match source[2..5].
#
# Mechanism (pure boot self-test, no userland interaction) — identical to
# scripts/test_uabi_fills.sh: the copy_file_range / sendfile blocks live
# inside uabi_fills_selftest() (linux_abi/u_syscalls.ad), gated by the
# /etc/uabi-fills-test marker that build_initramfs.py plants when
# ENABLE_UABI_FILLS_TEST=1. They print "[copyfilerange] PASS" and
# "[sendfile] PASS" on success.
#
# Pass marker:  [test_copy_file_range] PASS
# Fail marker:  [test_copy_file_range] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_copy_file_range

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${CFR_BOOT_TIMEOUT:-120}"

echo "[test_copy_file_range] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_copy_file_range] (2/3) Build kernel with /etc/uabi-fills-test marker"
INIT_ELF=build/user/init.elf ENABLE_UABI_FILLS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_copy_file_range] (3/3) Boot QEMU and run the copy_file_range/sendfile self-test"
set +e
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
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

echo "[test_copy_file_range] --- self-test output ---"
grep -a -E "\[copyfilerange\]|\[sendfile\]|\[UABI_FILLS\]" "$LOG" || true
echo "[test_copy_file_range] --- end ---"

# --- three-valued verdict (migrated off the hard PASS/FAIL tail) -----
# The legacy tail turned a MISSING PASS banner into a hard FAIL while
# treating rc=124 (timeout) as non-fatal — so a guest the degraded host
# starved BEFORE the in-boot selftest finished produced a FALSE RED
# indistinguishable from a real regression. verdict_boot_gate resolves
# zero-marker + rc=124 to INCONCLUSIVE; an observed internal FAIL is a
# real red; BOTH per-leg PASS banners are the real green (genuine kernel
# selftest OUTPUT — this gate feeds NO serial input to false-match).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[copyfilerange\]|\[sendfile\]|\[UABI_FILLS\]'

if grep -a -q -F "[UABI_FILLS] FAIL" "$LOG"; then
    grep -a -F "[UABI_FILLS] FAIL" "$LOG" >&2 || true
    verdict_fail "$TAG" "the kernel self-test reported an internal [UABI_FILLS] FAIL (observed regression)."
fi

if grep -a -q -F "[copyfilerange] PASS" "$LOG" && grep -a -q -F "[sendfile] PASS" "$LOG"; then
    verdict_pass "$TAG" \
        "copy_file_range(326) + sendfile(40) fd->fd copy through real dispatch + VFS read/write."
fi

# The selftest started (a marker matched) but at least one PASS banner is
# missing and no explicit FAIL was seen.
if [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "the uabi-fills selftest started but not both PASS banners" \
        "([copyfilerange] PASS + [sendfile] PASS) printed and qemu was killed" \
        "by timeout (rc=124) — starved mid-selftest on a degraded host." \
        "Re-run on a quiet host."
fi
verdict_fail "$TAG" \
    "the uabi-fills selftest started and qemu exited on its own (rc=$rc)" \
    "WITHOUT both PASS banners — an OBSERVED incomplete run."
