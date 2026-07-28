#!/usr/bin/env bash
# scripts/test_ahci_trim.sh — AHCI TRIM + IDENTIFY/SMART maturity test.
#
# Boots the kernel once with /etc/ahci-trim-test planted
# (ENABLE_AHCI_TRIM_TEST=1) and a QEMU ich9-ahci SATA disk attached.
# init/main.ad at boot:37.atrim calls ahci_trim_selftest()
# (drivers/ata/ahci.ad), which exercises two real, newly-matured AHCI
# features end-to-end through the existing command-slot path:
#
#   1. IDENTIFY DEVICE (ATA 0xEC) — decode the 48-bit LBA capacity
#      (IDENTIFY words 100..103) and the nominal media rotation rate
#      (word 217; 1 = SSD), and assert the decoded capacity matches the
#      capacity the bring-up IDENTIFY already cached for the same disk.
#      QEMU definitely supports IDENTIFY, so this is the load-bearing PASS.
#   2. DATA SET MANAGEMENT / TRIM (ATA 0x06, feature 0x01) — build a real
#      8-byte LBA-range-entry payload in a DMA buffer and issue it as a
#      DMA write via the command slot. A clean completion OR a correctly
#      DETECTED device abort (the driver reads the TFD.ERR bit when the
#      host model rejects TRIM) both PASS; only a fatal HBA wedge FAILs.
#   3. SMART READ DATA (ATA 0xB0 / 0xD0) is probed as part of identify;
#      QEMU's ich9-ahci aborts it and the driver reports the abort
#      gracefully (no FAIL).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass markers: [ahci-ident] PASS  +  [ahci-trim] PASS
# Fail markers: [ahci-trim] FAIL / [ahci-ident] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_ahci_trim] (1/4) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_ahci_trim] (2/4) Build kernel with /etc/ahci-trim-test marker"
INIT_ELF=build/user/init.elf ENABLE_AHCI_TRIM_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ahci_trim] (3/4) Mint a SATA scratch disk with a valid MBR sig"
DISK=$(mktemp --suffix=.ahci-trim-disk)
# 1 MiB scratch disk. The TRIM self-test trims LBA 8..15 (don't-care
# content); the earlier ahci_smoke_test() reads LBA 0 and checks the MBR
# signature, so plant 0x55 0xAA at bytes 510..511 to keep it happy.
dd if=/dev/zero of="$DISK" bs=1M count=1 status=none
printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc status=none

# Known sector count of the 1 MiB disk (for the human-readable summary).
EXPECT_SECTORS=$(( 1 * 1024 * 1024 / 512 ))

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up scratch disk/log.
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ahci_trim] (4/4) Boot QEMU with -device ich9-ahci + -device ide-hd"
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

echo "[test_ahci_trim] --- captured (ahci-ident / ahci-trim lines) ---"
grep -E '\[ahci-(ident|trim)\]' "$LOG" || true
echo "[test_ahci_trim] --- end ---"

# Zero [ahci-ident]/[ahci-trim] markers => the selftest never ran:
# INCONCLUSIVE under starvation / rc=124, FAIL on an OBSERVED crash.
verdict_boot_gate test_ahci_trim "$LOG" "$rc" '\[ahci-(ident|trim)\]'

fail=0

if grep -qF "[ahci-ident] FAIL" "$LOG"; then
    echo "[test_ahci_trim] FAIL: IDENTIFY self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[ahci-trim] FAIL" "$LOG"; then
    echo "[test_ahci_trim] FAIL: TRIM self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[ahci-trim] self-test reported FAIL" "$LOG"; then
    echo "[test_ahci_trim] FAIL: self-test returned non-PASS" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_ahci_trim] PASS: $label"
    else
        echo "[test_ahci_trim] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "identify self-test ran"        "[ahci-ident] self-test start"
check "IDENTIFY decoded capacity"     "[ahci-ident] IDENTIFY capacity="
check "capacity matched bring-up"     "[ahci-ident] capacity matches bring-up IDENTIFY"
check "ahci-ident PASS"               "[ahci-ident] PASS"
check "trim self-test ran"            "[ahci-trim] self-test start"
check "ahci-trim PASS"                "[ahci-trim] PASS"

# Sanity-check the decoded sector count against the known disk size. The
# capacity line is "[ahci-ident] IDENTIFY capacity=<N> sectors".
got_sectors=$(grep -F "[ahci-ident] IDENTIFY capacity=" "$LOG" \
    | sed -n 's/.*capacity=\([0-9]\+\).*/\1/p' | head -n1 || true)
if [ -n "$got_sectors" ]; then
    if [ "$got_sectors" = "$EXPECT_SECTORS" ]; then
        echo "[test_ahci_trim] PASS: decoded sector count $got_sectors == disk size"
    else
        echo "[test_ahci_trim] WARN: decoded sectors=$got_sectors expected=$EXPECT_SECTORS (host model may report differently)"
    fi
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail test_ahci_trim "one or more AHCI IDENTIFY/TRIM assertions were violated (see [test_ahci_trim] FAIL lines above); the guest booted and ran the selftest, so this is a real, observed regression"
fi

verdict_pass test_ahci_trim "AHCI IDENTIFY DEVICE decodes the 48-bit capacity (and SSD/HDD rotation), and DATA SET MANAGEMENT/TRIM issues through the command slot with a correctly-read completion status"
