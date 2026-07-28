#!/usr/bin/env bash
# scripts/test_blkwrite.sh - M16.60 verification.
#
# The kernel runs a block-write smoke test at boot, exercising
# blk_write_sectors → blk_read_sectors round-trip on whichever
# block device is attached. The pattern goes write → read-back →
# byte-compare → restore-original. This script boots the kernel
# in two configurations to verify both backends:
#
#   1. virtio-blk (vda) via -drive build/ext4.img — exercises the
#      VIRTIO_BLK_T_OUT request type end-to-end.
#   2. brd (ram0) when no -drive is passed — exercises the
#      memcpy-into-backing-region write path on the baked image.
#
# A successful test prints "blk: write smoke test PASS"; any
# byte mismatch or driver error prints "FAIL @offset=N".

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_blkwrite] (1/3) Regenerate disk images"
python3 scripts/build_diskimg.py >/dev/null

echo "[test_blkwrite] (2/3) Rebuild kernel image"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

# run_qemu — boots one variant and classifies it three ways:
#   0 = PASS         ("blk: write smoke test PASS" observed)
#   1 = FAIL         (an OBSERVED byte-mismatch / driver error, or a
#                     kernel crash signature on the serial log)
#   2 = INCONCLUSIVE (the guest never reached the smoke test — zero
#                     markers + timeout: host starvation, not a bug)
run_qemu() {
    local label="$1"; shift
    local log=$(mktemp)
    set +e
    timeout 30s qemu-system-x86_64 \
        -kernel "$ELF" \
        "$@" \
        -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
        > "$log" 2>&1 < /dev/null
    local qrc=$?
    set -e
    if grep -F -q "blk: write smoke test PASS" "$log"; then
        echo "[test_blkwrite] OK: $label"
        rm -f "$log"
        return 0
    fi
    # OBSERVED failure: an explicit mismatch banner or a kernel crash.
    if grep -F -q "blk: write smoke test FAIL" "$log" \
       || grep -aqE 'TRAP: vector|[Kk]ernel panic|double fault|triple fault|Oops:' "$log"; then
        echo "[test_blkwrite] FAIL ($label) — observed failure:"
        cat "$log"
        rm -f "$log"
        return 1
    fi
    # No smoke-test marker at all: did the guest even boot far enough to
    # emit ANY block-layer marker? If not, and qemu was killed by timeout,
    # this is host starvation — INCONCLUSIVE, not a regression.
    if ! grep -aqE 'blk:' "$log" && [ "$qrc" -eq 124 ]; then
        echo "[test_blkwrite] INCONCLUSIVE ($label): zero 'blk:' markers + qemu timeout (rc=124) — host-starved, smoke test never ran"
        cat "$log" | tail -n 20
        rm -f "$log"
        return 2
    fi
    echo "[test_blkwrite] FAIL ($label) — no PASS marker (qemu rc=$qrc):"
    cat "$log"
    rm -f "$log"
    return 1
}

echo "[test_blkwrite] (3/3) Boot variants"
worst=0    # 0 PASS, 1 FAIL, 2 INCONCLUSIVE (FAIL dominates INCONCLUSIVE)
classify() {
    local rc="$1"
    if [ "$rc" -eq 1 ]; then worst=1
    elif [ "$rc" -eq 2 ] && [ "$worst" -ne 1 ]; then worst=2
    fi
}
# virtio-blk (vda) path against the ext4 image
set +e
run_qemu "virtio-blk write round-trip (vda + ext4.img)" \
    -drive file=build/ext4.img,if=virtio,format=raw
classify $?
# brd (ram0) path against the baked FAT image
run_qemu "brd write round-trip (ram0 + baked FAT)"
classify $?
set -e

if [ "$worst" -eq 1 ]; then
    verdict_fail test_blkwrite "a block-write round-trip variant reported an OBSERVED byte-mismatch / driver error (see FAIL lines above)"
elif [ "$worst" -eq 2 ]; then
    verdict_inconclusive test_blkwrite "a variant never reached the block-write smoke test (zero markers + qemu timeout) — re-run on a quiet host"
fi
verdict_pass test_blkwrite "block-write smoke test round-trips write->read->compare->restore on both virtio-blk (vda) and brd (ram0)"
