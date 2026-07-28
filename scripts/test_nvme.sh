#!/usr/bin/env bash
# scripts/test_nvme.sh — end-to-end test for the M16.92 native NVMe
# driver. Same shape as scripts/test_ahci.sh but attached via QEMU's
# emulated NVMe controller (`-device nvme`).
#
# Hand-build a 1 MiB tmpfile with a planted 0x55 0xAA at bytes 510..511
# so we get a positive MBR signature read-back without needing a real
# filesystem. The kernel only reads LBA 0 of namespace 1.
#
# Asserts the four canonical lines printed by drivers/nvme/nvme.ad:
#   "[nvme] controller ready"   — CC.EN + CSTS.RDY=1 came up.
#   "[nvme] model="             — IDENTIFY controller returned + decoded.
#   "[nvme] LBAs="              — IDENTIFY namespace returned NSZE.
#   "[nvme] MBR signature OK"   — I/O READ of LBA 0 succeeded and the
#                                 buffer's bytes 510..511 = 0x55 0xAA.
#
# Build lock: source `_build_lock.sh` ONCE here. Do NOT also bash a
# script that sources it (build_user / build_modules / build_iso) —
# they each take the same lock and we'd self-deadlock.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_nvme] (1/4) Rebuild initramfs (uses existing user + modules)"
# If userland hasn't been built yet (cold-cache first run), do it now.
# Otherwise reuse the cached blobs to keep the test under ~10s.
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_nvme] (2/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_nvme] (3/4) Mint a 1 MiB NVMe namespace with valid MBR sig"
DISK=$(mktemp --suffix=.nvme-disk)
dd if=/dev/zero of="$DISK" bs=1M count=1 status=none
printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
# Restore the default initramfs at the end and clean up scratch files
# so subsequent tests don't see whatever /init state we leave behind.
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_nvme] (4/4) Boot QEMU with -device nvme"
set +e
timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=nvme0 \
    -device nvme,drive=nvme0,serial=hamnix1234 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_nvme] --- captured (nvme lines) ---"
grep -E '\[nvme\]' "$LOG" || true
echo "[test_nvme] --- end ---"

fail=0
for needle in \
    "[nvme] controller ready" \
    "[nvme] model=" \
    "[nvme] LBAs=" \
    "[nvme] MBR signature OK"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_nvme] OK: '$needle'"
    else
        echo "[test_nvme] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_nvme] FAIL (qemu rc=$rc)"
    echo "[test_nvme] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_nvme] PASS"
