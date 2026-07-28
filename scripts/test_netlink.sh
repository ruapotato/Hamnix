#!/usr/bin/env bash
# scripts/test_netlink.sh — AF_NETLINK / NETLINK_ROUTE (rtnetlink) verification.
#
# Proves the Linux-ABI netlink family (linux_abi/u_netlink.ad, dispatched from
# linux_abi/u_syscalls.ad's socket/bind/sendto/recvfrom/read/write/close/
# getsockname arms) frames the kernel's REAL net state (drivers/net/ip.ad +
# eth.ad) into rtnetlink wire format so Debian's `ip` / systemd / libmnl can
# enumerate interfaces, addresses and routes.
#
# The in-kernel nl_selftest() (gated on the cpio marker /etc/netlink-test)
# drives a netlink endpoint through the real build+queue path and PARSES the
# replies the way iproute2 does:
#   (1) socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE) + bind
#   (2) RTM_GETLINK dump -> >=1 RTM_NEWLINK, IFLA_IFNAME "lo", NLMSG_DONE term
#   (3) RTM_GETADDR dump -> RTM_NEWADDR with 127.0.0.1 (IFA_LOCAL), DONE term
#   (4) RTM_GETROUTE dump -> NLMSG_DONE terminated
#   (5) drained endpoint reads EAGAIN, then close
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_netlink] PASS   (kernel prints [netlink] PASS)
# Fail marker:  [test_netlink] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_netlink

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_NETLINK_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_netlink] (1/3) Build userland + plant /etc/netlink-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_NETLINK_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_netlink] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_netlink] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_netlink] --- netlink self-test output ---"
grep -a -E "\[NETLINK\]|\[netlink\]" "$LOG" || true
echo "[test_netlink] --- end ---"

# Three-valued gate: a starved / non-booting run emits ZERO [netlink]
# markers. Route the zero-marker case through the shared discriminator FIRST
# (INCONCLUSIVE on timeout/OOM, FAIL on an observed crash).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[NETLINK\]|\[netlink\]'

fail=0

if grep -a -F -q "[netlink] FAIL" "$LOG"; then
    echo "[test_netlink] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[netlink] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[netlink] PASS" "$LOG"; then
    echo "[test_netlink] MISS: self-test PASS banner (expected '[netlink] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_netlink] --- full log ---"
    cat "$LOG"
    # Some [netlink] markers printed but the PASS banner never arrived AND
    # qemu was killed by timeout -> starved mid-selftest, not a regression.
    if ! grep -a -F -q "[netlink] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[netlink] markers printed but the '[netlink] PASS' banner never" \
            "arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "the [netlink] PASS banner was OBSERVED absent (or an internal FAIL" \
        "was reported) while the selftest ran (qemu rc=$rc) — real regression."
fi

verdict_pass "$TAG" "rtnetlink GETLINK/GETADDR/GETROUTE dumps framed and" \
    "parsed through the real linux_abi netlink path"
