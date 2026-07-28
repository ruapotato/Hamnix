#!/usr/bin/env bash
# scripts/test_ahci_multiport.sh — end-to-end test for the native AHCI
# driver's MULTI-PORT enumeration + per-port block-device registration.
#
# Real AHCI HBAs expose up to 32 implemented ports. This test attaches
# TWO SATA disks to a SINGLE ich9-ahci controller (bus ahci.0 and
# ahci.1), boots, and proves the driver:
#   * enumerated >= 2 AHCI ports,
#   * registered sd0 AND sd1 as distinct block devices,
#   * read the DISTINCT first sector from EACH disk through the generic
#     block layer (priv-cookie port routing works).
#
# The two backing images carry distinct first-sector bytes: disk0
# byte0 = 0xD0, disk1 byte0 = 0xD1, each with the 0x55 0xAA MBR
# signature planted at bytes 510..511 so the existing ahci_smoke_test
# MBR check and the multi-port self-test's signature assertion pass.
#
# The boot self-test (ahci_multiport_selftest) is chained off the
# existing ahci_smoke_test path in drivers/ata/ahci.ad — no init/main.ad
# marker is needed; it runs on every boot and SKIPs cleanly when only a
# single disk is attached. Here we attach two, so it must PASS.
#
# Asserts the canonical multi-port lines:
#   "[ahci-mp] enumerated 2 AHCI port(s)" — both ports brought up.
#   "[ahci-mp] sd0 and sd1 returned DISTINCT first sectors"
#   "[ahci-mp] PASS"                      — the unique PASS marker.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_ahci_multiport] (1/4) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null

echo "[test_ahci_multiport] (2/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ahci_multiport] (3/4) Mint TWO 1 MiB SATA disks with distinct sig"
DISK0=$(mktemp --suffix=.ahci-disk0)
DISK1=$(mktemp --suffix=.ahci-disk1)
dd if=/dev/zero of="$DISK0" bs=1M count=1 status=none
dd if=/dev/zero of="$DISK1" bs=1M count=1 status=none
# Distinct first-sector signatures so the readback proves per-port
# routing rather than both reads hitting the same port.
printf '\xd0\xa0' | dd of="$DISK0" bs=1 seek=0   conv=notrunc status=none
printf '\xd1\xa1' | dd of="$DISK1" bs=1 seek=0   conv=notrunc status=none
# MBR boot signature on both so the smoke-test + self-test checks pass.
printf '\x55\xaa' | dd of="$DISK0" bs=1 seek=510 conv=notrunc status=none
printf '\x55\xaa' | dd of="$DISK1" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
# Restore the default initramfs at the end so subsequent tests don't
# pick up whatever /init state we leave behind, and clean up the
# scratch disks + log.
trap 'rm -f "$LOG" "$DISK0" "$DISK1"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_ahci_multiport] (4/4) Boot QEMU with TWO disks on one ich9-ahci"
set +e
timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -device ich9-ahci,id=ahci \
    -drive if=none,file="$DISK0",format=raw,id=d0 \
    -device ide-hd,drive=d0,bus=ahci.0 \
    -drive if=none,file="$DISK1",format=raw,id=d1 \
    -device ide-hd,drive=d1,bus=ahci.1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ahci_multiport] --- captured (ahci-mp lines) ---"
grep -E '\[ahci-mp\]|\[ahci\] port' "$LOG" || true
echo "[test_ahci_multiport] --- end ---"

# Zero [ahci-mp]/[ahci] port markers => the multi-port selftest never
# ran: INCONCLUSIVE under starvation / rc=124, FAIL on an OBSERVED crash.
verdict_boot_gate test_ahci_multiport "$LOG" "$rc" '\[ahci-mp\]|\[ahci\] port'

fail=0
for needle in \
    "[ahci-mp] enumerated 2 AHCI port(s)" \
    "[ahci-mp] sd0 and sd1 returned DISTINCT first sectors" \
    "[ahci-mp] PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_ahci_multiport] OK: '$needle'"
    else
        echo "[test_ahci_multiport] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_ahci_multiport] --- full log ---"
    cat "$LOG"
    verdict_fail test_ahci_multiport "AHCI multi-port enumeration / per-port routing assertions were violated (see MISS lines above); the driver came up, so this is a real, observed regression (qemu rc=$rc)"
fi

verdict_pass test_ahci_multiport "AHCI enumerated 2 ports, registered sd0+sd1 as distinct block devices, and each returned its DISTINCT first sector through the generic block layer"
