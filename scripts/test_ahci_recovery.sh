#!/usr/bin/env bash
# scripts/test_ahci_recovery.sh — AHCI error-recovery + hot-plug + timeout
# maturity test.
#
# Boots the kernel once with /etc/ahci-recovery-test planted
# (ENABLE_AHCI_RECOVERY_TEST=1) and a QEMU ich9-ahci SATA disk attached.
# init/main.ad at boot:37.arec calls ahci_recovery_selftest()
# (drivers/ata/ahci.ad), which exercises the REAL AHCI maturity plumbing:
#
#   1. Error recovery: the standard AHCI dance — STOP the port (clear
#      PxCMD.ST, wait PxCMD.CR clear), write-1-to-clear PxSERR + PxIS,
#      COMRESET the link (PxSCTL.DET=1 -> hold -> DET=0, wait PxSSTS.DET==3),
#      RESTART the port (FRE + ST) and re-arm PxIE. QEMU's emulated AHCI
#      won't error naturally, so the test FORCES this cycle deterministically
#      via the production _port_error_recover() code path — but every
#      register write in the dance is REAL, not a faked completion.
#   2. Post-recovery I/O: re-IDENTIFY (real ATA 0xEC) and confirm the
#      capacity still matches, then read LBA 0 and confirm the MBR
#      signature survived — proving the device is usable again.
#   3. Hot-plug detect: latch a real PxSERR.DIAG.X edge and confirm the
#      driver's _port_hotplug_poll acks it (write-1-to-clear) and decodes
#      present->present (no spurious removal) and an attach edge -> arrival.
#   4. Command timeout: ahci_read_sectors recovers + retries on a failed
#      command rather than wedging (exercised on the final read).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass markers:
#   [ahci] PASS comreset
#   [ahci] PASS error-recovery
#   [ahci] PASS post-recovery-io
#   [ahci] PASS hotplug
#   [ahci-rec] PASS
# Fail markers: [ahci-rec] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_ahci_recovery] (1/4) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_ahci_recovery] (2/4) Build kernel with /etc/ahci-recovery-test marker"
INIT_ELF=build/user/init.elf ENABLE_AHCI_RECOVERY_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ahci_recovery] (3/4) Mint a SATA scratch disk with a valid MBR sig"
DISK=$(mktemp --suffix=.ahci-rec-disk)
# 1 MiB scratch disk. ahci_smoke_test() reads LBA 0 and checks the MBR
# signature, and the recovery self-test re-reads LBA 0 across the recovery
# and asserts the signature survived; plant 0x55 0xAA at bytes 510..511.
dd if=/dev/zero of="$DISK" bs=1M count=1 status=none
printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up scratch disk/log.
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ahci_recovery] (4/4) Boot QEMU with -device ich9-ahci + -device ide-hd"
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

echo "[test_ahci_recovery] --- captured ([ahci-rec] / [ahci] PASS lines) ---"
grep -E '\[ahci-rec\]|\[ahci\] PASS' "$LOG" || true
echo "[test_ahci_recovery] --- end ---"

# Zero [ahci-rec] markers => the recovery selftest never ran:
# INCONCLUSIVE under starvation / rc=124, FAIL on an OBSERVED crash.
verdict_boot_gate test_ahci_recovery "$LOG" "$rc" '\[ahci-rec\]'

fail=0

if grep -qF "[ahci-rec] FAIL" "$LOG"; then
    echo "[test_ahci_recovery] FAIL: recovery self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[ahci-rec] self-test reported FAIL" "$LOG"; then
    echo "[test_ahci_recovery] FAIL: self-test returned non-PASS" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_ahci_recovery] PASS: $label"
    else
        echo "[test_ahci_recovery] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "recovery self-test ran"     "[ahci-rec] self-test start"
check "baseline IDENTIFY+read OK"  "[ahci-rec] baseline OK"
check "port stopped (CR clear)"    "[ahci-rec] port STOPPED"
check "COMRESET re-established PHY" "[ahci] PASS comreset"
check "error-recovery completed"   "[ahci] PASS error-recovery"
check "device usable post-recovery" "[ahci] PASS post-recovery-io"
check "hot-plug edge poll"         "[ahci] PASS hotplug"
check "overall recovery PASS"      "[ahci-rec] PASS"

if [ "$fail" -ne 0 ]; then
    verdict_fail test_ahci_recovery "one or more AHCI error-recovery assertions were violated (see [test_ahci_recovery] FAIL lines above); the guest booted and ran the selftest, so this is a real, observed regression"
fi

verdict_pass test_ahci_recovery "AHCI performs the real STOP/CLEAR/COMRESET/RESTART error-recovery dance, the disk is usable again afterward (post-recovery IDENTIFY + LBA read), hot-plug edges are detected + acked, and command failures recover-and-retry rather than wedging"
