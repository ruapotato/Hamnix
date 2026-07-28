#!/usr/bin/env bash
# scripts/test_net_virtio.sh — end-to-end test for the M16.88
# bare-metal virtio-net PCI driver.
#
# Boots the kernel with a QEMU virtio-net device attached to SLIRP.
# The kernel's start_kernel() → net_smoke_test() path probes PCI,
# brings the driver up, reads the MAC from device config space,
# transmits one ARP request for the SLIRP gateway (10.0.2.2), and
# polls the RX used ring until the gateway's ARP reply arrives.
#
# The test asserts:
#   1. "[virtio-net] mac=52:54:00:12:34:56" appears  → MAC config
#      read worked end-to-end (PCI BAR + legacy IO + per-byte inb).
#   2. "[virtio-net] RX packet: len=" appears        → RX virtqueue
#      delivered at least one frame to eth_rx().
#
# Inside-the-guest helper: the kernel transmits the ARP itself; we
# don't drive any helper from outside. SLIRP's emulated gateway
# answers spontaneously to ARP-who-has-10.0.2.2.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_virtio] (1/3) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_virtio] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_net_virtio] (3/3) Boot QEMU with virtio-net attached"
LOG=$(mktemp)
# Restore the default /init at the end so subsequent tests / runs
# don't see whatever initramfs state we leave behind.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 15s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0,hostfwd=tcp::5555-:23 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_virtio] --- captured (virtio-net lines) ---"
grep -E '\[virtio-net\]|eth_rx' "$LOG" || true
echo "[test_net_virtio] --- end ---"

fail=0
for needle in \
    "[virtio-net] mac=52:54:00:12:34:56" \
    "[virtio-net] RX packet: len="
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_net_virtio] OK: '$needle'"
    else
        echo "[test_net_virtio] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_net_virtio] FAIL (qemu rc=$rc)"
    echo "[test_net_virtio] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_net_virtio] PASS"
