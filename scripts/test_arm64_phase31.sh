#!/usr/bin/env bash
# scripts/test_arm64_phase31.sh — PHASE 31 multi-arch milestone: parse a REAL
# FILESYSTEM (read-only FAT16) off the native virtio-mmio block device on bare
# aarch64.
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
# Phase 30 brings up the polled virtio-mmio BLOCK driver and proves a raw sector
# read. Phase 31 (handed off from the Phase-30 PASS) reuses that live transport
# and the generalized read-sector primitive to read FILESYSTEM blocks, then
# parses a minimal FAT16 volume INLINE in the kernel:
#   * read + parse the BPB (bytes/sec, sectors/cluster, reserved, #FATs,
#     root-dir entry count, sectors/FAT) and derive the FAT/root/data LBAs,
#   * scan the root directory for the 8.3 file "HELLO   TXT",
#   * follow its cluster chain through FAT16 (>=0xFFF8 = end-of-chain),
#   * read the file's bytes and assert they equal "HAMNIX-ARM64-FS-OK".
#
# This test builds the FAT16 backing disk DETERMINISTICALLY in pure Python (no
# host-tool dependency) — the root dir carries HELLO.TXT with that exact payload.
#
# Phase 31 runs only AFTER Phase 30 prints its PASS marker, so every prior phase
# (4..30) must still run to completion (no regression).
#
# Prints "[test_arm64_phase31] PASS" on success or "[test_arm64_phase31] FAIL ...".

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
P30_PASS="[arm64] Phase 30 PASS: virtio-blk read sector 0 -> HAMNIXARM"

PHASE31="[arm64] Phase 31: parse FAT16 filesystem off virtio-blk"
BPB="[arm64] Phase 31: BPB bps="
LAYOUT="[arm64] Phase 31: layout fat_lba="
FOUND="[arm64] Phase 31: found HELLO.TXT first_clus="
SUMMARY="[arm64] Phase 31 summary:"
P31_PASS="[arm64] Phase 31 PASS: FAT16 read HELLO.TXT -> HAMNIX-ARM64-FS-OK"

fail() {
    echo "[test_arm64_phase31] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase31] qemu-system-aarch64 not found; attempting apt install"
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
WORK="$PROJ_ROOT/build/arm64_phase31_test"
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

# --- build a deterministic FAT16 backing disk in pure Python -----------
# A tiny FAT16 volume (no partition table — a "superfloppy", LBA 0 = boot
# sector) whose root directory contains HELLO.TXT carrying the known payload.
# The kernel parses the BPB, scans the root dir, follows the cluster chain and
# verifies the file bytes equal "HAMNIX-ARM64-FS-OK".
python3 - "$DISK" <<'PYEOF' || fail "could not build FAT16 disk image"
import sys, struct

disk_path = sys.argv[1]

BPS          = 512        # bytes per sector
SPC          = 1          # sectors per cluster (1 -> simplest chain math)
RESERVED     = 1          # reserved sectors (just the boot sector)
NUM_FATS     = 2          # two FATs (standard)
ROOT_ENT     = 512        # root directory entries (512 * 32 = 32 sectors)
SEC_PER_FAT  = 16         # sectors per FAT (ample for a tiny volume)
TOTAL_SECS   = 4096       # 2 MiB volume

PAYLOAD = b"HAMNIX-ARM64-FS-OK"

root_secs = (ROOT_ENT * 32 + BPS - 1) // BPS         # 32
fat_lba   = RESERVED                                 # 1
root_lba  = RESERVED + NUM_FATS * SEC_PER_FAT        # 1 + 32 = 33
data_lba  = root_lba + root_secs                     # 33 + 32 = 65

# Whole image, zero-filled.
img = bytearray(TOTAL_SECS * BPS)

# --- boot sector (LBA 0): BPB the kernel parses ------------------------
# NOTE: Phase 30 (which hands off to Phase 31 only on its OWN success) checks
# that the first 8 bytes of sector 0 equal ASCII "HAMNIXAR". Bytes 0..10 are the
# BPB's jump+OEM area, which the FAT16 parser does NOT read (it starts at the
# bytes/sector field at offset 11). So we plant "HAMNIXARM" across the jump+OEM
# region — satisfying Phase 30's tag check AND leaving a valid FAT16 BPB.
bs = bytearray(BPS)
bs[0:11]  = b"HAMNIXARM  "                   # jump+OEM overlaid with the P30 tag
struct.pack_into("<H", bs, 11, BPS)          # bytes per sector
bs[13]    = SPC                              # sectors per cluster
struct.pack_into("<H", bs, 14, RESERVED)     # reserved sectors
bs[16]    = NUM_FATS                         # number of FATs
struct.pack_into("<H", bs, 17, ROOT_ENT)     # root dir entries
struct.pack_into("<H", bs, 19, TOTAL_SECS)   # total sectors (16-bit)
bs[21]    = 0xF8                             # media descriptor (fixed disk)
struct.pack_into("<H", bs, 22, SEC_PER_FAT)  # sectors per FAT
struct.pack_into("<H", bs, 24, 32)           # sectors per track
struct.pack_into("<H", bs, 26, 2)            # number of heads
struct.pack_into("<I", bs, 28, 0)            # hidden sectors
struct.pack_into("<I", bs, 32, 0)            # total sectors (32-bit)
# Extended boot record (FAT12/16).
bs[36]    = 0x80                             # drive number
bs[38]    = 0x29                             # extended boot signature
struct.pack_into("<I", bs, 39, 0x12345678)   # volume serial
bs[43:54] = b"HAMNIXVOL  "                    # volume label (11 bytes)
bs[54:62] = b"FAT16   "                       # filesystem type (8 bytes)
bs[510]   = 0x55
bs[511]   = 0xAA
img[0:BPS] = bs

# --- file content + cluster chain --------------------------------------
# HELLO.TXT is small (18 bytes) so it occupies exactly one cluster (cluster 2).
first_clus = 2
file_size  = len(PAYLOAD)

# Write the payload into cluster 2's first sector.
clus2_off = data_lba * BPS + (first_clus - 2) * SPC * BPS
img[clus2_off:clus2_off + file_size] = PAYLOAD

# --- FAT(s): mark cluster 2 as end-of-chain ----------------------------
def build_fat():
    fat = bytearray(SEC_PER_FAT * BPS)
    # Reserved entries 0 and 1.
    struct.pack_into("<H", fat, 0, 0xFFF8)   # media | reserved high bits
    struct.pack_into("<H", fat, 2, 0xFFFF)   # reserved
    # Cluster 2 = end-of-chain.
    struct.pack_into("<H", fat, 4, 0xFFFF)
    return fat

fat = build_fat()
for n in range(NUM_FATS):
    off = (fat_lba + n * SEC_PER_FAT) * BPS
    img[off:off + len(fat)] = fat

# --- root directory: one 8.3 entry for HELLO.TXT -----------------------
ent = bytearray(32)
ent[0:11] = b"HELLO   TXT"                   # 8.3 name, space-padded
ent[11]   = 0x20                             # attr = archive
struct.pack_into("<H", ent, 26, first_clus)  # first cluster (low word)
struct.pack_into("<I", ent, 28, file_size)   # file size
root_off = root_lba * BPS
img[root_off:root_off + 32] = ent

with open(disk_path, "wb") as f:
    f.write(img)

# Self-check: re-parse what we wrote.
assert img[510] == 0x55 and img[511] == 0xAA, "bad boot signature"
assert img[root_off:root_off + 11] == b"HELLO   TXT", "root entry name wrong"
assert img[clus2_off:clus2_off + file_size] == PAYLOAD, "payload not at cluster 2"
print("[fat16-builder] BPS=%d SPC=%d RESERVED=%d NUM_FATS=%d ROOT_ENT=%d SEC_PER_FAT=%d"
      % (BPS, SPC, RESERVED, NUM_FATS, ROOT_ENT, SEC_PER_FAT))
print("[fat16-builder] fat_lba=%d root_lba=%d data_lba=%d file_size=%d"
      % (fat_lba, root_lba, data_lba, file_size))
PYEOF

[ -s "$DISK" ] || fail "FAT16 disk image was not created"

# --- boot under qemu-system-aarch64 with a virtio-blk drive ------------
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
    echo "[test_arm64_phase31] captured serial:"
    sed 's/^/[test_arm64_phase31]   | /' "$SERIAL"
}

