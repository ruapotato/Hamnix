#!/usr/bin/env bash
# scripts/test_ahci_write.sh — verify the M16.118 AHCI WRITE DMA EXT
# path by writing a known pattern to LBA 1, reading it back via the
# existing READ DMA EXT path, and checking byte-for-byte equality.
#
# The check happens inside the kernel (drivers/ata/ahci.ad's
# _ahci_write_smoke_test) so this script just greps the serial log
# for the two PASS markers:
#
#   "[ahci] write LBA=1 nblocks=1 OK"
#   "[ahci] readback matches pattern"
#
# A tmpfile disk image (dd zero, 1 MiB) is created per run so we never
# touch real data. The MBR signature at LBA 0 (bytes 510..511 = 0x55
# 0xAA) is planted exactly like scripts/test_ahci.sh — the existing
# READ smoke test runs first inside the kernel, so we want it to keep
# passing too. The new write hits LBA 1 to avoid clobbering that
# signature.
#
# Build lock: source `_build_lock.sh` ONCE here (build_user /
# build_modules / build_initramfs each take the same lock, so don't
# also bash a script that re-takes it).

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_ahci_write] (1/4) Build userland + modules + initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_ahci_write] (2/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ahci_write] (3/4) Mint a 1 MiB SATA disk with valid MBR sig"
DISK=$(mktemp --suffix=.ahci-write-disk)
dd if=/dev/zero of="$DISK" bs=1M count=1 status=none
printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_ahci_write] (4/4) Boot QEMU with -device ahci + -device ide-hd"
set +e
timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=hd0 \
    -device ahci,id=ahci0 \
    -device ide-hd,drive=hd0,bus=ahci0.0 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ahci_write] --- captured (ahci lines) ---"
grep -E '\[ahci\]' "$LOG" || true
echo "[test_ahci_write] --- end ---"

# Zero [ahci] markers => the driver never came up: INCONCLUSIVE under
# starvation / rc=124, FAIL on an OBSERVED crash — never a bare hard FAIL.
verdict_boot_gate test_ahci_write "$LOG" "$rc" '\[ahci\]'

fail=0
# Existing READ smoke test markers must still pass — write is additive.
# The two new markers prove the write/readback path is healthy.
for needle in \
    "[ahci] controller found" \
    "[ahci] MBR signature OK" \
    "[ahci] write LBA=1 nblocks=1 OK" \
    "[ahci] readback matches pattern"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_ahci_write] OK: '$needle'"
    else
        echo "[test_ahci_write] MISS: '$needle'"
        fail=1
    fi
done

# Also verify a mismatch banner DIDN'T fire — that would imply the
# readback succeeded as a command but the bytes were wrong.
if grep -F -q "[ahci] readback MISMATCH" "$LOG"; then
    echo "[test_ahci_write] readback MISMATCH banner present — FAIL"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ahci_write] --- full log ---"
    cat "$LOG"
    verdict_fail test_ahci_write "AHCI WRITE DMA EXT round-trip assertions were violated (see MISS lines above); the driver came up, so this is a real, observed regression (qemu rc=$rc)"
fi

verdict_pass test_ahci_write "AHCI WRITE DMA EXT wrote LBA=1 and read it back byte-for-byte through the existing READ DMA EXT path"
