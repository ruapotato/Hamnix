#!/usr/bin/env bash
# scripts/test_arm64_phase35.sh — PHASE 35 multi-arch milestone: make the
# virtio-mmio block path WRITABLE on bare aarch64 and prove a real round-trip
# FILESYSTEM write against a writable FAT16 backing disk.
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
# Phases 30/31 proved the polled virtio-mmio block transport can READ raw sectors
# and parse a FAT16 volume. Phase 35 (handed off from the Phase-34 PASS) re-finds
# + re-brings-up the SAME virtio-blk transport and adds the WRITE direction
# (VIRTIO_BLK_T_OUT over the same request virtqueue: out-header descriptor + a
# DEVICE-READABLE data descriptor + the status byte). It proves durability two
# ways, entirely inside kmain.ad:
#   1. RAW round-trip: write a known position-dependent pattern to a high scratch
#      sector (LBA 4000, clear of FS metadata), read it back, confirm 512 bytes.
#   2. FS-level round-trip: rewrite HELLO.TXT's data cluster with NEW bytes
#      ("ARM64-WRITE-OK-A64") and update its directory-entry size on disk, then
#      re-locate the file and re-read it through the normal FAT16 chain READ path,
#      confirming the new content comes back through the real filesystem.
# It prints "[arm64] Phase 35 PASS: ..." only after both verifications succeed.
#
# Phase 35 runs only AFTER Phase 34 prints its PASS marker, so every prior phase
# (4..34) must still run to completion (no regression). The FAT16 image is copied
# to a writable scratch disk per run (deterministic), attached WITHOUT readonly so
# the WRITE path can durably modify it; the virtio-net-device is kept alongside so
# Phases 33/34 still pass.
#
# Prints "[test_arm64_phase35] PASS" on success or "[test_arm64_phase35] FAIL ...".

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
P32_PASS="[arm64] Phase 32 PASS: loaded PROG.ELF from FAT16 disk and ran it at EL0"
P33_PASS="[arm64] Phase 33 PASS: virtio-net ARP round-trip (TX used + RX frame) over virtio-mmio"

PHASE34="[arm64] Phase 34: IPv4/ICMP echo round-trip over native virtio-net"
GW34="[arm64] Phase 34: gateway 10.0.2.2 is at"
TXDONE34="[arm64] Phase 34: TX used-ring completion observed (ICMP request len="
RXVALID34="[arm64] Phase 34: RX Echo Reply validated (icmp_type="
SUMMARY34="[arm64] Phase 34 summary:"
P34_PASS="[arm64] Phase 34 PASS: IPv4/ICMP echo round-trip (ping 10.0.2.2) over native virtio-net"

PHASE35="[arm64] Phase 35: writable virtio-blk + real FAT16 filesystem write"
RAW35="[arm64] Phase 35: raw write->read-back of scratch sector"
WROTE35="[arm64] Phase 35: rewrote HELLO.TXT data cluster + dir size via virtio-blk WRITE"
SUMMARY35="[arm64] Phase 35 summary: raw_ok=1 fs_read_len="
P35_PASS="[arm64] Phase 35 PASS: virtio-blk WRITE + FAT16 filesystem write round-trip -> ARM64-WRITE-OK-A64"

fail() {
    echo "[test_arm64_phase35] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase35] qemu-system-aarch64 not found; attempting apt install"
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
WORK="$PROJ_ROOT/build/arm64_phase35_test"
mkdir -p "$WORK"
ELF="$WORK/hamnix-arm64.elf"
SERIAL="$WORK/serial.txt"
DISK="$WORK/disk.img"          # pristine FAT16 image (never written by QEMU)
SCRATCH="$WORK/scratch.img"    # fresh writable copy QEMU mutates (Phase 35 WRITE)
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

# --- build the SAME deterministic FAT16 backing disk as Phase 32 -------
# (HELLO.TXT for Phase 31 + PROG.ELF for Phase 32) so Phases 30/31/32 still pass.
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

# --- fresh writable scratch copy of the FAT16 image --------------------
# Phase 35 DURABLY writes to the disk (scratch sector + HELLO.TXT cluster + dir
# entry). Copy the pristine image to a fresh scratch file each run so repeated
# runs are deterministic and the source image stays clean. The -drive below
# attaches this scratch copy WITHOUT readonly so VIRTIO_BLK_T_OUT can mutate it.
cp -f "$DISK" "$SCRATCH" || fail "could not create writable scratch disk"
[ -s "$SCRATCH" ] || fail "writable scratch disk was not created"

# --- boot under qemu-system-aarch64: WRITABLE virtio-blk drive + virtio-net ---
# Same flags as the prior arm64 phase scripts, PLUS a virtio-net-device backed
# by QEMU's built-in user-mode network (SLIRP). SLIRP answers ARP for the
# gateway 10.0.2.2 deterministically (Phase 33) and proxies ICMP echo to the
# gateway, giving Phase 34 a real ping reply. The block drive points at the
# writable SCRATCH copy (NOT readonly) so Phase 35's WRITE path is durable.
timeout 360 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$ELF" \
    -drive if=none,file="$SCRATCH",format=raw,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -netdev user,id=n0 \
    -device virtio-net-device,netdev=n0 \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase35] captured serial:"
    sed 's/^/[test_arm64_phase35]   | /' "$SERIAL"
}

