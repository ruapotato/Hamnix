#!/usr/bin/env bash
# scripts/test_pipe_chan.sh — Phase 4c DEV_PIPE_R/DEV_PIPE_W pool-chan gate.
#
# Proves the FD_PIPE_MARK_R/FD_PIPE_MARK_W → DEV_PIPE_R/DEV_PIPE_W fold
# (namespace-purity Phase 4c): vfs_pipe() lands two FD_CHAN_MARK fds
# carrying POOL chan ids (back_slot = pipe ring slot), and every I/O
# surface routes through namec's DEV_PIPE arms:
#
#   * vfs_pipe → namec_open_pipe_end; both fds resolve to the SAME ring
#     slot via namec_chan_pipe_slot.
#   * vfs_waitfds_probe flips 0 → 1 → 0 across a payload round-trip —
#     the namec_poll_readable DEV_PIPE_R arm (EOF-readable contract).
#   * dup (copy_fd_entry) + close of the dup leaves the original
#     readable — the chan-refcount tripwire (LAST close releases the
#     pipe end, not the first).
#   * close writer → probe 1 (EOF readable) + read returns 0.
#   * close reader first → write returns -32 (EPIPE) — the
#     pipe_write_blocking no-readers arm.
#   * vfs_fd_inode yields the 0x43-prefixed per-pipe stable identity
#     (dev_type<<32|slot), R and W ends DISTINCT.
#   * lseek on a pipe fd is rejected (EINVAL, no cursor).
#
# All the work happens in the in-kernel pipechan_selftest() (fs/pipe.ad),
# gated on the cpio marker /etc/pipechan-test — NO serial input needed
# (same input-free shape as test_devfd_chan.sh), so the gate is immune
# to the host's QEMU stdin behavior (the legacy test_pipe.sh /
# test_u35_pipelines.sh gates are serial-input-driven and unusable on
# this host).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO.
#
# Pass marker:  [test_pipe_chan] PASS   (kernel prints [PIPECHAN] PASS)
# Fail marker:  [test_pipe_chan] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_pipe_chan

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PIPECHAN_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_pipe_chan] (1/3) Build userland + plant /etc/pipechan-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PIPECHAN_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_pipe_chan] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_pipe_chan] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_pipe_chan] --- pipechan self-test output ---"
grep -a -E "\[PIPECHAN\]" "$LOG" || true
echo "[test_pipe_chan] --- end ---"

# --- three-valued verdict (migrated off the hard MISS->FAIL tail) -----
# A zero-marker / rc=124 boot on a TCG-starved host used to look identical
# to a real regression. verdict_boot_gate resolves zero-marker+timeout to
# INCONCLUSIVE; an observed [PIPECHAN] FAIL is a real red; the PASS banner
# is a genuine kernel-selftest OUTPUT (this gate feeds NO serial input).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[PIPECHAN\]'

if grep -a -F -q "[PIPECHAN] FAIL" "$LOG"; then
    grep -a -F "[PIPECHAN] FAIL" "$LOG" | head -5 >&2 || true
    verdict_fail "$TAG" "the pipechan self-test reported an internal FAIL (observed regression)."
fi

if grep -a -F -q "[PIPECHAN] PASS" "$LOG"; then
    verdict_pass "$TAG" "pipe() rides DEV_PIPE_R/DEV_PIPE_W pool chans (qemu rc=$rc)."
fi

if [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "the selftest emitted markers but its PASS banner never printed and" \
        "qemu was killed by timeout (rc=124) — starved mid-selftest. Re-run quiet."
fi
verdict_fail "$TAG" \
    "the selftest started and qemu exited on its own (rc=$rc) WITHOUT a PASS" \
    "banner — an OBSERVED incomplete run."
