#!/usr/bin/env bash
# scripts/test_arm64_phase32.sh — PHASE 32 multi-arch milestone: LOAD A REAL ELF
# BINARY OFF THE FAT16 DISK and EXECUTE IT AT EL0 on bare aarch64.
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
# Phase 31 parses a read-only FAT16 volume off the native virtio-mmio block
# device and reads HELLO.TXT. Phase 32 (handed off from the Phase-31 PASS)
# COMBINES the Phase-26 AArch64 ELF64 loader with that FAT16 reader: it reads a
# genuine AArch64 ELF EXECUTABLE ("PROG.ELF") out of the SAME FAT16 image,
# parses its header + program headers, maps its PT_LOAD segments (W^X) into a
# fresh EL0 address space, ERETs into e_entry at EL0, and the loaded program
# issues write()/exit() syscalls through the EL0 svc path — proving a real
# on-disk program -> EL0 execution pipeline.
#
# The FAT16 backing disk is built DETERMINISTICALLY in pure Python (no host
# tool dependency): the root dir carries HELLO.TXT (for Phase 31) AND PROG.ELF
# (a hand-assembled minimal AArch64 ELF64 for Phase 32). The PROG.ELF bytes are
# emitted byte-for-byte here so no cross-toolchain is required.
#
# Phase 32 runs only AFTER Phase 31 prints its PASS marker, so every prior phase
# (4..31) must still run to completion (no regression).
#
# Prints "[test_arm64_phase32] PASS" on success or "[test_arm64_phase32] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
P26_PASS="[arm64] Phase 26 PASS"
P27_PASS="[arm64] Phase 27 PASS"
P28_PASS="[arm64] Phase 28 PASS"
P29_PASS="[arm64] Phase 29 PASS"
P30_PASS="[arm64] Phase 30 PASS: virtio-blk read sector 0 -> HAMNIXARM"
P31_PASS="[arm64] Phase 31 PASS: FAT16 read HELLO.TXT -> HAMNIX-ARM64-FS-OK"

PHASE32="[arm64] Phase 32: load a real ELF binary off the FAT16 disk + run at EL0"
FOUND32="[arm64] Phase 32: found PROG.ELF first_clus="
ELFHDR="[arm64] Phase 32 ELF: class64 LSB, machine=AArch64, type=EXEC, entry="
PTLOAD="[arm64] Phase 32 PT_LOAD: vaddr="
SUMMARY="[arm64] Phase 32 summary:"
P32_PASS="[arm64] Phase 32 PASS: loaded PROG.ELF from FAT16 disk and ran it at EL0"

