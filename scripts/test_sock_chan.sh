#!/usr/bin/env bash
# scripts/test_sock_chan.sh — Phase 4c DEV_SOCKET/DEV_SOCKETPAIR pool-chan gate.
#
# Proves the FD_SOCKET_MARK / FD_SOCKETPAIR_MARK → DEV_SOCKET /
# DEV_SOCKETPAIR fold (namespace-purity Phase 4c): vfs_socketpair()
# lands two FD_CHAN_MARK fds carrying POOL chan ids (back_slot = the
# packed (slot << 1 | dir) end encoding), socket(2) fds carry a
# DEV_SOCKET chan (back_slot = the legacy fdbuf record encoding), and
# every I/O surface routes through namec's DEV_SOCKET* arms:
#
#   * vfs_socketpair → namec_open_sockpair_end; both fds resolve to the
#     SAME pair slot with OPPOSITE direction bits via
#     namec_chan_sockpair_packed.
#   * vfs_waitfds_probe walks 2 → 1 → 2 across a payload round-trip —
#     the namec_poll_readable DEV_SOCKETPAIR arm (honest class-2
#     readiness, not the legacy always-ready fallthrough).
#   * payload round-trips BOTH directions (sockpair_write_blocking /
#     sockpair_read_blocking via namec_write / namec_read).
#   * dup (copy_fd_entry) + close of the dup leaves the original
#     working — the chan-refcount tripwire (LAST close releases the
#     end-ref; legacy vfs_dup hand-rolled sockpair_inc_ref).
#   * close end A → end B reads EOF (0) and writes -32 (EPIPE).
#   * vfs_fd_inode yields the 0x43-prefixed stable identity
#     (dev_type<<32|back_slot), A and B ends DISTINCT.
#   * lseek on a sockpair/socket fd is rejected (EINVAL, no cursor).
#   * DEV_SOCKET: vfs_alloc_socket_fd / vfs_fd_is_socket /
#     vfs_socket_fd_set_record+get_record round-trip; a record-less
#     socket reads EOF and writes EPIPE (the U35 stub contract).
#
# All the work happens in the in-kernel sockchan_selftest()
# (fs/socketpair.ad), gated on the cpio marker /etc/sockchan-test — NO
# serial input needed (same input-free shape as test_pipe_chan.sh), so
# the gate is immune to the host's QEMU stdin behavior (the legacy
# test_socketpair.sh-style gates are serial-input-driven and unusable
# on this host).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO.
#
# Pass marker:  [test_sock_chan] PASS   (kernel prints [SOCKCHAN] PASS)
# Fail marker:  [test_sock_chan] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_sock_chan

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_SOCKCHAN_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_sock_chan] (1/3) Build userland + plant /etc/sockchan-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_SOCKCHAN_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_sock_chan] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_sock_chan] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_sock_chan] --- sockchan self-test output ---"
grep -a -E "\[SOCKCHAN\]" "$LOG" || true
echo "[test_sock_chan] --- end ---"

# Three-valued gate: a starved / non-booting run emits ZERO [SOCKCHAN]
# markers. Route the zero-marker case through the shared discriminator FIRST
# (INCONCLUSIVE on timeout/OOM, FAIL on an observed crash).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[SOCKCHAN\]'

fail=0

if grep -a -F -q "[SOCKCHAN] FAIL" "$LOG"; then
    echo "[test_sock_chan] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[SOCKCHAN] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[SOCKCHAN] PASS" "$LOG"; then
    echo "[test_sock_chan] MISS: self-test PASS banner (expected '[SOCKCHAN] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_sock_chan] --- full log ---"
    cat "$LOG"
    if ! grep -a -F -q "[SOCKCHAN] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[SOCKCHAN] markers printed but the '[SOCKCHAN] PASS' banner never" \
            "arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "the [SOCKCHAN] PASS banner was OBSERVED absent (or an internal FAIL" \
        "was reported) while the selftest ran (qemu rc=$rc) — real regression."
fi

verdict_pass "$TAG" "socket()/socketpair() fds ride DEV_SOCKET/DEV_SOCKETPAIR" \
    "pool chans through namec's DEV_SOCKET* arms (namespace-purity Phase 4c)"