# --- guard against any explicit failure markers ------------------------
if grep -q -F "Phase 31 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-31 FAT16 parser reported FAIL"
fi
if grep -q -F "Phase 30 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-30 block driver reported FAIL (regression)"
fi
if grep -q -F "Phase 29 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-29 lifecycle reported FAIL (regression)"
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
grep -q -F "$P29_PASS"   "$SERIAL" || { dump_serial; fail "Phase-29 exit/wait/reap did not complete — regression"; }
grep -q -F "$P30_PASS"   "$SERIAL" || { dump_serial; fail "Phase-30 virtio-blk read did not complete (Phase 31 not reached) — regression"; }

# --- Phase 31 assertions ----------------------------------------------
grep -q -F "$PHASE31" "$SERIAL" || { dump_serial; fail "Phase-31 demo did not start"; }
grep -q -F "$BPB"     "$SERIAL" || { dump_serial; fail "Phase-31 did not parse the BPB"; }
grep -q -F "$LAYOUT"  "$SERIAL" || { dump_serial; fail "Phase-31 did not derive the FAT16 layout"; }
grep -q -F "$FOUND"   "$SERIAL" || { dump_serial; fail "Phase-31 did not find HELLO.TXT in the root dir"; }
grep -q -F "$SUMMARY" "$SERIAL" || { dump_serial; fail "Phase-31 summary line not emitted"; }
grep -q -F "$P31_PASS" "$SERIAL" || { dump_serial; fail "'$P31_PASS' not found (Phase 31 did not read the file back)"; }

echo "[test_arm64_phase31] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase31] phase 30 OK (regr)    : $(grep -F "$P30_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase31] phase 31 start        : $(grep -F "$PHASE31" "$SERIAL" | head -1)"
echo "[test_arm64_phase31] BPB parsed            : $(grep -F "$BPB" "$SERIAL" | head -1)"
echo "[test_arm64_phase31] layout derived        : $(grep -F "$LAYOUT" "$SERIAL" | head -1)"
echo "[test_arm64_phase31] HELLO.TXT located      : $(grep -F "$FOUND" "$SERIAL" | head -1)"
echo "[test_arm64_phase31] summary line          : $(grep -F "$SUMMARY" "$SERIAL" | head -1)"
echo "[test_arm64_phase31] phase 31 PASS line     : $(grep -F "$P31_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase31] PASS"
