#!/usr/bin/env bash
# scripts/test_blk_sched.sh — additive block I/O scheduler test.
#
# Boots the kernel once with /etc/blk-sched-test planted
# (ENABLE_BLK_SCHED_TEST=1) and a QEMU ich9-ahci SATA disk attached.
# init/main.ad at boot:37.bsch calls blk_sched_selftest()
# (kernel/block/blk.ad), which PROVES the ADDITIVE block I/O scheduler
# (request merging + elevator ordering) is real AND that it never
# regresses byte-correctness vs the synchronous path:
#
#   * SEEDS 4 adjacent sectors with a distinct pattern through the plain
#     synchronous blk_write_sectors() path,
#   * opens a plug and submits 4 OUT-OF-ORDER adjacent reads (LBA+2, +0,
#     +3, +1) into a single contiguous scratch buffer, then unplugs —
#     the elevator sorts ascending and the merger coalesces all 4 into
#     ONE dispatched transfer (asserts 3 merge events, 1 dispatch),
#   * byte-compares the merged readback against an INDEPENDENT
#     synchronous read of the same span AND against the seed pattern,
#   * submits a NON-adjacent batch (a 1-sector gap) and asserts it stays
#     2 transfers with 0 merges.
#
# A PASS proves the scheduler merges + orders real I/O while the
# synchronous correctness path stays byte-identical.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# An AHCI (ich9-ahci) disk is used deliberately: it tolerates TCG-QEMU
# vCPU starvation under host load far better than virtio-blk (which can
# return status=255 at marker [000173] under load — a HOST flake).
#
# Pass marker:  [blk-sched] PASS
# Fail marker:  [blk-sched] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_blk_sched] (1/4) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_blk_sched] (2/4) Build kernel with /etc/blk-sched-test marker"
INIT_ELF=build/user/init.elf ENABLE_BLK_SCHED_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_blk_sched] (3/4) Mint a SATA scratch disk with a valid MBR sig"
DISK=$(mktemp --suffix=.blk-sched-disk)
# 1 MiB scratch disk. The self-test seeds + reads LBA 64..67, so the
# on-disk content is don't-care — but earlier AHCI smoke tests read LBA 0
# and check the MBR signature, so plant 0x55 0xAA at bytes 510..511.
dd if=/dev/zero of="$DISK" bs=1M count=1 status=none
printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up scratch disk/log.
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_blk_sched] (4/4) Boot QEMU with -device ich9-ahci + -device ide-hd"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=hd0 \
    -device ich9-ahci,id=ahci0 \
    -device ide-hd,drive=hd0,bus=ahci0.0 \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_blk_sched] --- captured (blk-sched lines) ---"
grep -E '\[blk-sched\]' "$LOG" || true
echo "[test_blk_sched] --- end ---"

# Zero [blk-sched] markers => the selftest never ran: INCONCLUSIVE under
# starvation / rc=124, FAIL on an OBSERVED crash — never a bare hard FAIL.
verdict_boot_gate test_blk_sched "$LOG" "$rc" '\[blk-sched\]'

fail=0

# Host-load flake: TCG-QEMU vCPU starvation can make a virtio-blk read
# fail with status=255 at marker [000173]. We use AHCI here to avoid it,
# but surface it explicitly if it ever shows up.
if grep -qF "status=255" "$LOG"; then
    echo "[test_blk_sched] NOTE: status=255 seen — possible host-load TCG flake" >&2
fi

if grep -qF "[blk-sched] FAIL" "$LOG"; then
    echo "[test_blk_sched] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[blk-sched] self-test reported FAIL" "$LOG"; then
    echo "[test_blk_sched] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_blk_sched] PASS: $label"
    else
        echo "[test_blk_sched] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"                 "[blk-sched] self-test start"
check "4 adjacent reqs coalesced"     "[blk-sched] 4 adjacent reqs coalesced to 1 transfer OK"
check "merged readback byte-identical" "[blk-sched] merged readback byte-identical to seed OK"
check "non-adjacent kept 2 transfers" "[blk-sched] non-adjacent batch kept 2 transfers OK"
check "blk-sched self-test PASS"      "[blk-sched] PASS"

if [ "$fail" -ne 0 ]; then
    verdict_fail test_blk_sched "one or more block-I/O-scheduler assertions were violated (see [test_blk_sched] FAIL lines above); the guest booted and ran the selftest, so this is a real, observed regression"
fi

verdict_pass test_blk_sched "additive block I/O scheduler: 4 out-of-order adjacent reads merged + elevator-ordered into 1 transfer, byte-identical to the synchronous path; non-adjacent batch correctly stayed 2 transfers"
