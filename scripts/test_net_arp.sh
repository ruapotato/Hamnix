#!/usr/bin/env bash
# scripts/test_net_arp.sh — exercise the M16.90 ARP RX path.
#
# The bare-metal kernel's net_smoke_test() transmits an ARP request
# for the SLIRP gateway (10.0.2.2) over virtio-net. SLIRP's emulated
# gateway answers with an ARP reply, the reply lands in our RX
# virtqueue, virtio_net_poll() hands the frame to eth_rx(), eth_rx()
# dispatches by ethertype, and arp_rx() learns the (sender_ip,
# sender_mac) binding and prints a cache-line marker.
#
# The test asserts:
#   1. "[virtio-net] RX packet: len="   → RX path delivered a frame.
#   2. "[arp] cached: 10.0.2.2 -> "     → eth_rx demux + arp_rx
#                                          parser + cache insert all
#                                          worked end-to-end.
#
# Why SLIRP and not tap: tap requires elevated privileges and a host
# bridge; SLIRP only answers ARP-who-has-10.0.2.2 (it doesn't
# spontaneously probe us), but that's enough to validate the RX
# parsing path. The responder side (we receive a REQUEST → we send
# a REPLY) will be tested in a follow-up agent with tap networking.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_arp] (1/3) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_arp] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_net_arp] (3/3) Boot QEMU with virtio-net attached"
LOG=$(mktemp)
# Restore the default /init at the end so subsequent tests / runs
# don't see whatever initramfs state we leave behind.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 15s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_arp] --- captured (net lines) ---"
grep -E '\[virtio-net\]|\[arp\]|\[eth\]' "$LOG" || true
echo "[test_net_arp] --- end ---"

fail=0
for needle in \
    "[virtio-net] RX packet: len=" \
    "[arp] cached: 10.0.2.2 -> "
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_net_arp] OK: '$needle'"
    else
        echo "[test_net_arp] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_net_arp] FAIL (qemu rc=$rc)"
    echo "[test_net_arp] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_net_arp] PASS"
