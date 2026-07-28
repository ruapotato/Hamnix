#!/usr/bin/env bash
# scripts/test_ahci_blk.sh — AHCI generic block-layer round-trip test.
#
# Boots the kernel once with /etc/ahci-blk-test planted
# (ENABLE_AHCI_BLK_TEST=1) and a QEMU ich9-ahci SATA disk attached.
# init/main.ad at boot:37.ablk calls ahci_blk_selftest()
# (drivers/ata/ahci.ad), which PROVES a SATA disk is reachable through
# the UNIFORM kernel block-layer vtable — the payoff of the AHCI port's
# register_blockdev() wiring:
#
#   * resolves the AHCI disk THROUGH the block layer with
#     find_blockdev("sd0") (a failure here means the port never
#     registered as a block device),
#   * writes a known pattern to a scratch LBA via the GENERIC
#     blk_write_sectors() vtable dispatch (ops.write_sectors ->
#     _ahci_write_sectors_blkop -> ahci_write_sectors), NOT by calling
#     ahci_write_sectors directly,
#   * reads the same LBA back via blk_read_sectors() and byte-compares.
#
# That round-trip is exactly the path ext4 / fat use to mount a disk, so
# a PASS proves an AHCI SATA disk can be mounted through the same generic
# block layer that already backs virtio-blk / ram0 / USB sd0.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [ahci-blk] PASS
# Fail marker:  [ahci-blk] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_ahci_blk] (1/4) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_ahci_blk] (2/4) Build kernel with /etc/ahci-blk-test marker"
INIT_ELF=build/user/init.elf ENABLE_AHCI_BLK_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ahci_blk] (3/4) Mint a SATA scratch disk with a valid MBR sig"
DISK=$(mktemp --suffix=.ahci-blk-disk)
# 1 MiB scratch disk. The self-test writes its own pattern to LBA 2 and
# reads it back, so the on-disk content is don't-care — but the earlier
# ahci_smoke_test() reads LBA 0 and checks the MBR signature, so plant
# 0x55 0xAA at bytes 510..511 to keep that smoke test happy.
dd if=/dev/zero of="$DISK" bs=1M count=1 status=none
printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up scratch disk/log.
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ahci_blk] (4/4) Boot QEMU with -device ich9-ahci + -device ide-hd"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=hd0 \
    -device ich9-ahci,id=ahci0 \
    -device ide-hd,drive=hd0,bus=ahci0.0 \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ahci_blk] --- captured (ahci-blk lines) ---"
grep -E '\[ahci-blk\]' "$LOG" || true
echo "[test_ahci_blk] --- end ---"

# Zero [ahci-blk] markers => the selftest never ran: INCONCLUSIVE under
# starvation / rc=124, FAIL on an OBSERVED crash — never a bare hard FAIL
# indistinguishable from host starvation.
verdict_boot_gate test_ahci_blk "$LOG" "$rc" '\[ahci-blk\]'

fail=0

if grep -qF "[ahci-blk] FAIL" "$LOG"; then
    echo "[test_ahci_blk] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[ahci-blk] self-test reported FAIL" "$LOG"; then
    echo "[test_ahci_blk] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_ahci_blk] PASS: $label"
    else
        echo "[test_ahci_blk] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"             "[ahci-blk] self-test start"
check "sd0 found via block layer" "[ahci-blk] sd0 found at block slot="
check "generic write dispatched"  "[ahci-blk] generic write sd0 LBA=2 OK"
check "generic readback matched"  "[ahci-blk] generic readback sd0 matches"
check "ahci-blk self-test PASS"   "[ahci-blk] PASS"

if [ "$fail" -ne 0 ]; then
    verdict_fail test_ahci_blk "one or more AHCI generic-block-layer assertions were violated (see [test_ahci_blk] FAIL lines above); the guest booted and ran the selftest, so this is a real, observed regression"
fi

verdict_pass test_ahci_blk "AHCI SATA disk reachable through the generic block-layer vtable: find_blockdev(sd0) + blk_write_sectors + blk_read_sectors round-trip verified byte-for-byte"
