#!/usr/bin/env bash
# scripts/test_net_icmp.sh — exercise the M16.91+ ICMP echo path.
#
# After DHCP (or the hardcoded fallback) configures our IP, the
# kernel transmits an ICMP ECHO REQUEST to the SLIRP gateway
# (10.0.2.2). SLIRP's emulated gateway responds with an ECHO REPLY,
# which lands in our RX queue, ip_rx dispatches to icmp_rx, and
# icmp_rx logs "[icmp] echo reply from 10.0.2.2".
#
# The test asserts:
#   1. "[icmp] echo request -> 10.0.2.2" — we transmitted at all
#                                            (TX path live).
#   2. "[icmp] echo reply from 10.0.2.2" — round-trip succeeded
#                                            (RX/parse/dispatch
#                                            all worked).
#
# This is the first proof of two-way IPv4 traffic in the bare-metal
# kernel; it depends on:
#   - virtio_net_tx (M16.91 TX wiring)
#   - eth_tx (M16.91 body, calls virtio_net_tx)
#   - ip_send + ip_csum16 (this milestone)
#   - arp_lookup for the gateway (cached during the ARP probe
#     round-trip from M16.88)
#   - icmp_rx / icmp_send_echo_request (this milestone)

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_icmp] (1/3) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_icmp] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_net_icmp] (3/3) Boot QEMU with virtio-net + SLIRP"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_icmp] --- captured (icmp / dhcp / arp) ---"
grep -E '\[icmp\]|\[dhcp\]|\[arp\]|\[virtio-net\]|\[eth\]' "$LOG" || true
echo "[test_net_icmp] --- end ---"

fail=0
for needle in \
    "[icmp] echo request -> 10.0.2" \
    "[icmp] echo reply from 10.0.2"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_net_icmp] OK: '$needle'"
    else
        echo "[test_net_icmp] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_net_icmp] FAIL (qemu rc=$rc)"
    echo "[test_net_icmp] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_net_icmp] PASS"
