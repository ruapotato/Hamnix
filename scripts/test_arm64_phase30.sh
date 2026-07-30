#!/usr/bin/env bash
# scripts/test_arm64_phase30.sh — PHASE 30 multi-arch milestone: REAL DEVICE I/O
# on bare aarch64 via a native virtio-mmio BLOCK driver.
#
# Not in ci_battery_manifest.txt because it is one RUNG of the standalone aarch64
# ladder that scripts/test_arm64_phase49.sh (which IS registered) runs end to end:
# arch/arm64/kmain.ad executes phases 1..49 in sequence in a SINGLE boot, each rung
# gated on the previous rung's PASS marker, so a regression here stops that boot
# long before "Phase 49 PASS" and reds the registered gate. Registering all 49
# would be 49 identical seed-compiles and 49 identical ~6.5-min TCG boots for one
# signal -- a manifest number going up, not coverage, and ~5 hours against a
# 50-minute shard cap. Kept rather than deleted because when the registered gate
# reds, running the rungs individually is how you find WHICH rung broke; this is
# the on-demand bisection tool for that. Per the USER ruling of 2026-07-30 ARM64
# ships on the LLVM path only, so the hand-written seed backend this lane
# exercises is a frozen regression FIXTURE, not a track under active development.
#
# qemu `-machine virt` exposes 32 virtio-mmio transports starting at 0x0a000000
# (each 0x200 bytes apart). QEMU 10.x presents MODERN (version 2) virtio-mmio.
# Phase 30 (handed off from the Phase-29 verdict) probes those windows for a
# virtio-blk device (MagicValue "virt" + DeviceID 2), brings it up per the
# virtio 1.x spec (reset -> ACKNOWLEDGE -> DRIVER -> ack F_VERSION_1 ->
# FEATURES_OK -> program ONE split virtqueue with descriptor/avail/used rings in
# identity-mapped Normal RAM -> DRIVER_OK), then issues VIRTIO_BLK_T_IN reads of
# sectors 0, 1 and 2 by chaining a header(R)/data(W)/status(W) descriptor triple,
# notifying the device and POLLING the used ring to completion.
#
# This test attaches a raw backing drive whose sector 0 begins with the ASCII tag
# "HAMNIXARM"; the driver reads sector 0 back and asserts the first 8 bytes equal
# that tag (little-endian 0x52415849_4E4D4148), proving a genuine end-to-end
# device read — not a stub.
#
# Phase 30 runs only AFTER Phase 29 prints its PASS marker (the hand-off point),
# so every prior phase (4..29) must still run to completion (no regression).
#
# Prints "[test_arm64_phase30] PASS" on success or "[test_arm64_phase30] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
BRK_OK="[arm64] EL0 page-table brk OK"
SCHED_OK="[arm64] SMP scheduling OK"
SIG_OK="[arm64] EL0 signal delivery OK"
FP_OK="[arm64] EL0 FP context switch OK"
DEMAND_OK="[arm64] EL0 demand paging OK"
UACCESS_OK="[arm64] EL1 safe user access OK"
MMAP_OK="[arm64] EL0 mmap/munmap OK"
MPROT_OK="[arm64] EL0 mprotect OK"
MP_OK="[arm64] EL0 multipage mmap split OK"
P19_OK="[arm64] EL0 dual-address-space ASID sched OK"
P20_OK="[arm64] EL0 dynamic spawn + exit/reaping OK"
P21_OK="[arm64] EL0 nanosleep block/wake scheduling OK"
P22_OK="[arm64] EL0 futex wait/wake scheduling OK"
P23_OK="[arm64] EL0 thread-local storage (TPIDR_EL0) scheduling OK"
P24_PASS="[arm64] Phase 24 PASS"
P25_PASS="[arm64] Phase 25 PASS"
P26_PASS="[arm64] Phase 26 PASS"
P27_PASS="[arm64] Phase 27 PASS"
P28_PASS="[arm64] Phase 28 PASS"
P29_PASS="[arm64] Phase 29 PASS"

PHASE30="[arm64] Phase 30: virtio-mmio block device read (sector 0)"
FOUND="[arm64] Phase 30: found virtio-blk transport @"
LIVE="[arm64] Phase 30: device live (DRIVER_OK), reading sectors"
TAGLINE="[arm64] Phase 30: sector 0 first-8-bytes ="
SUMMARY="[arm64] Phase 30 summary:"
P30_PASS="[arm64] Phase 30 PASS: virtio-blk read sector 0 -> HAMNIXARM"