fail() {
    echo "[test_arm64_phase32] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase32] qemu-system-aarch64 not found; attempting apt install"
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
WORK="$PROJ_ROOT/build/arm64_phase32_test"
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

# --- verify the kernel image is a well-formed AArch64 executable -------
HDR="$(aarch64-linux-gnu-readelf -h "$ELF" 2>&1)" || \
    HDR="$(readelf -h "$ELF" 2>&1)" || fail "readelf failed on $ELF"
echo "$HDR" | grep -q "Machine: *AArch64" || fail "ELF Machine is not AArch64:
$HDR"

# --- build a deterministic FAT16 backing disk in pure Python -----------
# A tiny FAT16 superfloppy (LBA 0 = boot sector) whose root directory carries
# HELLO.TXT (Phase 31 payload) AND PROG.ELF (a hand-assembled minimal AArch64
# ELF64 executable for Phase 32). The kernel parses the BPB, scans the root dir,
# follows each file's cluster chain and runs PROG.ELF at EL0.
python3 - "$DISK" <<'PYEOF' || fail "could not build FAT16 disk image"
import sys, struct

disk_path = sys.argv[1]

BPS          = 512        # bytes per sector
SPC          = 1          # sectors per cluster
RESERVED     = 1          # reserved sectors (boot sector)
NUM_FATS     = 2
ROOT_ENT     = 512        # 512 * 32 = 32 sectors of root dir
SEC_PER_FAT  = 16
TOTAL_SECS   = 4096       # 2 MiB volume

HELLO_PAYLOAD = b"HAMNIX-ARM64-FS-OK"

# ---- Phase-32 program syscall ABI (must match kmain.ad constants) -----
SYS_WRITE = 600
SYS_EXIT  = 601
EXIT_CODE = 0x37          # 55

TEXT_VA   = 0x42600000    # PT_LOAD #1 (R+X): code + message
DATA_VA   = 0x42800000    # PT_LOAD #2 (R+W): a few initialised bytes
PAGE      = 0x1000

# File layout: ehdr(64) + 2*phdr(56) = 0xB8 ; text content at TEXT_FOFF=0x120 ;
# message at MSG_OFF=0x100 within the text segment ; data content after that.
TEXT_FOFF = 0x120
MSG_OFF   = 0x100
MSG_VA    = TEXT_VA + MSG_OFF

MESSAGE = b"Hello from a real ELF64 read off the FAT16 disk on aarch64\n"

# ---- minimal AArch64 instruction encoders -----------------------------
def movz(xd, imm16, shift):                  # movz xd, #imm16, lsl #shift
    hw = shift // 16
    return 0xD2800000 | (hw << 21) | ((imm16 & 0xFFFF) << 5) | xd
def movk(xd, imm16, shift):                  # movk xd, #imm16, lsl #shift
    hw = shift // 16
    return 0xF2800000 | (hw << 21) | ((imm16 & 0xFFFF) << 5) | xd
def load_imm64(xd, val):
    return [movz(xd, val & 0xFFFF, 0),
            movk(xd, (val >> 16) & 0xFFFF, 16),
            movk(xd, (val >> 32) & 0xFFFF, 32),
            movk(xd, (val >> 48) & 0xFFFF, 48)]
SVC0 = 0xD4000001                            # svc #0

# ---- the EL0 program: write(1, MSG_VA, len) ; exit(EXIT_CODE) ----------
words = []
words += load_imm64(0, 1)                    # x0 = 1 (fd)
words += load_imm64(1, MSG_VA)               # x1 = message VA
words += load_imm64(2, len(MESSAGE))         # x2 = length
words += load_imm64(8, SYS_WRITE)            # x8 = SYS_WRITE
words.append(SVC0)
words += load_imm64(0, EXIT_CODE)            # x0 = exit code
words += load_imm64(8, SYS_EXIT)             # x8 = SYS_EXIT
words.append(SVC0)

code = b"".join(struct.pack("<I", w) for w in words)
assert len(code) <= MSG_OFF, "code overflows into the message region"

# ---- assemble the ELF file image --------------------------------------
text_seg = bytearray()
text_seg += code
text_seg += b"\x00" * (MSG_OFF - len(code))  # pad code -> message offset
text_seg += MESSAGE
TEXT_FILESZ = len(text_seg)

# 8 initialised data bytes (data segment also carries a small BSS tail).
DATA_BYTES = bytes((0xC0 + i) & 0xFF for i in range(8))
DATA_FILESZ = len(DATA_BYTES)
DATA_MEMSZ  = 0x40

data_foff = TEXT_FOFF + TEXT_FILESZ
data_foff = (data_foff + 7) & ~7             # 8-align

elf = bytearray(data_foff + DATA_FILESZ)

# Elf64_Ehdr
elf[0:4]   = b"\x7fELF"
elf[4]     = 2                               # ELFCLASS64
elf[5]     = 1                               # ELFDATA2LSB
elf[6]     = 1                               # EV_CURRENT
struct.pack_into("<H", elf, 16, 2)           # e_type = ET_EXEC
struct.pack_into("<H", elf, 18, 183)         # e_machine = EM_AARCH64
struct.pack_into("<I", elf, 20, 1)           # e_version
struct.pack_into("<Q", elf, 24, TEXT_VA)     # e_entry
struct.pack_into("<Q", elf, 32, 64)          # e_phoff
struct.pack_into("<H", elf, 52, 64)          # e_ehsize
struct.pack_into("<H", elf, 54, 56)          # e_phentsize
struct.pack_into("<H", elf, 56, 2)           # e_phnum

# Elf64_Phdr #1: text (PT_LOAD, R+X)
p1 = 64
struct.pack_into("<I", elf, p1 + 0,  1)              # p_type = PT_LOAD
struct.pack_into("<I", elf, p1 + 4,  0x4 | 0x1)      # p_flags = R | X
struct.pack_into("<Q", elf, p1 + 8,  TEXT_FOFF)      # p_offset
struct.pack_into("<Q", elf, p1 + 16, TEXT_VA)        # p_vaddr
struct.pack_into("<Q", elf, p1 + 24, TEXT_VA)        # p_paddr
struct.pack_into("<Q", elf, p1 + 32, TEXT_FILESZ)    # p_filesz
struct.pack_into("<Q", elf, p1 + 40, TEXT_FILESZ)    # p_memsz
struct.pack_into("<Q", elf, p1 + 48, PAGE)           # p_align

# Elf64_Phdr #2: data (PT_LOAD, R+W) with a BSS tail
p2 = 64 + 56
struct.pack_into("<I", elf, p2 + 0,  1)              # p_type = PT_LOAD
struct.pack_into("<I", elf, p2 + 4,  0x4 | 0x2)      # p_flags = R | W
struct.pack_into("<Q", elf, p2 + 8,  data_foff)      # p_offset
struct.pack_into("<Q", elf, p2 + 16, DATA_VA)        # p_vaddr
struct.pack_into("<Q", elf, p2 + 24, DATA_VA)        # p_paddr
struct.pack_into("<Q", elf, p2 + 32, DATA_FILESZ)    # p_filesz
struct.pack_into("<Q", elf, p2 + 40, DATA_MEMSZ)     # p_memsz
struct.pack_into("<Q", elf, p2 + 48, PAGE)           # p_align

# segment file content
elf[TEXT_FOFF:TEXT_FOFF + TEXT_FILESZ] = text_seg
elf[data_foff:data_foff + DATA_FILESZ] = DATA_BYTES

PROG_ELF = bytes(elf)

# ---- FAT16 layout -----------------------------------------------------
root_secs = (ROOT_ENT * 32 + BPS - 1) // BPS         # 32
fat_lba   = RESERVED                                 # 1
root_lba  = RESERVED + NUM_FATS * SEC_PER_FAT        # 33
data_lba  = root_lba + root_secs                     # 65

img = bytearray(TOTAL_SECS * BPS)

# ---- boot sector (LBA 0): BPB -----------------------------------------
bs = bytearray(BPS)
bs[0:11]  = b"HAMNIXARM  "                   # jump+OEM overlaid with the P30 tag
struct.pack_into("<H", bs, 11, BPS)
bs[13]    = SPC
struct.pack_into("<H", bs, 14, RESERVED)
bs[16]    = NUM_FATS
struct.pack_into("<H", bs, 17, ROOT_ENT)
struct.pack_into("<H", bs, 19, TOTAL_SECS)
bs[21]    = 0xF8
struct.pack_into("<H", bs, 22, SEC_PER_FAT)
struct.pack_into("<H", bs, 24, 32)
struct.pack_into("<H", bs, 26, 2)
struct.pack_into("<I", bs, 28, 0)
struct.pack_into("<I", bs, 32, 0)
bs[36]    = 0x80
bs[38]    = 0x29
struct.pack_into("<I", bs, 39, 0x12345678)
bs[43:54] = b"HAMNIXVOL  "
bs[54:62] = b"FAT16   "
bs[510]   = 0x55
bs[511]   = 0xAA
img[0:BPS] = bs

# ---- cluster allocation -----------------------------------------------
# HELLO.TXT (18 bytes) -> cluster 2 (one cluster). PROG.ELF -> clusters 3..N.
clus_size = SPC * BPS
def write_clusters(start_clus, payload):
    n = (len(payload) + clus_size - 1) // clus_size
    n = max(n, 1)
    for i in range(n):
        c = start_clus + i
        off = data_lba * BPS + (c - 2) * clus_size
        chunk = payload[i * clus_size:(i + 1) * clus_size]
        img[off:off + len(chunk)] = chunk
    return list(range(start_clus, start_clus + n))

hello_clusters = write_clusters(2, HELLO_PAYLOAD)
prog_start = hello_clusters[-1] + 1
prog_clusters = write_clusters(prog_start, PROG_ELF)

# ---- FAT(s): build the chains -----------------------------------------
def build_fat():
    fat = bytearray(SEC_PER_FAT * BPS)
    struct.pack_into("<H", fat, 0, 0xFFF8)   # media | reserved
    struct.pack_into("<H", fat, 2, 0xFFFF)   # reserved
    def chain(clusters):
        for i, c in enumerate(clusters):
            nxt = clusters[i + 1] if i + 1 < len(clusters) else 0xFFFF
            struct.pack_into("<H", fat, c * 2, nxt)
    chain(hello_clusters)
    chain(prog_clusters)
    return fat

fat = build_fat()
for n in range(NUM_FATS):
    off = (fat_lba + n * SEC_PER_FAT) * BPS
    img[off:off + len(fat)] = fat

# ---- root directory: HELLO.TXT + PROG.ELF -----------------------------
def dir_entry(name83, first_clus, size):
    ent = bytearray(32)
    ent[0:11] = name83
    ent[11]   = 0x20                          # attr = archive
    struct.pack_into("<H", ent, 26, first_clus)
    struct.pack_into("<I", ent, 28, size)
    return ent

root_off = root_lba * BPS
img[root_off:root_off + 32]       = dir_entry(b"HELLO   TXT", hello_clusters[0], len(HELLO_PAYLOAD))
img[root_off + 32:root_off + 64]  = dir_entry(b"PROG    ELF", prog_clusters[0], len(PROG_ELF))

with open(disk_path, "wb") as f:
    f.write(img)

# Self-check.
assert img[510] == 0x55 and img[511] == 0xAA, "bad boot signature"
assert img[root_off:root_off + 11] == b"HELLO   TXT", "HELLO entry wrong"
assert img[root_off + 32:root_off + 43] == b"PROG    ELF", "PROG entry wrong"
poff = data_lba * BPS + (prog_clusters[0] - 2) * clus_size
assert img[poff:poff + 4] == b"\x7fELF", "PROG.ELF magic not at its cluster"
print("[fat16-builder] HELLO clusters=%s PROG clusters=%s PROG.ELF size=%d"
      % (hello_clusters, prog_clusters, len(PROG_ELF)))
print("[fat16-builder] fat_lba=%d root_lba=%d data_lba=%d"
      % (fat_lba, root_lba, data_lba))
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
    echo "[test_arm64_phase32] captured serial:"
    sed 's/^/[test_arm64_phase32]   | /' "$SERIAL"
}

