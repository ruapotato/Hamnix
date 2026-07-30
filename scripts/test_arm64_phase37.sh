#!/usr/bin/env bash
# scripts/test_arm64_phase37.sh — PHASE 37 multi-arch milestone: a REAL BLOCKING
# in-kernel PIPE for IPC between TWO on-disk EL0 user processes running CONCURRENTLY
# under the live preemptive timer scheduler on bare aarch64 (qemu-virt).
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
# Handed off from the Phase-36 PASS, the kernel:
#   1. reads PRODA.ELF (producer) and CONSB.ELF (consumer) off the FAT16 disk and
#      builds a fresh private ASID-tagged EL0 address space for each;
#   2. runs BOTH at EL0 concurrently — the EL1 generic-timer IRQ round-robins the
#      two private (TTBR0+ASID) spaces;
#   3. the CONSUMER pipe_read()s an EMPTY pipe and GENUINELY BLOCKS (it is
#      descheduled into a BLOCKED state, parked on a self-loop, and SKIPPED by the
#      round-robin picker — it is NOT spinning);
#   4. the PRODUCER pipe_write()s a known 24-byte sequence into the kernel ring
#      buffer; the write DELIVERS the queued bytes into the blocked consumer's
#      backing pages, sets its resumed read() return value, and WAKES it
#      (BLOCKED -> RUNNABLE);
#   5. the consumer resumes, receives the full sequence, report()s the received
#      bytes (the kernel cross-checks them byte-for-byte against the known
#      sequence), and exit(0x44)s; the producer exit(0x33)s;
#   6. the kernel runs the verdict and prints "[arm64] Phase 37 PASS: ...".
#
# EL0 syscalls exercised: pipe_write(710)/pipe_read(711)/report(712)/exit(713).
# The PASS is kernel-verified: the consumer cannot fake the round-trip (the kernel
# compares the reported received bytes against the known producer sequence, and the
# verdict requires that the consumer actually blocked AND was woken by the write).
#
# Phase 37 runs only AFTER Phase 36 prints its PASS marker, so every prior phase
# (4..36) must still run to completion (no regression).
#
# Prints "[test_arm64_phase37] PASS" on success or "[test_arm64_phase37] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
P30_PASS="[arm64] Phase 30 PASS: virtio-blk read sector 0 -> HAMNIXARM"
P31_PASS="[arm64] Phase 31 PASS: FAT16 read HELLO.TXT -> HAMNIX-ARM64-FS-OK"
P32_PASS="[arm64] Phase 32 PASS: loaded PROG.ELF from FAT16 disk and ran it at EL0"
P35_PASS="[arm64] Phase 35 PASS: virtio-blk WRITE + FAT16 filesystem write round-trip -> ARM64-WRITE-OK-A64"
P36_PASS="[arm64] Phase 36 PASS: multi-process FAT16 userland (INITA file round-trip + spawned CHILDB + reaped exit status + ordering)"

PHASE37="[arm64] Phase 37: blocking in-kernel pipe IPC (two on-disk EL0 processes: PRODA + CONSB)"
READA37="[arm64] Phase 37: read PRODA.ELF off disk"
READB37="[arm64] Phase 37: read CONSB.ELF off disk"
LAUNCH37="[arm64] Phase 37: launching producer PRODA (ASID 26) + consumer CONSB (ASID 27) concurrently"
BLOCK37="[arm64] Phase 37: consumer pipe_read on EMPTY pipe -> BLOCKED"
WAKE37="[arm64] Phase 37: write woke the BLOCKED consumer"
SUMMARY37="[arm64] Phase 37 summary: bytes_written="
P37_PASS="[arm64] Phase 37 PASS: pipe IPC blocking round-trip"