fail() {
    echo "[test_arm64_phase30] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase30] qemu-system-aarch64 not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y qemu-system-arm >/dev/null 2>&1 || true
    fi
    if command -v qemu-system-aarch64 >/dev/null 2>&1; then
        QEMU="qemu-system-aarch64"
    else
        fail "qemu-system-aarch64 not installed (apt install qemu-system-arm)"
    fi
fi

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase30_test"
mkdir -p "$WORK"
ELF="$WORK/hamnix-arm64.elf"
SERIAL="$WORK/serial.txt"
DISK="$WORK/disk.img"
trap 'rm -rf "$WORK"' EXIT

# --- compile -----------------------------------------------------------
COMPILE_OUT="$(python3 -m compiler.adder compile --target=aarch64-bare-metal \
    "$PROJ_ROOT/arch/arm64/kmain.ad" -o "$ELF" 2>&1)" || fail "compile errored:
$COMPILE_OUT"
echo "$COMPILE_OUT" | grep -q "Compiled to" || fail "compiler did not report success:
$COMPILE_OUT"
[ -f "$ELF" ] || fail "no ELF produced at $ELF"

# --- verify the image is a well-formed AArch64 executable --------------
HDR="$(aarch64-linux-gnu-readelf -h "$ELF" 2>&1)" || \
    HDR="$(readelf -h "$ELF" 2>&1)" || fail "readelf failed on $ELF"
echo "$HDR" | grep -q "Machine: *AArch64" || fail "ELF Machine is not AArch64:
$HDR"

# --- build a raw backing drive with a known tag at sector 0 ------------
# Sector 0 begins with ASCII "HAMNIXARM"; the driver reads it back and asserts
# the first 8 bytes equal "HAMNIXAR" (little-endian 0x52415849_4E4D4148).
TAG="HAMNIXARM"
# 1 MiB raw image (2048 sectors), tag at the very start of sector 0.
dd if=/dev/zero of="$DISK" bs=512 count=2048 status=none || fail "could not create backing image"
printf '%s' "$TAG" | dd of="$DISK" bs=1 conv=notrunc status=none || fail "could not write tag to sector 0"
# Sanity: confirm the tag is actually at sector 0 of the host image.
HOSTTAG="$(dd if="$DISK" bs=1 count=9 status=none 2>/dev/null)"
[ "$HOSTTAG" = "$TAG" ] || fail "host backing image does not carry the tag at sector 0 (got '$HOSTTAG')"

# --- boot under qemu-system-aarch64 with TWO cores + a virtio-blk drive -
# Match the existing arm64 phase scripts' qemu flags (-M virt -cpu cortex-a72
# -smp 2 -nographic -no-reboot), adding the virtio-mmio block device backed by
# the tagged raw image.
timeout 360 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase30] captured serial:"
    sed 's/^/[test_arm64_phase30]   | /' "$SERIAL"
}

# --- guard against any explicit failure markers ------------------------
if grep -q -F "Phase 30 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-30 block driver reported FAIL"
fi
if grep -q -F "Phase 29 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-29 lifecycle reported FAIL (regression)"
fi
if grep -q -F "Phase 28 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-28 scheduler reported FAIL (regression)"
fi
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort paniced the kernel"
fi
if grep -q -F "EL0 non-SVC sync exception" "$SERIAL"; then
    dump_serial
    fail "an unexpected EL0 non-SVC sync exception fired (a task faulted)"
fi

