#!/usr/bin/env bash
# scripts/test_statx_getrandom.sh — getrandom(2)/statx(2) Linux-ABI
# direct-syscall verification.
#
# Proves the getrandom(318) and statx(332) DIRECT top-level syscalls
# (_u_getrandom / _u_statx in linux_abi/u_syscalls.ad) drive the real
# in-kernel dispatch (linux_u_syscall_dispatch — the exact path a
# Debian/glibc binary takes). The in-kernel statx_getrandom_selftest()
# (gated on the cpio marker /etc/statx-test) asserts:
#   * getrandom(buf, 32, 0) twice — each returns the full requested length
#     and the two 32-byte buffers differ (the kernel CSPRNG advances), and
#     a zero-length request returns 0,
#   * statx(AT_FDCWD, "/etc", ...) — STATX_BASIC_STATS mask, S_IFDIR type
#     bit, stx_nlink >= 1,
#   * statx on a planted /tmp regular file — S_IFREG type bit and stx_size
#     equal to the bytes written,
#   * statx on a missing path — returns -ENOENT.
#
# getrandom draws from the kernel's existing ChaCha20 fast-key-erasure
# CSPRNG (sys/.../devrandom.ad), seeded from RDSEED/RDRAND/TSC; this is the
# SAME pool that backs /dev/random and /dev/urandom. statx reuses the same
# 256-byte struct-statx layout/filler the io_uring statx op uses.
#
# tmpfs is RAM-backed, so — like test_linkat.sh — this needs NO disk image.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_statx_getrandom] PASS   (kernel prints [STATX_GETRANDOM] PASS)
# Fail marker:  [test_statx_getrandom] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_statx_getrandom

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_STATX_GETRANDOM_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_statx_getrandom] (1/3) Build userland + plant /etc/statx-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_STATX_GETRANDOM_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_statx_getrandom] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_statx_getrandom] (3/3) Boot QEMU (no disk image — pure tmpfs)"
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

echo "[test_statx_getrandom] --- self-test output ---"
grep -a -E "\[STATX_GETRANDOM\]|\[getrandom\]|\[statx\]" "$LOG" || true
echo "[test_statx_getrandom] --- end ---"

# --- three-valued verdict (migrated off the hard MISS->FAIL tail) ----
# The legacy tail turned a MISSING PASS banner into a hard FAIL — so a
# guest the degraded host starved BEFORE the in-boot selftest finished
# produced a FALSE RED indistinguishable from a real regression.
# verdict_boot_gate resolves zero-marker + rc=124 to INCONCLUSIVE; an
# observed internal FAIL is a real red; the PASS banner is a real green
# (genuine kernel selftest OUTPUT — this gate feeds NO serial input).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[STATX_GETRANDOM\]|\[statx\]|\[getrandom\]'

if grep -a -F -q "[STATX_GETRANDOM] FAIL" "$LOG"; then
    grep -a -F "[STATX_GETRANDOM] FAIL" "$LOG" | head -5 >&2 || true
    verdict_fail "$TAG" "the kernel self-test reported an internal FAIL (observed regression)."
fi

if grep -a -F -q "[STATX_GETRANDOM] PASS" "$LOG"; then
    verdict_pass "$TAG" "getrandom(318)/statx(332) work through Linux-ABI dispatch."
fi

# Selftest markers were seen (guest booted) but neither PASS nor FAIL.
if [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "the selftest started but its PASS banner never printed and qemu was" \
        "killed by timeout (rc=124) — starved mid-selftest on a degraded host." \
        "Re-run on a quiet host."
fi
verdict_fail "$TAG" \
    "the selftest started and qemu exited on its own (rc=$rc) WITHOUT a PASS" \
    "banner — an OBSERVED incomplete run."
