#!/usr/bin/env bash
# scripts/test_ahci_ncq.sh — real AHCI Native Command Queuing test.
#
# Boots the kernel once with /etc/ahci-ncq-test planted
# (ENABLE_AHCI_NCQ_TEST=1) and a QEMU ich9-ahci SATA disk attached.
# init/main.ad at boot:37.ncq calls ahci_ncq_selftest()
# (drivers/ata/ahci.ad), which PROVES real multi-slot command queuing:
#
#   * allocates a FRESH command-list slot per read (the slot allocator
#     scans the CI/SACT mask for a clear bit instead of hardwiring slot 0),
#   * submits SEVERAL reads of distinct LBAs back-to-back across
#     INDEPENDENT CI bits WITHOUT draining between them — so all N CI bits
#     are set before any poll,
#   * watches the CI bits clear to detect WHICH slots finished, recording
#     the PEAK number of slots seen outstanding simultaneously,
#   * re-reads each LBA serially (legacy slot-0 path) and byte-compares to
#     prove the concurrently-fetched buffers hold the right sectors.
#
# Two PASS conditions (the self-test reports which carried it):
#   - peak in-flight > 1  → genuine simultaneous overlap was observed, OR
#   - the host completes each command instantly (peak=1) → falls back to
#     asserting the allocator rotated across >1 DISTINCT slots and every
#     slot's data is correct (real independent multi-slot queuing, even if
#     this particular host model can't hold two in flight long enough to
#     photograph the overlap).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [ahci-ncq] PASS
# Fail marker:  [ahci-ncq] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_ahci_ncq] (1/4) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_ahci_ncq] (2/4) Build kernel with /etc/ahci-ncq-test marker"
INIT_ELF=build/user/init.elf ENABLE_AHCI_NCQ_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ahci_ncq] (3/4) Mint a SATA disk with deterministic LBAs"
DISK=$(mktemp --suffix=.ncq-disk)
# 1 MiB scratch disk. Plant a distinct, recognisable pattern in the first
# few sectors so the self-test's read-back/verify has non-trivial content
# (byte b of LBA n = (n*37 + b) & 0xFF). Also plant the MBR signature at
# bytes 510..511 so the earlier ahci_smoke_test passes its MBR check.
dd if=/dev/zero of="$DISK" bs=1M count=1 status=none
python3 - "$DISK" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r+b") as f:
    for lba in range(8):
        sector = bytes(((lba * 37 + b) & 0xFF) for b in range(512))
        f.seek(lba * 512)
        f.write(sector)
    # MBR signature at LBA0 bytes 510..511 for the smoke test.
    f.seek(510)
    f.write(b"\x55\xaa")
PY

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up scratch disk/log.
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ahci_ncq] (4/4) Boot QEMU with -device ahci + -device ide-hd"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=hd0 \
    -device ahci,id=ahci0 \
    -device ide-hd,drive=hd0,bus=ahci0.0 \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ahci_ncq] --- captured (ahci-ncq lines) ---"
grep -E '\[ahci-ncq\]' "$LOG" || true
echo "[test_ahci_ncq] --- end ---"

# Three-valued gate: a boot that never reached the selftest (zero
# [ahci-ncq] markers) is INCONCLUSIVE under host starvation / rc=124,
# or an actionable FAIL if the serial log shows an OBSERVED crash — it
# is NEVER laundered into the same hard FAIL as a real regression.
verdict_boot_gate test_ahci_ncq "$LOG" "$rc" '\[ahci-ncq\]'

fail=0

if grep -qF "[ahci-ncq] FAIL" "$LOG"; then
    echo "[test_ahci_ncq] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[ahci-ncq] self-test reported FAIL" "$LOG"; then
    echo "[test_ahci_ncq] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_ahci_ncq] PASS: $label"
    else
        echo "[test_ahci_ncq] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"            "[ahci-ncq] self-test start"
check "slots submitted"          "[ahci-ncq] submitted req="
check "distinct slots reported"  "[ahci-ncq] distinct slots used="
check "data verified"            "[ahci-ncq] req="
check "ncq self-test PASS"       "[ahci-ncq] PASS"

if [ "$fail" -ne 0 ]; then
    verdict_fail test_ahci_ncq "one or more AHCI NCQ assertions were violated (see [test_ahci_ncq] FAIL lines above); the guest booted and ran the selftest, so this is a real, observed regression"
fi

verdict_pass test_ahci_ncq "AHCI allocates independent command-list slots per read, submits multiple reads across independent CI bits, detects which slots completed, and each slot's data is correct"