# --- regression: every prior phase must still complete -----------------
grep -q "$BANNER"        "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$BRK_OK"     "$SERIAL" || { dump_serial; fail "Phase-9 brk did not complete — regression"; }
grep -q -F "$SCHED_OK"   "$SERIAL" || { dump_serial; fail "Phase-12 SMP scheduling did not complete — regression"; }
grep -q -F "$SIG_OK"     "$SERIAL" || { dump_serial; fail "Phase-11 signal demo did not complete — regression"; }
grep -q -F "$FP_OK"      "$SERIAL" || { dump_serial; fail "Phase-13 FP context switch did not complete — regression"; }
grep -q -F "$DEMAND_OK"  "$SERIAL" || { dump_serial; fail "Phase-14 demand paging did not complete — regression"; }
grep -q -F "$UACCESS_OK" "$SERIAL" || { dump_serial; fail "Phase-15 safe user access did not complete — regression"; }
grep -q -F "$MMAP_OK"    "$SERIAL" || { dump_serial; fail "Phase-16 mmap/munmap did not complete — regression"; }
grep -q -F "$MPROT_OK"   "$SERIAL" || { dump_serial; fail "Phase-17 mprotect did not complete — regression"; }
grep -q -F "$MP_OK"      "$SERIAL" || { dump_serial; fail "Phase-18 multipage mmap split did not complete — regression"; }
grep -q -F "$P19_OK"     "$SERIAL" || { dump_serial; fail "Phase-19 dual-space ASID sched did not complete — regression"; }
grep -q -F "$P20_OK"     "$SERIAL" || { dump_serial; fail "Phase-20 dynamic spawn + reaping did not complete — regression"; }
grep -q -F "$P21_OK"     "$SERIAL" || { dump_serial; fail "Phase-21 nanosleep block/wake did not complete — regression"; }
grep -q -F "$P22_OK"     "$SERIAL" || { dump_serial; fail "Phase-22 futex wait/wake did not complete — regression"; }
grep -q -F "$P23_OK"     "$SERIAL" || { dump_serial; fail "Phase-23 thread-local storage did not complete — regression"; }
grep -q -F "$P24_PASS"   "$SERIAL" || { dump_serial; fail "Phase-24 demand paging did not complete — regression"; }
grep -q -F "$P25_PASS"   "$SERIAL" || { dump_serial; fail "Phase-25 COW fork did not complete — regression"; }
grep -q -F "$P26_PASS"   "$SERIAL" || { dump_serial; fail "Phase-26 ELF loader did not complete — regression"; }
grep -q -F "$P27_PASS"   "$SERIAL" || { dump_serial; fail "Phase-27 timer round-robin did not complete — regression"; }
grep -q -F "$P28_PASS"   "$SERIAL" || { dump_serial; fail "Phase-28 blocking scheduler did not complete — regression"; }
grep -q -F "$P29_PASS"   "$SERIAL" || { dump_serial; fail "Phase-29 exit/wait/reap did not complete (Phase 30 not reached) — regression"; }

# --- Phase 30 assertions ----------------------------------------------
grep -q -F "$PHASE30" "$SERIAL" || { dump_serial; fail "Phase-30 demo did not start"; }
grep -q -F "$FOUND"   "$SERIAL" || { dump_serial; fail "Phase-30 did not locate a virtio-blk transport"; }
grep -q -F "$LIVE"    "$SERIAL" || { dump_serial; fail "Phase-30 device bring-up (DRIVER_OK) did not complete"; }
grep -q -F "$TAGLINE" "$SERIAL" || { dump_serial; fail "Phase-30 did not print the sector-0 tag line"; }
grep -q -F "$SUMMARY" "$SERIAL" || { dump_serial; fail "Phase-30 summary line not emitted"; }
grep -q -F "$P30_PASS" "$SERIAL" || { dump_serial; fail "'$P30_PASS' not found (Phase 30 did not read the tag back)"; }

# --- parse + assert the readback tag matches the host image ------------
TAG_LINE="$(grep -F "$TAGLINE" "$SERIAL" | head -1)"
GOT_HEX="$(echo "$TAG_LINE" | sed -n 's/.*= \(0x[0-9a-fA-F]*\).*/\1/p')"
[ -n "$GOT_HEX" ] || { dump_serial; fail "could not parse the sector-0 tag hex"; }
# Expected little-endian u64 of "HAMNIXAR": 0x52415849_4E4D4148.
WANT_HEX="0x524158494E4D4148"
GOT_VAL=$((GOT_HEX))
WANT_VAL=$((WANT_HEX))
[ "$GOT_VAL" -eq "$WANT_VAL" ] || { dump_serial; fail "sector-0 tag mismatch: got $GOT_HEX want $WANT_HEX"; }

echo "[test_arm64_phase30] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase30] phase 29 OK (regr)    : $(grep -F "$P29_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase30] phase 30 start        : $(grep -F "$PHASE30" "$SERIAL" | head -1)"
echo "[test_arm64_phase30] transport found       : $(grep -F "$FOUND" "$SERIAL" | head -1)"
echo "[test_arm64_phase30] device live           : $(grep -F "$LIVE" "$SERIAL" | head -1)"
echo "[test_arm64_phase30] sector-0 tag (hex)     : $GOT_HEX (== $WANT_HEX, ASCII HAMNIXAR)"
echo "[test_arm64_phase30] summary line          : $(grep -F "$SUMMARY" "$SERIAL" | head -1)"
echo "[test_arm64_phase30] phase 30 PASS line     : $(grep -F "$P30_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase30] PASS"
