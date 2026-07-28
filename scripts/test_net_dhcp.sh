#!/usr/bin/env bash
# scripts/test_net_dhcp.sh — exercise the M16.91+ DHCP client.
#
# The bare-metal kernel's net_smoke_test() sends a DHCPDISCOVER over
# virtio-net to the SLIRP gateway, which acts as a DHCPv4 server
# (RFC-compliant: it offers 10.0.2.15 by default with 10.0.2.2 as
# the router). dhcp_rx() picks up the OFFER, transmits a REQUEST,
# and on ACK installs the lease via ip_set_our_ip / ip_set_gateway.
#
# The test asserts:
#   1. "[dhcp] sending DHCPDISCOVER" — we transmitted at all (proves
#      the TX path through virtio_net_tx is live).
#   2. "[dhcp] got ip=10.0.2.15"     — full discover → offer →
#                                       request → ack round-trip
#                                       completed and the lease
#                                       was installed.
#
# Why SLIRP and not tap: SLIRP includes a built-in DHCP server (see
# QEMU's `slirp/src/bootp.c`) that defaults to handing out 10.0.2.15
# to the first DHCPDISCOVER from a guest. No external dnsmasq /
# elevated privileges needed.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_dhcp] (1/3) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_dhcp] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_net_dhcp] (3/3) Boot QEMU with virtio-net + SLIRP DHCP"
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

echo "[test_net_dhcp] --- captured (dhcp / arp / virtio-net) ---"
grep -E '\[dhcp\]|\[arp\]|\[virtio-net\]|\[icmp\]|\[eth\]' "$LOG" || true
echo "[test_net_dhcp] --- end ---"

fail=0
for needle in \
    "[dhcp] sending DHCPDISCOVER" \
    "[dhcp] got ip=10.0.2.15"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_net_dhcp] OK: '$needle'"
    else
        echo "[test_net_dhcp] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_net_dhcp] FAIL (qemu rc=$rc)"
    echo "[test_net_dhcp] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_net_dhcp] PASS"
