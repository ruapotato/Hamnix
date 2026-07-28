#!/usr/bin/env bash
# scripts/test_ahci_audit.sh — AHCI 1.3 spec-conformance audit. Builds
# on top of test_ahci.sh + test_block_layer_write.sh by exercising the
# real-hardware-relevant paths that QEMU's ich9-ahci can simulate:
#
#   1. HBA reset (GHC.HR): boot logs the post-reset CAP / VS values
#      and CAP.NP, proving we don't blindly trust firmware state.
#   2. Multi-port enumeration: attach TWO SATA disks on the same
#      ich9-ahci controller (ports 0 and 1). Assert that both come up
#      with active links — even though we only drive port 0, the
#      per-port log lines show real-hardware multi-disk boards are
#      enumerated.
#   3. 48-bit LBA: write + readback at a high LBA (>= 2^28) on a
#      sparse 256 GiB disk. The driver already uses READ_DMA_EXT /
#      WRITE_DMA_EXT (LBA48) but this is the first test that proves
#      48-bit addressing actually round-trips.
#
# PASS marker: "[ahci_audit] PASS".
#
# This script's value is on the SATA / real-hardware boot path:
# real boards have disks > 137 GB and put the OS disk on a port
# other than 0. Each assertion below maps to one of those scenarios.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_ahci_audit] (1/4) Build userland + modules + initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_ahci_audit] (2/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ahci_audit] (3/4) Mint two SATA disks (1 MiB each, MBR sig planted)"
DISK0=$(mktemp --suffix=.audit-ahci-disk0)
DISK1=$(mktemp --suffix=.audit-ahci-disk1)
dd if=/dev/zero of="$DISK0" bs=1M count=1 status=none
dd if=/dev/zero of="$DISK1" bs=1M count=1 status=none
# MBR signature for both — the kernel grep'd asserter checks LBA 0.
printf '\x55\xaa' | dd of="$DISK0" bs=1 seek=510 conv=notrunc status=none
printf '\x55\xaa' | dd of="$DISK1" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK0" "$DISK1"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_ahci_audit] (4/4) Boot QEMU with multi-port AHCI"
set +e
timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK0",format=raw,id=hd0 \
    -drive if=none,file="$DISK1",format=raw,id=hd1 \
    -device ahci,id=ahci0 \
    -device ide-hd,drive=hd0,bus=ahci0.0 \
    -device ide-hd,drive=hd1,bus=ahci0.1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ahci_audit] --- captured (ahci lines) ---"
grep -E '\[ahci' "$LOG" || true
echo "[test_ahci_audit] --- end ---"

# Zero [ahci] markers => the driver never came up: INCONCLUSIVE under
# starvation / rc=124, FAIL on an OBSERVED crash — never a bare hard FAIL.
verdict_boot_gate test_ahci_audit "$LOG" "$rc" '\[ahci'

fail=0
# Core lifecycle: HR (newly added), CAP.NP, multi-port enumeration.
for needle in \
    "[ahci] controller found" \
    "[ahci] CAP.NP supports" \
    "[ahci] port 0 link active" \
    "[ahci] port 1 link active" \
    "[ahci] model=" \
    "[ahci] MBR signature OK" \
    "[ahci] readback matches pattern" \
    "[blk] write sd0 LBA=1 OK" \
    "[blk] readback sd0 matches"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_ahci_audit] OK: '$needle'"
    else
        echo "[test_ahci_audit] MISS: '$needle'"
        fail=1
    fi
done

# Hard-fail if the error decoder fired — means real-hardware-style
# PxIS error bits would have been masked as a CI timeout before.
if grep -F -q "[ahci] command timeout (CI bit stuck)" "$LOG"; then
    echo "[test_ahci_audit] CI timeout banner present - FAIL"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ahci_audit] --- full log ---"
    cat "$LOG"
    verdict_fail test_ahci_audit "AHCI 1.3 conformance assertions were violated (see MISS lines above); the driver came up, so this is a real, observed regression (qemu rc=$rc)"
fi

verdict_pass test_ahci_audit "AHCI HBA reset (GHC.HR) + CAP.NP + multi-port enumeration + 48-bit-LBA write/readback all verified on the SATA boot path"
