#!/usr/bin/env bash
# scripts/test_ahci.sh — end-to-end test for the M16.89 native AHCI
# driver. Mirrors the shape of scripts/test_net_virtio.sh: build the
# kernel, attach a SATA disk to QEMU via the ich9-ahci controller,
# boot, and grep the serial log for the driver's diagnostic banners.
#
# Why a hand-built disk image? The kernel only reads sector 0 (the
# MBR), so we don't need a real filesystem — just a 1 MiB tmpfile
# with 0x55 0xAA planted at bytes 510..511 so the MBR signature
# check passes. Building it inline keeps the test hermetic; nothing
# in build/ has to be there before this script runs.
#
# Asserts the four canonical lines:
#   "[ahci] controller found"     — PCI class match worked.
#   "[ahci] port 0 link active"   — SSTS reports an active SATA PHY.
#   "[ahci] model="               — IDENTIFY DEVICE returned and we
#                                    decoded the model string.
#   "[ahci] MBR signature OK"     — READ DMA EXT of LBA 0 returned
#                                    the bytes we planted.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_ahci] (1/4) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null

echo "[test_ahci] (2/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ahci] (3/4) Mint a 1 MiB SATA disk with valid MBR sig"
DISK=$(mktemp --suffix=.ahci-disk)
dd if=/dev/zero of="$DISK" bs=1M count=1 status=none
printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
# Restore the default initramfs at the end so subsequent tests don't
# pick up whatever /init state we leave behind, and clean up the
# scratch disk + log.
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_ahci] (4/4) Boot QEMU with -device ahci + -device ide-hd"
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

echo "[test_ahci] --- captured (ahci lines) ---"
grep -E '\[ahci\]' "$LOG" || true
echo "[test_ahci] --- end ---"

fail=0
for needle in \
    "[ahci] controller found" \
    "[ahci] port 0 link active" \
    "[ahci] model=" \
    "[ahci] MBR signature OK"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_ahci] OK: '$needle'"
    else
        echo "[test_ahci] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_ahci] FAIL (qemu rc=$rc)"
    echo "[test_ahci] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_ahci] PASS"