# --- guard against any explicit failure markers ------------------------
if grep -q -F "Phase 32 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-32 ELF loader reported FAIL"
fi
if grep -q -F "Phase 31 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-31 FAT16 parser reported FAIL (regression)"
fi
if grep -q -F "Phase 30 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-30 block driver reported FAIL (regression)"
fi
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort paniced the kernel"
fi
if grep -q -F "EL0 non-SVC sync exception" "$SERIAL"; then
    dump_serial
    fail "an unexpected EL0 non-SVC sync exception fired (a task faulted)"
fi

# --- regression: prior phase milestones must still complete ------------
grep -q "$BANNER"        "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$P26_PASS"   "$SERIAL" || { dump_serial; fail "Phase-26 ELF loader did not complete — regression"; }
grep -q -F "$P27_PASS"   "$SERIAL" || { dump_serial; fail "Phase-27 timer round-robin did not complete — regression"; }
grep -q -F "$P28_PASS"   "$SERIAL" || { dump_serial; fail "Phase-28 blocking scheduler did not complete — regression"; }
grep -q -F "$P29_PASS"   "$SERIAL" || { dump_serial; fail "Phase-29 exit/wait/reap did not complete — regression"; }
grep -q -F "$P30_PASS"   "$SERIAL" || { dump_serial; fail "Phase-30 virtio-blk read did not complete — regression"; }
grep -q -F "$P31_PASS"   "$SERIAL" || { dump_serial; fail "Phase-31 FAT16 read did not complete (Phase 32 not reached) — regression"; }