fail() {
    echo "[test_arm64_phase37] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase37] qemu-system-aarch64 not found; attempting apt install"
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
WORK="$PROJ_ROOT/build/arm64_phase37_test"
mkdir -p "$WORK"
ELF="$WORK/hamnix-arm64.elf"
SERIAL="$WORK/serial.txt"
DISK="$WORK/disk.img"          # pristine FAT16 image (never written by QEMU)
SCRATCH="$WORK/scratch.img"    # fresh writable copy QEMU mutates
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

# --- build the FAT16 backing disk: prior-phase files (HELLO/PROG/INITA/CHILDB
#     + WORK.TXT/MARK.TXT) plus Phase-37 PRODA.ELF + CONSB.ELF ----------
python3 - "$DISK" <<'PYEOF' || fail "could not build FAT16 disk image"
import sys, struct

disk_path = sys.argv[1]

BPS          = 512
SPC          = 1
RESERVED     = 1
NUM_FATS     = 2
ROOT_ENT     = 512
SEC_PER_FAT  = 16
TOTAL_SECS   = 4096

HELLO_PAYLOAD = b"HAMNIX-ARM64-FS-OK"

# ---- Phase-32 PROG.ELF ABI (must match kmain.ad) -----------------------
P32_SYS_WRITE = 600
P32_SYS_EXIT  = 601
P32_EXIT_CODE = 0x37
P32_TEXT_VA   = 0x42600000
P32_DATA_VA   = 0x42800000
PAGE          = 0x1000
P32_TEXT_FOFF = 0x120
P32_MSG_OFF   = 0x100
P32_MSG_VA    = P32_TEXT_VA + P32_MSG_OFF
P32_MESSAGE   = b"Hello from a real ELF64 read off the FAT16 disk on aarch64\n"

# ---- Phase-36 ABI (must match kmain.ad constants) ----------------------
SYS_OPEN   = 700
SYS_WRITE  = 701
SYS_READ   = 702
SYS_CLOSE  = 703
SYS_SPAWN  = 704
SYS_EXIT   = 705
SYS_REPORT = 706
NID_WORK   = 0
NID_MARK   = 1
PROG_CHILDB = 0
CHK_WORK   = 0
CHK_MARK   = 1
CHK_STATUS = 2
CHILD_EXIT  = 0x2A   # 42
PARENT_EXIT = 0x5B   # 91
WORK_LEN = 16
MARK_LEN = 12
def work_byte(i): return (0x41 + i * 3) & 0x7F
def mark_byte(i): return (0x4D + i * 5) & 0x7F
WORK_PAYLOAD = bytes(work_byte(i) for i in range(WORK_LEN))
MARK_PAYLOAD = bytes(mark_byte(i) for i in range(MARK_LEN))

# Program A (INITA) + B (CHILDB) EL0 layout (Phase 36).
A_TEXT_VA  = 0x42600000
A_DATA_VA  = 0x42800000
B_TEXT_VA  = 0x42C00000
B_DATA_VA  = 0x42E00000
A_WORK_OFF  = 0x00
A_SCRATCH_OFF = 0x40
B_MARK_OFF  = 0x00

# ---- Phase-37 ABI (must match kmain.ad constants) ----------------------
SYS_PIPE_WRITE = 710
SYS_PIPE_READ  = 711
SYS_P37_REPORT = 712
SYS_P37_EXIT   = 713
P37_CHK_PIPE   = 0
PROD_EXIT      = 0x33   # 51
CONS_EXIT      = 0x44   # 68
PROD_LEN       = 24
def prod_byte(i): return (0x21 + i * 7) & 0x7F
PROD_PAYLOAD = bytes(prod_byte(i) for i in range(PROD_LEN))

# Producer (PRODA) reuses the Phase-36 program-A VAs; consumer (CONSB) reuses the
# program-B VAs (these match the kmain.ad Phase-37 P37A_*/P37B_* segment VAs).
PA_TEXT_VA = 0x42600000
PA_DATA_VA = 0x42800000
PB_TEXT_VA = 0x42C00000
PB_DATA_VA = 0x42E00000
PA_SEQ_OFF = 0x00     # producer's 24-byte sequence lives at data+0
PB_BUF_OFF = 0x00     # consumer accumulates received bytes at data+0

TEXT_FOFF = 0xC0

# ---- minimal AArch64 encoders -----------------------------------------
def movz(xd, imm16, shift):
    hw = shift // 16
    return 0xD2800000 | (hw << 21) | ((imm16 & 0xFFFF) << 5) | xd
def movk(xd, imm16, shift):
    hw = shift // 16
    return 0xF2800000 | (hw << 21) | ((imm16 & 0xFFFF) << 5) | xd
def load_imm64(xd, val):
    return [movz(xd, val & 0xFFFF, 0),
            movk(xd, (val >> 16) & 0xFFFF, 16),
            movk(xd, (val >> 32) & 0xFFFF, 32),
            movk(xd, (val >> 48) & 0xFFFF, 48)]
SVC0 = 0xD4000001

def syscall(words, nr, x0=None, x1=None, x2=None):
    if x0 is not None: words += load_imm64(0, x0)
    if x1 is not None: words += load_imm64(1, x1)
    if x2 is not None: words += load_imm64(2, x2)
    words += load_imm64(8, nr)
    words.append(SVC0)

def mov_x2_from_x0(words):
    words.append(0xAA000000 | (0 << 16) | (31 << 5) | 2)   # orr x2, xzr, x0 == mov x2,x0

# ---- assemble INITA.ELF (Phase 36) ------------------------------------
def build_inita():
    words = []
    syscall(words, SYS_OPEN, x0=NID_WORK)
    syscall(words, SYS_WRITE, x0=0, x1=A_DATA_VA + A_WORK_OFF, x2=WORK_LEN)
    syscall(words, SYS_CLOSE, x0=0)
    syscall(words, SYS_OPEN, x0=NID_WORK)
    syscall(words, SYS_READ, x0=0, x1=A_DATA_VA + A_SCRATCH_OFF, x2=WORK_LEN)
    syscall(words, SYS_CLOSE, x0=0)
    syscall(words, SYS_REPORT, x0=CHK_WORK, x1=A_DATA_VA + A_SCRATCH_OFF, x2=WORK_LEN)
    syscall(words, SYS_SPAWN, x0=PROG_CHILDB)
    mov_x2_from_x0(words)
    words += load_imm64(0, CHK_STATUS)
    words += load_imm64(1, 0)
    words += load_imm64(8, SYS_REPORT)
    words.append(SVC0)
    syscall(words, SYS_OPEN, x0=NID_MARK)
    syscall(words, SYS_READ, x0=0, x1=A_DATA_VA + A_SCRATCH_OFF, x2=MARK_LEN)
    syscall(words, SYS_CLOSE, x0=0)
    syscall(words, SYS_REPORT, x0=CHK_MARK, x1=A_DATA_VA + A_SCRATCH_OFF, x2=MARK_LEN)
    syscall(words, SYS_EXIT, x0=PARENT_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x80)
    data_seg[A_WORK_OFF:A_WORK_OFF + WORK_LEN] = WORK_PAYLOAD
    return assemble_elf(A_TEXT_VA, A_DATA_VA, code, bytes(data_seg))

def build_childb():
    words = []
    syscall(words, SYS_OPEN, x0=NID_MARK)
    syscall(words, SYS_WRITE, x0=0, x1=B_DATA_VA + B_MARK_OFF, x2=MARK_LEN)
    syscall(words, SYS_CLOSE, x0=0)
    syscall(words, SYS_EXIT, x0=CHILD_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    data_seg[B_MARK_OFF:B_MARK_OFF + MARK_LEN] = MARK_PAYLOAD
    return assemble_elf(B_TEXT_VA, B_DATA_VA, code, bytes(data_seg))

# ---- assemble PRODA.ELF (Phase 37 producer) ---------------------------
def build_proda():
    words = []
    # pipe_write(buf = data+seq_off, len = PROD_LEN)
    syscall(words, SYS_PIPE_WRITE, x0=PA_DATA_VA + PA_SEQ_OFF, x1=PROD_LEN)
    # exit(PROD_EXIT)
    syscall(words, SYS_P37_EXIT, x0=PROD_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    data_seg[PA_SEQ_OFF:PA_SEQ_OFF + PROD_LEN] = PROD_PAYLOAD
    return assemble_elf(PA_TEXT_VA, PA_DATA_VA, code, bytes(data_seg))

# ---- assemble CONSB.ELF (Phase 37 consumer) ---------------------------
# Loops pipe_read into [data+buf_off + total] until total >= PROD_LEN, accumulating
# the running count in x19 (callee-saved across the svc by AAPCS). Then report() the
# received bytes and exit(). Register plan:
#   x19 = total bytes received (init 0)
#   loop: x1 = data_buf + x19 ; x2 = PROD_LEN - x19 ; x8=PIPE_READ ; svc
#         x19 = x19 + x0 ; if x19 < PROD_LEN -> loop
#   report(CHK_PIPE, data_buf, PROD_LEN) ; exit(CONS_EXIT)
def build_consb():
    words = []
    DATA_BUF = PB_DATA_VA + PB_BUF_OFF
    # x19 = 0
    words += load_imm64(19, 0)
    loop_idx = len(words)                       # index of the first loop instruction
    # x20 = DATA_BUF (base)
    words += load_imm64(20, DATA_BUF)
    # x0 = x20 + x19   (add x0, x20, x19)  -> pipe_read buf VA (a0)
    words.append(0x8B000000 | (19 << 16) | (20 << 5) | 0)
    # x21 = PROD_LEN
    words += load_imm64(21, PROD_LEN)
    # x1 = x21 - x19   (sub x1, x21, x19)  -> pipe_read len (a1)
    words.append(0xCB000000 | (19 << 16) | (21 << 5) | 1)
    # x8 = SYS_PIPE_READ
    words += load_imm64(8, SYS_PIPE_READ)
    words.append(SVC0)
    # x19 = x19 + x0   (add x19, x19, x0)
    words.append(0x8B000000 | (0 << 16) | (19 << 5) | 19)
    # cmp x19, PROD_LEN  -> via: x22 = PROD_LEN ; subs xzr, x19, x22
    words += load_imm64(22, PROD_LEN)
    # subs xzr, x19, x22   (cmp x19, x22): 0xEB000000 | (Rm<<16)|(Rn<<5)|Rd(31)
    words.append(0xEB000000 | (22 << 16) | (19 << 5) | 31)
    # b.lt loop   (condition LT = 0b1011). B.cond: 0x54000000 | (imm19<<5) | cond
    branch_idx = len(words)
    # placeholder; patch the offset once we know loop target distance.
    words.append(0x54000000 | (0 << 5) | 0xB)   # b.lt #0 (patched below)
    # patch: offset (in instructions) from branch to loop_idx
    rel = loop_idx - branch_idx
    imm19 = rel & 0x7FFFF
    words[branch_idx] = 0x54000000 | (imm19 << 5) | 0xB
    # report(CHK_PIPE, DATA_BUF, PROD_LEN)
    syscall(words, SYS_P37_REPORT, x0=P37_CHK_PIPE, x1=DATA_BUF, x2=PROD_LEN)
    # exit(CONS_EXIT)
    syscall(words, SYS_P37_EXIT, x0=CONS_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)                  # zero-filled receive buffer
    return assemble_elf(PB_TEXT_VA, PB_DATA_VA, code, bytes(data_seg))

def assemble_elf(text_va, data_va, code, data_bytes):
    assert len(code) <= (0x1000 - TEXT_FOFF), "code too large for one page"
    text_seg = bytes(code)
    TEXT_FILESZ = len(text_seg)
    DATA_FILESZ = len(data_bytes)
    DATA_MEMSZ  = max(DATA_FILESZ, 0x100)
    data_foff = TEXT_FOFF + TEXT_FILESZ
    data_foff = (data_foff + 7) & ~7
    elf = bytearray(data_foff + DATA_FILESZ)
    elf[0:4] = b"\x7fELF"
    elf[4] = 2; elf[5] = 1; elf[6] = 1
    struct.pack_into("<H", elf, 16, 2)            # ET_EXEC
    struct.pack_into("<H", elf, 18, 183)          # EM_AARCH64
    struct.pack_into("<I", elf, 20, 1)
    struct.pack_into("<Q", elf, 24, text_va)      # e_entry
    struct.pack_into("<Q", elf, 32, 64)           # e_phoff
    struct.pack_into("<H", elf, 52, 64)           # e_ehsize
    struct.pack_into("<H", elf, 54, 56)           # e_phentsize
    struct.pack_into("<H", elf, 56, 2)            # e_phnum
    p1 = 64
    struct.pack_into("<I", elf, p1 + 0, 1)               # PT_LOAD
    struct.pack_into("<I", elf, p1 + 4, 0x4 | 0x1)       # R+X
    struct.pack_into("<Q", elf, p1 + 8, TEXT_FOFF)
    struct.pack_into("<Q", elf, p1 + 16, text_va)
    struct.pack_into("<Q", elf, p1 + 24, text_va)
    struct.pack_into("<Q", elf, p1 + 32, TEXT_FILESZ)
    struct.pack_into("<Q", elf, p1 + 40, TEXT_FILESZ)
    struct.pack_into("<Q", elf, p1 + 48, PAGE)
    p2 = 64 + 56
    struct.pack_into("<I", elf, p2 + 0, 1)               # PT_LOAD
    struct.pack_into("<I", elf, p2 + 4, 0x4 | 0x2)       # R+W
    struct.pack_into("<Q", elf, p2 + 8, data_foff)
    struct.pack_into("<Q", elf, p2 + 16, data_va)
    struct.pack_into("<Q", elf, p2 + 24, data_va)
    struct.pack_into("<Q", elf, p2 + 32, DATA_FILESZ)
    struct.pack_into("<Q", elf, p2 + 40, DATA_MEMSZ)
    struct.pack_into("<Q", elf, p2 + 48, PAGE)
    elf[TEXT_FOFF:TEXT_FOFF + TEXT_FILESZ] = text_seg
    elf[data_foff:data_foff + DATA_FILESZ] = data_bytes
    return bytes(elf)

# ---- PROG.ELF (Phase 32, unchanged shape) ------------------------------
def build_prog():
    words = []
    words += load_imm64(0, 1)
    words += load_imm64(1, P32_MSG_VA)
    words += load_imm64(2, len(P32_MESSAGE))
    words += load_imm64(8, P32_SYS_WRITE)
    words.append(SVC0)
    words += load_imm64(0, P32_EXIT_CODE)
    words += load_imm64(8, P32_SYS_EXIT)
    words.append(SVC0)
    code = b"".join(struct.pack("<I", w) for w in words)
    assert len(code) <= P32_MSG_OFF
    text_seg = bytearray()
    text_seg += code
    text_seg += b"\x00" * (P32_MSG_OFF - len(code))
    text_seg += P32_MESSAGE
    TEXT_FILESZ = len(text_seg)
    DATA_BYTES = bytes((0xC0 + i) & 0xFF for i in range(8))
    DATA_FILESZ = len(DATA_BYTES)
    DATA_MEMSZ  = 0x40
    data_foff = P32_TEXT_FOFF + TEXT_FILESZ
    data_foff = (data_foff + 7) & ~7
    elf = bytearray(data_foff + DATA_FILESZ)
    elf[0:4] = b"\x7fELF"
    elf[4] = 2; elf[5] = 1; elf[6] = 1
    struct.pack_into("<H", elf, 16, 2)
    struct.pack_into("<H", elf, 18, 183)
    struct.pack_into("<I", elf, 20, 1)
    struct.pack_into("<Q", elf, 24, P32_TEXT_VA)
    struct.pack_into("<Q", elf, 32, 64)
    struct.pack_into("<H", elf, 52, 64)
    struct.pack_into("<H", elf, 54, 56)
    struct.pack_into("<H", elf, 56, 2)
    p1 = 64
    struct.pack_into("<I", elf, p1 + 0, 1)
    struct.pack_into("<I", elf, p1 + 4, 0x4 | 0x1)
    struct.pack_into("<Q", elf, p1 + 8, P32_TEXT_FOFF)
    struct.pack_into("<Q", elf, p1 + 16, P32_TEXT_VA)
    struct.pack_into("<Q", elf, p1 + 24, P32_TEXT_VA)
    struct.pack_into("<Q", elf, p1 + 32, TEXT_FILESZ)
    struct.pack_into("<Q", elf, p1 + 40, TEXT_FILESZ)
    struct.pack_into("<Q", elf, p1 + 48, PAGE)
    p2 = 64 + 56
    struct.pack_into("<I", elf, p2 + 0, 1)
    struct.pack_into("<I", elf, p2 + 4, 0x4 | 0x2)
    struct.pack_into("<Q", elf, p2 + 8, data_foff)
    struct.pack_into("<Q", elf, p2 + 16, P32_DATA_VA)
    struct.pack_into("<Q", elf, p2 + 24, P32_DATA_VA)
    struct.pack_into("<Q", elf, p2 + 32, DATA_FILESZ)
    struct.pack_into("<Q", elf, p2 + 40, DATA_MEMSZ)
    struct.pack_into("<Q", elf, p2 + 48, PAGE)
    elf[P32_TEXT_FOFF:P32_TEXT_FOFF + TEXT_FILESZ] = text_seg
    elf[data_foff:data_foff + DATA_FILESZ] = DATA_BYTES
    return bytes(elf)

PROG_ELF   = build_prog()
INITA_ELF  = build_inita()
CHILDB_ELF = build_childb()
PRODA_ELF  = build_proda()
CONSB_ELF  = build_consb()

# ---- FAT16 layout -----------------------------------------------------
root_secs = (ROOT_ENT * 32 + BPS - 1) // BPS
fat_lba   = RESERVED
root_lba  = RESERVED + NUM_FATS * SEC_PER_FAT
data_lba  = root_lba + root_secs

img = bytearray(TOTAL_SECS * BPS)

bs = bytearray(BPS)
bs[0:11]  = b"HAMNIXARM  "
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

clus_size = SPC * BPS
def write_clusters(start_clus, payload):
    n = max((len(payload) + clus_size - 1) // clus_size, 1)
    for i in range(n):
        c = start_clus + i
        off = data_lba * BPS + (c - 2) * clus_size
        chunk = payload[i * clus_size:(i + 1) * clus_size]
        img[off:off + len(chunk)] = chunk
    return list(range(start_clus, start_clus + n))

hello_clusters  = write_clusters(2, HELLO_PAYLOAD)
prog_clusters   = write_clusters(hello_clusters[-1] + 1, PROG_ELF)
inita_clusters  = write_clusters(prog_clusters[-1] + 1, INITA_ELF)
childb_clusters = write_clusters(inita_clusters[-1] + 1, CHILDB_ELF)
work_clusters   = write_clusters(childb_clusters[-1] + 1, b"\x00")
mark_clusters   = write_clusters(work_clusters[-1] + 1, b"\x00")
proda_clusters  = write_clusters(mark_clusters[-1] + 1, PRODA_ELF)
consb_clusters  = write_clusters(proda_clusters[-1] + 1, CONSB_ELF)

def build_fat():
    fat = bytearray(SEC_PER_FAT * BPS)
    struct.pack_into("<H", fat, 0, 0xFFF8)
    struct.pack_into("<H", fat, 2, 0xFFFF)
    def chain(clusters):
        for i, c in enumerate(clusters):
            nxt = clusters[i + 1] if i + 1 < len(clusters) else 0xFFFF
            struct.pack_into("<H", fat, c * 2, nxt)
    chain(hello_clusters)
    chain(prog_clusters)
    chain(inita_clusters)
    chain(childb_clusters)
    chain(work_clusters)
    chain(mark_clusters)
    chain(proda_clusters)
    chain(consb_clusters)
    return fat

fat = build_fat()
for n in range(NUM_FATS):
    off = (fat_lba + n * SEC_PER_FAT) * BPS
    img[off:off + len(fat)] = fat

def dir_entry(name83, first_clus, size):
    ent = bytearray(32)
    ent[0:11] = name83
    ent[11]   = 0x20
    struct.pack_into("<H", ent, 26, first_clus)
    struct.pack_into("<I", ent, 28, size)
    return ent

root_off = root_lba * BPS
entries = [
    (b"HELLO   TXT", hello_clusters[0],  len(HELLO_PAYLOAD)),
    (b"PROG    ELF", prog_clusters[0],   len(PROG_ELF)),
    (b"INITA   ELF", inita_clusters[0],  len(INITA_ELF)),
    (b"CHILDB  ELF", childb_clusters[0], len(CHILDB_ELF)),
    (b"WORK    TXT", work_clusters[0],   0),
    (b"MARK    TXT", mark_clusters[0],   0),
    (b"PRODA   ELF", proda_clusters[0],  len(PRODA_ELF)),
    (b"CONSB   ELF", consb_clusters[0],  len(CONSB_ELF)),
]
for i, (n83, fc, sz) in enumerate(entries):
    img[root_off + i * 32:root_off + i * 32 + 32] = dir_entry(n83, fc, sz)

with open(disk_path, "wb") as f:
    f.write(img)

assert img[510] == 0x55 and img[511] == 0xAA, "bad boot signature"
assert PRODA_ELF[:4] == b"\x7fELF" and CONSB_ELF[:4] == b"\x7fELF"
print("[fat16-builder] PRODA=%s CONSB=%s" % (proda_clusters, consb_clusters))
print("[fat16-builder] PRODA.ELF=%d CONSB.ELF=%d bytes; data_lba=%d"
      % (len(PRODA_ELF), len(CONSB_ELF), data_lba))
PYEOF

[ -s "$DISK" ] || fail "FAT16 disk image was not created"

cp -f "$DISK" "$SCRATCH" || fail "could not create writable scratch disk"
[ -s "$SCRATCH" ] || fail "writable scratch disk was not created"

# --- boot under qemu-system-aarch64: WRITABLE virtio-blk + virtio-net ---
timeout 420 "$QEMU" \
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
    echo "[test_arm64_phase37] captured serial (tail):"
    tail -120 "$SERIAL" | sed 's/^/[test_arm64_phase37]   | /'
}

# --- guard against explicit failure markers / panics -------------------
for ph in 30 31 32 35 36 37; do
    if grep -q -F "Phase $ph FAIL" "$SERIAL"; then
        dump_serial
        fail "Phase-$ph reported FAIL"
    fi
done
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort paniced the kernel"
fi
if grep -q -F "EL0 non-SVC sync exception" "$SERIAL"; then
    dump_serial
    fail "an unexpected EL0 non-SVC sync exception fired (a task faulted)"
fi
if grep -q -F "EL0 unknown syscall (phase 37)" "$SERIAL"; then
    dump_serial
    fail "a Phase-37 program issued an unknown syscall"
fi

# --- regression: prior phase milestones must still complete ------------
grep -q "$BANNER"        "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$P30_PASS"   "$SERIAL" || { dump_serial; fail "Phase-30 virtio-blk read regressed"; }
grep -q -F "$P31_PASS"   "$SERIAL" || { dump_serial; fail "Phase-31 FAT16 read regressed"; }
grep -q -F "$P32_PASS"   "$SERIAL" || { dump_serial; fail "Phase-32 on-disk ELF run regressed"; }
grep -q -F "$P35_PASS"   "$SERIAL" || { dump_serial; fail "Phase-35 FAT16 write regressed"; }
grep -q -F "$P36_PASS"   "$SERIAL" || { dump_serial; fail "Phase-36 multi-process userland regressed (Phase 37 not reached)"; }

# --- Phase 37 assertions ----------------------------------------------
grep -q -F "$PHASE37"   "$SERIAL" || { dump_serial; fail "Phase-37 pipe IPC demo did not start"; }
grep -q -F "$READA37"   "$SERIAL" || { dump_serial; fail "Phase-37 did not read PRODA.ELF off disk"; }
grep -q -F "$READB37"   "$SERIAL" || { dump_serial; fail "Phase-37 did not read CONSB.ELF off disk"; }
grep -q -F "$LAUNCH37"  "$SERIAL" || { dump_serial; fail "Phase-37 did not launch both processes"; }
grep -q -F "$BLOCK37"   "$SERIAL" || { dump_serial; fail "Phase-37 consumer never BLOCKED on the empty pipe (no blocking proof)"; }
grep -q -F "$WAKE37"    "$SERIAL" || { dump_serial; fail "Phase-37 producer write never woke the blocked consumer"; }
grep -q -F "$SUMMARY37" "$SERIAL" || { dump_serial; fail "Phase-37 summary line not emitted"; }
grep -q -F "$P37_PASS"  "$SERIAL" || { dump_serial; fail "'$P37_PASS' not found (Phase 37 blocking pipe round-trip did not verify)"; }

echo "[test_arm64_phase37] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase37] phase 36 OK (regr)    : $(grep -F "$P36_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase37] phase 37 start        : $(grep -F "$PHASE37" "$SERIAL" | head -1)"
echo "[test_arm64_phase37] consumer blocked      : $(grep -F "$BLOCK37" "$SERIAL" | head -1)"
echo "[test_arm64_phase37] write woke consumer   : $(grep -F "$WAKE37" "$SERIAL" | head -1)"
echo "[test_arm64_phase37] summary line          : $(grep -F "$SUMMARY37" "$SERIAL" | head -1)"
echo "[test_arm64_phase37] phase 37 PASS line    : $(grep -F "$P37_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase37] PASS"