# --- guard against any explicit failure markers ------------------------
if grep -q -F "Phase 35 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-35 writable virtio-blk / FAT16 write reported FAIL"
fi
if grep -q -F "Phase 34 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-34 IPv4/ICMP echo reported FAIL (regression)"
fi
if grep -q -F "Phase 33 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-33 virtio-net reported FAIL (regression)"
fi
if grep -q -F "Phase 32 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-32 ELF loader reported FAIL (regression)"
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
grep -q -F "$P31_PASS"   "$SERIAL" || { dump_serial; fail "Phase-31 FAT16 read did not complete — regression"; }
grep -q -F "$P32_PASS"   "$SERIAL" || { dump_serial; fail "Phase-32 on-disk ELF run did not complete — regression"; }
grep -q -F "$P33_PASS"   "$SERIAL" || { dump_serial; fail "Phase-33 virtio-net ARP round-trip did not complete — regression"; }
grep -q -F "$P34_PASS"   "$SERIAL" || { dump_serial; fail "Phase-34 IPv4/ICMP echo round-trip did not complete (Phase 35 not reached) — regression"; }

# --- Phase 34 regression (it must still pass before Phase 35 runs) ------
grep -q -F "$PHASE34"   "$SERIAL" || { dump_serial; fail "Phase-34 demo did not start — regression"; }
grep -q -F "$TXDONE34"  "$SERIAL" || { dump_serial; fail "Phase-34 ICMP request TX used-ring completion not observed — regression"; }
grep -q -F "$RXVALID34" "$SERIAL" || { dump_serial; fail "Phase-34 did not validate an ICMP Echo Reply — regression"; }

# --- Phase 35 assertions ----------------------------------------------
grep -q -F "$PHASE35"   "$SERIAL" || { dump_serial; fail "Phase-35 writable-block demo did not start"; }
grep -q -F "$RAW35"     "$SERIAL" || { dump_serial; fail "Phase-35 raw scratch-sector write->read-back not verified"; }
grep -q -F "$WROTE35"   "$SERIAL" || { dump_serial; fail "Phase-35 FAT16 cluster + dir-size write not performed"; }
grep -q -F "$SUMMARY35" "$SERIAL" || { dump_serial; fail "Phase-35 summary line not emitted"; }
grep -q -F "$P35_PASS"  "$SERIAL" || { dump_serial; fail "'$P35_PASS' not found (Phase 35 did not complete the write round-trip)"; }

echo "[test_arm64_phase35] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase35] phase 33 OK (regr)    : $(grep -F "$P33_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase35] phase 34 OK (regr)    : $(grep -F "$P34_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase35] phase 35 start        : $(grep -F "$PHASE35" "$SERIAL" | head -1)"
echo "[test_arm64_phase35] raw write read-back   : $(grep -F "$RAW35" "$SERIAL" | head -1)"
echo "[test_arm64_phase35] FAT16 cluster rewrite : $(grep -F "$WROTE35" "$SERIAL" | head -1)"
echo "[test_arm64_phase35] summary line          : $(grep -F "$SUMMARY35" "$SERIAL" | head -1)"
echo "[test_arm64_phase35] phase 35 PASS line    : $(grep -F "$P35_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase35] PASS"
