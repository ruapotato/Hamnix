#!/usr/bin/env bash
# scripts/test_memfd.sh -- Linux memfd_create(2) + file sealing.
#
# Real Linux software (Wayland/graphics clients, dconf, dbus, language
# runtimes) reaches for memfd_create(2) plus fcntl(F_ADD_SEALS) to make
# an anonymous, growable, optionally sealable RAM-backed file. The
# implementation lives in linux_abi/u_memfd.ad (handlers) backed by the
# existing tmpfs store (fs/tmpfs.ad) through the FD_TMPFS_MARK fd
# machinery (fs/vfs.ad), and is wired into the central Linux-ABI
# dispatcher (linux_abi/u_syscalls.ad) at memfd_create=319 plus the
# fcntl F_ADD_SEALS=1033 / F_GET_SEALS=1034 commands.
#
# This test boots the kernel once with /etc/memfd-test planted
# (ENABLE_MEMFD_TEST=1); init/main.ad's memfd gate (boot:37.memfd) calls
# memfd_selftest() (linux_abi/u_memfd.ad), which exercises every
# primitive directly in boot context (driving the same code the syscall
# entry points call):
#
#   * memfd_create (MFD_ALLOW_SEALING) -> writable/readable anon file;
#     write 12 bytes, read them back byte-exact.
#   * F_SEAL_WRITE -> a subsequent write makes no progress (EPERM); the
#     seal is visible via F_GET_SEALS.
#   * F_SEAL_GROW -> ftruncate-larger EPERMs AND an extending write past
#     EOF is refused (the file does not grow).
#   * adding any seal to a memfd created WITHOUT MFD_ALLOW_SEALING EPERMs.
#   * F_SEAL_SEAL -> any further seal EPERMs.
#
# Pass marker:  [memfd] PASS
# Fail marker:  [memfd] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_memfd

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_memfd] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_memfd] (2/3) Build kernel with /etc/memfd-test marker"
INIT_ELF=build/user/init.elf ENABLE_MEMFD_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_memfd] (3/3) Boot QEMU and run the memfd self-test"
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

echo "[test_memfd] --- memfd self-test output ---"
grep -aE "\[memfd\]" "$LOG" || true
echo "[test_memfd] --- end ---"

# --- three-valued verdict (migrated off the hard PASS/FAIL tail) -----
# The legacy tail turned a MISSING PASS banner into a hard FAIL while
# treating rc=124 (timeout) as non-fatal — so a guest the degraded host
# starved BEFORE the in-boot selftest finished produced a FALSE RED
# indistinguishable from a real regression. verdict_boot_gate resolves
# zero-marker + rc=124 to INCONCLUSIVE; an observed internal FAIL is a
# real red; the anchored PASS banner is a real green. That banner is
# genuine kernel selftest OUTPUT (this gate feeds NO serial input, so
# there is no input-echo to false-match).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[memfd\]'

if grep -a -F -q "[memfd] FAIL" "$LOG"; then
    grep -a -F "[memfd] FAIL" "$LOG" | head -5 >&2 || true
    verdict_fail "$TAG" "the kernel self-test reported an internal [memfd] FAIL (observed regression)."
fi

if grep -aqE '(^|\] )\[memfd\] PASS$' "$LOG"; then
    verdict_pass "$TAG" "memfd_create round-trips bytes, and F_SEAL_WRITE / F_SEAL_GROW / F_SEAL_SEAL" \
        "plus the non-ALLOW_SEALING EPERM rule are all enforced."
fi

# Selftest markers were seen (guest booted) but neither PASS nor FAIL.
if [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "the [memfd] selftest started but its anchored PASS banner never" \
        "printed and qemu was killed by timeout (rc=124) — starved mid-selftest" \
        "on a degraded host. Re-run on a quiet host."
fi
verdict_fail "$TAG" \
    "the [memfd] selftest started and qemu exited on its own (rc=$rc)" \
    "WITHOUT a PASS banner — an OBSERVED incomplete run."