# --- Phase 32 assertions ----------------------------------------------
grep -q -F "$PHASE32" "$SERIAL" || { dump_serial; fail "Phase-32 demo did not start"; }
grep -q -F "$FOUND32" "$SERIAL" || { dump_serial; fail "Phase-32 did not find PROG.ELF in the root dir"; }
grep -q -F "$ELFHDR"  "$SERIAL" || { dump_serial; fail "Phase-32 did not validate the on-disk ELF header"; }
grep -q -F "$PTLOAD"  "$SERIAL" || { dump_serial; fail "Phase-32 did not map any PT_LOAD segment"; }
grep -q -F "$SUMMARY" "$SERIAL" || { dump_serial; fail "Phase-32 summary line not emitted"; }
grep -q -F "$P32_PASS" "$SERIAL" || { dump_serial; fail "'$P32_PASS' not found (Phase 32 did not run the on-disk ELF at EL0)"; }

echo "[test_arm64_phase32] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase32] phase 31 OK (regr)    : $(grep -F "$P31_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase32] phase 32 start        : $(grep -F "$PHASE32" "$SERIAL" | head -1)"
echo "[test_arm64_phase32] PROG.ELF located       : $(grep -F "$FOUND32" "$SERIAL" | head -1)"
echo "[test_arm64_phase32] ELF header validated  : $(grep -F "$ELFHDR" "$SERIAL" | head -1)"
echo "[test_arm64_phase32] PT_LOAD mapped        : $(grep -F "$PTLOAD" "$SERIAL" | head -1)"
echo "[test_arm64_phase32] summary line          : $(grep -F "$SUMMARY" "$SERIAL" | head -1)"
echo "[test_arm64_phase32] phase 32 PASS line     : $(grep -F "$P32_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase32] PASS"
