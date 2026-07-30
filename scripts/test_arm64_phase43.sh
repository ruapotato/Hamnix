#!/usr/bin/env bash
# scripts/test_arm64_phase43.sh — PHASE 42 milestone: REAL EL0 FILE-backed mmap,
# demand-paged from the on-disk virtio-blk device on bare aarch64 (qemu-virt).
# A single EL0 task maps a FILE (a known on-disk extent with known contents) as a
# lazily-backed read-only window that is initially UNMAPPED; the kernel
# materialises it on demand by READING the file's bytes off disk on each fault.
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
# Handed off from the Phase-41 PASS, the kernel:
#   1. brings up the virtio-blk transport (Phase-30 primitives) and ERETs into an
#      EL0 task whose first touch of each of TWO distinct pages in the unmapped
#      file window raises a translation Data Abort;
#   2. the kernel services each abort: allocates a fresh physical page, READS that
#      page's file bytes off the virtio-blk device (8 real sectors per page, from
#      two DIFFERENT file offsets — a real disk read, not a memset), installs an
#      EL0 RO + non-executable + inner-shareable L3 PTE, flushes only that VA, and
#      resumes EL0 at the faulting load so it retries + observes the real bytes;
#   3. EL0 reads each page's first 8 bytes back and reports them; the kernel
#      verifies each equals the file's known on-disk signature, through BOTH the
#      EL0 mapping AND the backing physical page (so the demand map truly reached
#      the disk-filled pool page);
#   4. EL0 munmaps the region: the kernel drops the L3 PTEs, frees the backing
#      pages, and flushes the TLB;
#   5. EL0 re-touches the region, which translation-FAULTS AGAIN (the mapping is
#      truly gone); the kernel catches that fault CLEANLY (no re-page, no crash),
#      latches it, and runs the verdict;
#   6. the kernel prints "[arm64] Phase 42 PASS: ...".
#
# The PASS is kernel-verified and cannot be faked: it requires exactly N_PAGES
# demand faults serviced, every page mapped, every disk read OK, every read-back
# matching the file's on-disk signature (incl. the backing physical page), ZERO
# faults outside the window, both report syscalls, the region UNMAPPED, AND the
# post-munmap re-touch faulting again cleanly.
#
# Phase 42 runs only AFTER Phase 41 prints its PASS marker, so every prior phase
# (4..41) must still run to completion (no regression).
#
# Prints "[test_arm64_phase43] PASS" on success or "[test_arm64_phase43] FAIL ...".
#
# NOTE: a 124 timeout that still shows every PASS banner is acceptable — the
# kernel halts in a WFI loop at the Phase-42 verdict, so QEMU never exits on its
# own; the grep assertions below are the authoritative verdict.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
P30_PASS="[arm64] Phase 30 PASS: virtio-blk read sector 0 -> HAMNIXARM"
P31_PASS="[arm64] Phase 31 PASS: FAT16 read HELLO.TXT -> HAMNIX-ARM64-FS-OK"
P32_PASS="[arm64] Phase 32 PASS: loaded PROG.ELF from FAT16 disk and ran it at EL0"
P33_PASS="[arm64] Phase 33 PASS: virtio-net ARP round-trip (TX used + RX frame) over virtio-mmio"
P34_PASS="[arm64] Phase 34 PASS: IPv4/ICMP echo round-trip (ping 10.0.2.2) over native virtio-net"
P35_PASS="[arm64] Phase 35 PASS: virtio-blk WRITE + FAT16 filesystem write round-trip -> ARM64-WRITE-OK-A64"
P36_PASS="[arm64] Phase 36 PASS: multi-process FAT16 userland (INITA file round-trip + spawned CHILDB + reaped exit status + ordering)"
P37_PASS="[arm64] Phase 37 PASS: pipe IPC blocking round-trip"
P38_PASS="[arm64] Phase 38 PASS: shm IPC zero-copy round-trip"
P39_PASS="[arm64] Phase 39 PASS: futex thread-sync round-trip"

# Phase 40 + 41 PASS are now REGRESSION guards (Phase 42 chains off Phase 41).
P40_PASS="[arm64] Phase 40 PASS: TCP loopback three-way handshake + bidirectional data + FIN teardown"
P41_PASS="[arm64] Phase 41 PASS: EL0 demand-paged anonymous mmap (fault-backed) + munmap"

# Phase 42 progress + verdict markers.
PHASE42="[arm64] Phase 42: EL0 file-backed mmap demand-paged from the virtio-blk disk"
DISKUP42="[arm64] Phase 42: virtio-blk live @ "
LAUNCH42="[arm64] launching EL0 file-backed mmap task (2 pages demand-read from disk, then munmap + re-fault)"
FAULT42="[arm64] Phase 42 demand fault: paged in file VA "
READBACK42="[arm64] Phase 42 read-back page "
MUNMAP42="[arm64] Phase 42 munmap: tearing down file-backed region [base="
REFAULT42="[arm64] Phase 42: post-munmap touch of VA "
SUMMARY42="[arm64] Phase 42 summary: faults="
# Phase 42 PASS is now a REGRESSION guard (Phase 43 chains off Phase 42).
P42_PASS="[arm64] Phase 42 PASS: EL0 file-backed mmap demand-paged from disk"

# Phase 43 progress + verdict markers (REAL blocking PIPE IPC, two EL0 tasks).
PHASE43="[arm64] Phase 43: blocking pipe IPC (two EL0 tasks, one address space: READER43 + WRITER43)"
READA43="[arm64] Phase 43: read READER43.ELF off disk"
READB43="[arm64] Phase 43: read WRITER43.ELF off disk"
LAUNCH43="[arm64] Phase 43: launching task A (reader) + task B (writer) in ONE address space (ASID 31)"
RBLOCK43="[arm64] Phase 43: task A pipe_read on EMPTY pipe -> SLEEPING"
RWAKE43="[arm64] Phase 43: pipe_write delivered to + woke the BLOCKED reader (task A) -> RUNNABLE"
WBLOCK43="[arm64] Phase 43: task B pipe_write filled the ring"
WWAKE43="[arm64] Phase 43: a read drained the ring -> woke the BLOCKED writer (task B) -> RUNNABLE"
SUMMARY43="[arm64] Phase 43 summary: reader_blocked="
P43_PASS="[arm64] Phase 43 PASS: EL0 blocking pipe IPC (reader slept on empty pipe, writer woke it; writer slept on full pipe, reader woke it; message round-tripped byte-for-byte)"

fail() {
    echo "[test_arm64_phase43] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase43] qemu-system-aarch64 not found; attempting apt install"
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
WORK="$PROJ_ROOT/build/arm64_phase43_test"
mkdir -p "$WORK"
ELF="$WORK/hamnix-arm64.elf"
SERIAL="$WORK/serial.txt"
DISK="$WORK/disk.img"          # pristine FAT16 image (prior phases read off it)
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

# --- build the FAT16 backing disk (needed for prior phases 30..39) -----
#     This is the SAME image the Phase-39 test builds; Phase 40 itself needs
#     no disk, but every prior phase must still run to completion first.
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

# ---- Phase-32 PROG.ELF ABI ---------------------------------------------
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

# ---- Phase-36 ABI ------------------------------------------------------
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
CHILD_EXIT  = 0x2A
PARENT_EXIT = 0x5B
WORK_LEN = 16
MARK_LEN = 12
def work_byte(i): return (0x41 + i * 3) & 0x7F
def mark_byte(i): return (0x4D + i * 5) & 0x7F
WORK_PAYLOAD = bytes(work_byte(i) for i in range(WORK_LEN))
MARK_PAYLOAD = bytes(mark_byte(i) for i in range(MARK_LEN))

A_TEXT_VA  = 0x42600000
A_DATA_VA  = 0x42800000
B_TEXT_VA  = 0x42C00000
B_DATA_VA  = 0x42E00000
A_WORK_OFF  = 0x00
A_SCRATCH_OFF = 0x40
B_MARK_OFF  = 0x00

# ---- Phase-37 ABI ------------------------------------------------------
SYS_PIPE_WRITE = 710
SYS_PIPE_READ  = 711
SYS_P37_REPORT = 712
SYS_P37_EXIT   = 713
P37_CHK_PIPE   = 0
PROD_EXIT      = 0x33
CONS_EXIT      = 0x44
PROD_LEN       = 24
def prod_byte(i): return (0x21 + i * 7) & 0x7F
PROD_PAYLOAD = bytes(prod_byte(i) for i in range(PROD_LEN))

PA_TEXT_VA = 0x42600000
PA_DATA_VA = 0x42800000
PB_TEXT_VA = 0x42C00000
PB_DATA_VA = 0x42E00000
PA_SEQ_OFF = 0x00
PB_BUF_OFF = 0x00

# ---- Phase-38 ABI ------------------------------------------------------
SYS_SHM_GET    = 720
SYS_SHM_ATTACH = 721
SYS_SIGNAL     = 722
SYS_WAIT       = 723
SYS_P38_REPORT = 724
SYS_P38_EXIT   = 725
P38_CHK_SHM    = 0
P38_PROD_EXIT  = 0x55
P38_CONS_EXIT  = 0x66
P38_SHM_LEN    = 28
P38_SHM_VA     = 0x43400000
P38_SIGNAL_VAL = 0xA5
def shm_byte(i): return (0x31 + i * 11) & 0x7F
SHM_PAYLOAD = bytes(shm_byte(i) for i in range(P38_SHM_LEN))

P38A_TEXT_VA = 0x42600000
P38A_DATA_VA = 0x42800000
P38B_TEXT_VA = 0x42C00000
P38B_DATA_VA = 0x42E00000
P38A_SEQ_OFF = 0x00

# ---- Phase-39 ABI ------------------------------------------------------
SYS_P39_FUTEX_WAIT = 730
SYS_P39_FUTEX_WAKE = 731
SYS_P39_REPORT     = 732
SYS_P39_EXIT       = 733
P39_CHK_HANDOFF    = 0
P39_A_EXIT         = 0x77
P39_B_EXIT         = 0x88
P39_FUTEX_VA       = 0x42E00000
P39_HANDOFF_VA     = 0x42E00040
P39_FUTEX_EXPECTED = 0x11
P39_FUTEX_BUMP     = 0x12
P39_HANDOFF_VAL    = 0x5AC3

P39A_TEXT_VA = 0x42600000
P39A_STACK_VA = 0x42800000
P39B_TEXT_VA = 0x42A00000
P39B_STACK_VA = 0x42C00000
P39_DATA_VA  = 0x42E00000

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

def mov_reg(rd, rn):
    return 0xAA0003E0 | (rn << 16) | rd

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
    words.append(mov_reg(2, 0))
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

def build_proda():
    words = []
    syscall(words, SYS_PIPE_WRITE, x0=PA_DATA_VA + PA_SEQ_OFF, x1=PROD_LEN)
    syscall(words, SYS_P37_EXIT, x0=PROD_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    data_seg[PA_SEQ_OFF:PA_SEQ_OFF + PROD_LEN] = PROD_PAYLOAD
    return assemble_elf(PA_TEXT_VA, PA_DATA_VA, code, bytes(data_seg))

def build_consb():
    words = []
    DATA_BUF = PB_DATA_VA + PB_BUF_OFF
    words += load_imm64(19, 0)
    loop_idx = len(words)
    words += load_imm64(20, DATA_BUF)
    words.append(0x8B000000 | (19 << 16) | (20 << 5) | 0)
    words += load_imm64(21, PROD_LEN)
    words.append(0xCB000000 | (19 << 16) | (21 << 5) | 1)
    words += load_imm64(8, SYS_PIPE_READ)
    words.append(SVC0)
    words.append(0x8B000000 | (0 << 16) | (19 << 5) | 19)
    words += load_imm64(22, PROD_LEN)
    words.append(0xEB000000 | (22 << 16) | (19 << 5) | 31)
    branch_idx = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)
    rel = loop_idx - branch_idx
    imm19 = rel & 0x7FFFF
    words[branch_idx] = 0x54000000 | (imm19 << 5) | 0xB
    syscall(words, SYS_P37_REPORT, x0=P37_CHK_PIPE, x1=DATA_BUF, x2=PROD_LEN)
    syscall(words, SYS_P37_EXIT, x0=CONS_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    return assemble_elf(PB_TEXT_VA, PB_DATA_VA, code, bytes(data_seg))

def build_proda38():
    words = []
    syscall(words, SYS_SHM_GET, x0=0)
    syscall(words, SYS_SHM_ATTACH, x0=0)
    words.append(mov_reg(19, 0))
    words += load_imm64(20, P38A_DATA_VA + P38A_SEQ_OFF)
    words += load_imm64(21, 0)
    words += load_imm64(22, P38_SHM_LEN)
    cpy_idx = len(words)
    words.append(0x38606800 | (21 << 16) | (20 << 5) | 0)
    words.append(0x38206800 | (21 << 16) | (19 << 5) | 0)
    words.append(0x91000400 | (21 << 5) | 21)
    words.append(0xEB000000 | (22 << 16) | (21 << 5) | 31)
    br_idx = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)
    rel = cpy_idx - br_idx
    words[br_idx] = 0x54000000 | ((rel & 0x7FFFF) << 5) | 0xB
    syscall(words, SYS_SIGNAL, x0=P38_SIGNAL_VAL)
    syscall(words, SYS_P38_EXIT, x0=P38_PROD_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    data_seg[P38A_SEQ_OFF:P38A_SEQ_OFF + P38_SHM_LEN] = SHM_PAYLOAD
    return assemble_elf(P38A_TEXT_VA, P38A_DATA_VA, code, bytes(data_seg))

def build_consb38():
    words = []
    syscall(words, SYS_SHM_GET, x0=0)
    syscall(words, SYS_SHM_ATTACH, x0=0)
    words.append(mov_reg(19, 0))
    words += load_imm64(8, SYS_WAIT)
    words.append(SVC0)
    words += load_imm64(0, P38_CHK_SHM)
    words.append(mov_reg(1, 19))
    words += load_imm64(2, P38_SHM_LEN)
    words += load_imm64(8, SYS_P38_REPORT)
    words.append(SVC0)
    syscall(words, SYS_P38_EXIT, x0=P38_CONS_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    return assemble_elf(P38B_TEXT_VA, P38B_DATA_VA, code, bytes(data_seg))

def build_thrda39():
    words = []
    syscall(words, SYS_P39_FUTEX_WAIT, x0=P39_FUTEX_VA, x1=P39_FUTEX_EXPECTED)
    words += load_imm64(19, P39_HANDOFF_VA)
    words.append(0xB9400000 | (19 << 5) | 20)
    words += load_imm64(0, P39_CHK_HANDOFF)
    words.append(mov_reg(1, 20))
    words += load_imm64(8, SYS_P39_REPORT)
    words.append(SVC0)
    syscall(words, SYS_P39_EXIT, x0=P39_A_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    return assemble_elf(P39A_TEXT_VA, P39A_STACK_VA, code, bytes(data_seg),
                        data_va_override=P39_DATA_VA, no_data_seg=True)

def build_thrdb39():
    words = []
    words += load_imm64(19, P39_HANDOFF_VA)
    words += load_imm64(20, P39_HANDOFF_VAL)
    words.append(0xB9000000 | (19 << 5) | 20)
    words += load_imm64(21, P39_FUTEX_VA)
    words += load_imm64(22, P39_FUTEX_BUMP)
    words.append(0xB9000000 | (21 << 5) | 22)
    syscall(words, SYS_P39_FUTEX_WAKE, x0=P39_FUTEX_VA, x1=1)
    syscall(words, SYS_P39_EXIT, x0=P39_B_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    return assemble_elf(P39B_TEXT_VA, P39B_STACK_VA, code, bytes(data_seg),
                        data_va_override=P39_DATA_VA, no_data_seg=True)

# ---- Phase-43 ABI (must match kmain.ad constants) ----------------------
SYS_P43_PIPE_READ  = 740
SYS_P43_PIPE_WRITE = 741
SYS_P43_REPORT     = 742
SYS_P43_EXIT       = 743
P43_CHK_PIPE       = 0
P43_A_EXIT         = 0x52   # 82  — reader exit status
P43_B_EXIT         = 0x57   # 87  — writer exit status
P43_MSG_LEN        = 40
# Task A (READER43) / task B (WRITER43) text + stack VAs (one shared AS); shared data
# VA (writer source @ +0, reader receive @ +0x80). Match the kmain.ad P43_* globals.
P43A_TEXT_VA  = 0x42600000
P43A_STACK_VA = 0x42800000
P43B_TEXT_VA  = 0x42A00000
P43B_STACK_VA = 0x42C00000
P43_DATA_VA   = 0x42E00000
P43_SRC_VA    = P43_DATA_VA + 0x00     # writer's source message
P43_RECV_VA   = P43_DATA_VA + 0x80     # reader's reassembled bytes

# ---- assemble READER43.ELF (Phase 43 reader, slot 0) -------------------
# Loop pipe_read(RECV_VA + total, MSG_LEN - total) accumulating the returned count
# into x19 until x19 == MSG_LEN (the first read BLOCKS on the empty pipe); then
# report(CHK_PIPE, RECV_VA, MSG_LEN) and exit(A_EXIT).
def build_reader43():
    words = []
    words += load_imm64(19, 0)                              # x19 = total received
    loop_idx = len(words)
    # x0 = RECV_VA + x19  (dst = base + total)  -- a0 = buf
    words += load_imm64(20, P43_RECV_VA)
    words.append(0x8B000000 | (19 << 16) | (20 << 5) | 0)   # add x0, x20, x19
    # x1 = MSG_LEN - x19  (want = MSG_LEN - total)  -- a1 = len
    words += load_imm64(21, P43_MSG_LEN)
    words.append(0xCB000000 | (19 << 16) | (21 << 5) | 1)   # sub x1, x21, x19
    words += load_imm64(8, SYS_P43_PIPE_READ)
    words.append(SVC0)
    # x19 += x0  (returned byte count)
    words.append(0x8B000000 | (0 << 16) | (19 << 5) | 19)   # add x19, x19, x0
    # cmp x19, MSG_LEN ; b.lt loop
    words += load_imm64(22, P43_MSG_LEN)
    words.append(0xEB000000 | (22 << 16) | (19 << 5) | 31)  # cmp x19, x22
    branch_idx = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)               # b.lt placeholder
    rel = loop_idx - branch_idx
    words[branch_idx] = 0x54000000 | ((rel & 0x7FFFF) << 5) | 0xB
    syscall(words, SYS_P43_REPORT, x0=P43_CHK_PIPE, x1=P43_RECV_VA, x2=P43_MSG_LEN)
    syscall(words, SYS_P43_EXIT, x0=P43_A_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    return assemble_elf(P43A_TEXT_VA, P43A_STACK_VA, code, bytes(data_seg),
                        data_va_override=P43_DATA_VA, no_data_seg=True)

# ---- assemble WRITER43.ELF (Phase 43 writer, slot 1) -------------------
# Loop pipe_write(SRC_VA + total, MSG_LEN - total) accumulating the returned count
# into x19 until x19 == MSG_LEN (the ring is small, so an early write BLOCKS on the
# full ring until the reader drains it); then exit(B_EXIT). The shared data page is
# seeded with the known message by the kernel's build_space.
def build_writer43():
    words = []
    words += load_imm64(19, 0)                              # x19 = total sent
    loop_idx = len(words)
    words += load_imm64(20, P43_SRC_VA)
    words.append(0x8B000000 | (19 << 16) | (20 << 5) | 0)   # add x0, x20, x19  (src) -- a0 = buf
    words += load_imm64(21, P43_MSG_LEN)
    words.append(0xCB000000 | (19 << 16) | (21 << 5) | 1)   # sub x1, x21, x19  (len) -- a1 = len
    words += load_imm64(8, SYS_P43_PIPE_WRITE)
    words.append(SVC0)
    words.append(0x8B000000 | (0 << 16) | (19 << 5) | 19)   # add x19, x19, x0
    words += load_imm64(22, P43_MSG_LEN)
    words.append(0xEB000000 | (22 << 16) | (19 << 5) | 31)  # cmp x19, x22
    branch_idx = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)               # b.lt placeholder
    rel = loop_idx - branch_idx
    words[branch_idx] = 0x54000000 | ((rel & 0x7FFFF) << 5) | 0xB
    syscall(words, SYS_P43_EXIT, x0=P43_B_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    return assemble_elf(P43B_TEXT_VA, P43B_STACK_VA, code, bytes(data_seg),
                        data_va_override=P43_DATA_VA, no_data_seg=True)

def assemble_elf(text_va, data_va, code, data_bytes,
                 data_va_override=None, no_data_seg=False):
    if data_va_override is not None:
        data_va = data_va_override
    assert len(code) <= (0x1000 - TEXT_FOFF), "code too large for one page"
    text_seg = bytes(code)
    TEXT_FILESZ = len(text_seg)
    if no_data_seg:
        data_bytes = b""
    DATA_FILESZ = len(data_bytes)
    DATA_MEMSZ  = max(DATA_FILESZ, 0x100)
    data_foff = TEXT_FOFF + TEXT_FILESZ
    data_foff = (data_foff + 7) & ~7
    elf = bytearray(data_foff + DATA_FILESZ)
    elf[0:4] = b"\x7fELF"
    elf[4] = 2; elf[5] = 1; elf[6] = 1
    struct.pack_into("<H", elf, 16, 2)
    struct.pack_into("<H", elf, 18, 183)
    struct.pack_into("<I", elf, 20, 1)
    struct.pack_into("<Q", elf, 24, text_va)
    struct.pack_into("<Q", elf, 32, 64)
    struct.pack_into("<H", elf, 52, 64)
    struct.pack_into("<H", elf, 54, 56)
    struct.pack_into("<H", elf, 56, 2)
    p1 = 64
    struct.pack_into("<I", elf, p1 + 0, 1)
    struct.pack_into("<I", elf, p1 + 4, 0x4 | 0x1)
    struct.pack_into("<Q", elf, p1 + 8, TEXT_FOFF)
    struct.pack_into("<Q", elf, p1 + 16, text_va)
    struct.pack_into("<Q", elf, p1 + 24, text_va)
    struct.pack_into("<Q", elf, p1 + 32, TEXT_FILESZ)
    struct.pack_into("<Q", elf, p1 + 40, TEXT_FILESZ)
    struct.pack_into("<Q", elf, p1 + 48, PAGE)
    p2 = 64 + 56
    struct.pack_into("<I", elf, p2 + 0, 1)
    struct.pack_into("<I", elf, p2 + 4, 0x4 | 0x2)
    struct.pack_into("<Q", elf, p2 + 8, data_foff)
    struct.pack_into("<Q", elf, p2 + 16, data_va)
    struct.pack_into("<Q", elf, p2 + 24, data_va)
    struct.pack_into("<Q", elf, p2 + 32, DATA_FILESZ)
    struct.pack_into("<Q", elf, p2 + 40, DATA_MEMSZ)
    struct.pack_into("<Q", elf, p2 + 48, PAGE)
    elf[TEXT_FOFF:TEXT_FOFF + TEXT_FILESZ] = text_seg
    elf[data_foff:data_foff + DATA_FILESZ] = data_bytes
    return bytes(elf)

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

PROG_ELF     = build_prog()
INITA_ELF    = build_inita()
CHILDB_ELF   = build_childb()
PRODA_ELF    = build_proda()
CONSB_ELF    = build_consb()
PRODA38_ELF  = build_proda38()
CONSB38_ELF  = build_consb38()
THRDA39_ELF  = build_thrda39()
THRDB39_ELF  = build_thrdb39()
READER43_ELF = build_reader43()
WRITER43_ELF = build_writer43()

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

hello_clusters   = write_clusters(2, HELLO_PAYLOAD)
prog_clusters    = write_clusters(hello_clusters[-1] + 1, PROG_ELF)
inita_clusters   = write_clusters(prog_clusters[-1] + 1, INITA_ELF)
childb_clusters  = write_clusters(inita_clusters[-1] + 1, CHILDB_ELF)
work_clusters    = write_clusters(childb_clusters[-1] + 1, b"\x00")
mark_clusters    = write_clusters(work_clusters[-1] + 1, b"\x00")
proda_clusters   = write_clusters(mark_clusters[-1] + 1, PRODA_ELF)
consb_clusters   = write_clusters(proda_clusters[-1] + 1, CONSB_ELF)
proda38_clusters = write_clusters(consb_clusters[-1] + 1, PRODA38_ELF)
consb38_clusters = write_clusters(proda38_clusters[-1] + 1, CONSB38_ELF)
thrda39_clusters = write_clusters(consb38_clusters[-1] + 1, THRDA39_ELF)
thrdb39_clusters = write_clusters(thrda39_clusters[-1] + 1, THRDB39_ELF)
reader43_clusters = write_clusters(thrdb39_clusters[-1] + 1, READER43_ELF)
writer43_clusters = write_clusters(reader43_clusters[-1] + 1, WRITER43_ELF)

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
    chain(proda38_clusters)
    chain(consb38_clusters)
    chain(thrda39_clusters)
    chain(thrdb39_clusters)
    chain(reader43_clusters)
    chain(writer43_clusters)
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
    (b"HELLO   TXT", hello_clusters[0],   len(HELLO_PAYLOAD)),
    (b"PROG    ELF", prog_clusters[0],    len(PROG_ELF)),
    (b"INITA   ELF", inita_clusters[0],   len(INITA_ELF)),
    (b"CHILDB  ELF", childb_clusters[0],  len(CHILDB_ELF)),
    (b"WORK    TXT", work_clusters[0],    0),
    (b"MARK    TXT", mark_clusters[0],    0),
    (b"PRODA   ELF", proda_clusters[0],   len(PRODA_ELF)),
    (b"CONSB   ELF", consb_clusters[0],   len(CONSB_ELF)),
    (b"PRODA38 ELF", proda38_clusters[0], len(PRODA38_ELF)),
    (b"CONSB38 ELF", consb38_clusters[0], len(CONSB38_ELF)),
    (b"THRDA39 ELF", thrda39_clusters[0], len(THRDA39_ELF)),
    (b"THRDB39 ELF", thrdb39_clusters[0], len(THRDB39_ELF)),
    (b"READER43ELF", reader43_clusters[0], len(READER43_ELF)),
    (b"WRITER43ELF", writer43_clusters[0], len(WRITER43_ELF)),
]
for i, (n83, fc, sz) in enumerate(entries):
    img[root_off + i * 32:root_off + i * 32 + 32] = dir_entry(n83, fc, sz)

# ---- Phase-42 file-backed mmap extent ----------------------------------
#   The kernel maps a FILE living at a known on-disk extent: N_PAGES 4 KiB pages,
#   8 sectors per page, starting at LBA P42_FILE_LBA. The kernel demand-reads each
#   page off this device on the faulting load and verifies the first 8 bytes equal
#   the per-page signature P42_FILE_SIG_BASE | (i<<8) | i (LITTLE-ENDIAN on disk,
#   so an aligned ldr of the first 8 bytes yields exactly that uint64). We seed the
#   whole 4 KiB of each page with a recognisable filler whose first 8 bytes are the
#   signature, so the demand read pulls real, distinct, known bytes off disk.
P42_FILE_LBA          = 3072
P42_SECTORS_PER_PAGE  = 8
P42_N_PAGES           = 2
P42_PAGE_BYTES        = P42_SECTORS_PER_PAGE * BPS   # 4096
P42_FILE_SIG_BASE     = 0xF11EDA7A00000000

def p42_sig(i):
    return (P42_FILE_SIG_BASE | (i << 8) | i) & 0xFFFFFFFFFFFFFFFF

assert (P42_FILE_LBA + P42_N_PAGES * P42_SECTORS_PER_PAGE) <= TOTAL_SECS, \
    "phase-42 file extent overruns the disk"

for i in range(P42_N_PAGES):
    page_lba  = P42_FILE_LBA + i * P42_SECTORS_PER_PAGE
    page_off  = page_lba * BPS
    page = bytearray(P42_PAGE_BYTES)
    # First 8 bytes = the per-page signature (little-endian).
    struct.pack_into("<Q", page, 0, p42_sig(i))
    # Fill the rest of the page with a per-page recognisable byte so the demand
    # read clearly pulled THIS page's distinct bytes (not a stale alias).
    filler = (0x70 + i) & 0xFF
    for b in range(8, P42_PAGE_BYTES):
        page[b] = filler
    img[page_off:page_off + P42_PAGE_BYTES] = page

with open(disk_path, "wb") as f:
    f.write(img)

assert img[510] == 0x55 and img[511] == 0xAA, "bad boot signature"
assert READER43_ELF[:4] == b"\x7fELF" and WRITER43_ELF[:4] == b"\x7fELF"
print("[fat16-builder] READER43=%s WRITER43=%s" % (reader43_clusters, writer43_clusters))
print("[fat16-builder] phase43 disk built; data_lba=%d file_lba=%d" % (data_lba, P42_FILE_LBA))
PYEOF

[ -s "$DISK" ] || fail "FAT16 disk image was not created"

cp -f "$DISK" "$SCRATCH" || fail "could not create writable scratch disk"
[ -s "$SCRATCH" ] || fail "writable scratch disk was not created"

# --- boot under qemu-system-aarch64: WRITABLE virtio-blk + virtio-net ---
#     The SAME machine/flags + virtio-blk disk backing prior phases. The kernel
#     halts in a WFI loop at the Phase-42 verdict, so QEMU never exits on its own;
#     the timeout (and a 124 rc) is expected and fine as long as every PASS banner
#     below is present.
timeout 420 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$ELF" \
    -drive if=none,file="$SCRATCH",format=raw,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -netdev user,id=n0 \
    -device virtio-net-device,netdev=n0 \
    >"$SERIAL" 2>&1
RC=$?

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase43] captured serial (tail):"
    tail -200 "$SERIAL" | sed 's/^/[test_arm64_phase43]   | /'
}

# --- guard against explicit failure markers / panics -------------------
for ph in 30 31 32 33 34 35 36 37 38 39 40 41 42 43; do
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
if grep -q -F "EL0 unknown syscall (phase 43)" "$SERIAL"; then
    dump_serial
    fail "a Phase-43 task issued an unknown syscall"
fi

# --- regression: prior phase milestones must still complete ------------
grep -q "$BANNER"        "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$P30_PASS"   "$SERIAL" || { dump_serial; fail "Phase-30 virtio-blk read regressed"; }
grep -q -F "$P31_PASS"   "$SERIAL" || { dump_serial; fail "Phase-31 FAT16 read regressed"; }
grep -q -F "$P32_PASS"   "$SERIAL" || { dump_serial; fail "Phase-32 on-disk ELF run regressed"; }
grep -q -F "$P33_PASS"   "$SERIAL" || { dump_serial; fail "Phase-33 virtio-net ARP regressed"; }
grep -q -F "$P34_PASS"   "$SERIAL" || { dump_serial; fail "Phase-34 IPv4/ICMP echo regressed"; }
grep -q -F "$P35_PASS"   "$SERIAL" || { dump_serial; fail "Phase-35 FAT16 write regressed"; }
grep -q -F "$P36_PASS"   "$SERIAL" || { dump_serial; fail "Phase-36 multi-process userland regressed"; }
grep -q -F "$P37_PASS"   "$SERIAL" || { dump_serial; fail "Phase-37 blocking-pipe IPC regressed"; }
grep -q -F "$P38_PASS"   "$SERIAL" || { dump_serial; fail "Phase-38 shm IPC regressed"; }
grep -q -F "$P39_PASS"   "$SERIAL" || { dump_serial; fail "Phase-39 futex thread-sync regressed"; }
grep -q -F "$P40_PASS"   "$SERIAL" || { dump_serial; fail "Phase-40 TCP loopback regressed"; }
grep -q -F "$P41_PASS"   "$SERIAL" || { dump_serial; fail "Phase-41 demand-paged anon mmap regressed (Phase 42 not reached)"; }

# --- regression: Phase 42 file-backed demand-paged mmap must still verify
grep -q -F "$P42_PASS"   "$SERIAL" || { dump_serial; fail "Phase-42 file-backed demand-paged mmap regressed (Phase 43 not reached)"; }

# --- Phase 43 assertions ----------------------------------------------
grep -q -F "$PHASE43"    "$SERIAL" || { dump_serial; fail "Phase-43 blocking-pipe IPC demo did not start"; }
grep -q -F "$READA43"    "$SERIAL" || { dump_serial; fail "Phase-43 never read READER43.ELF off disk"; }
grep -q -F "$READB43"    "$SERIAL" || { dump_serial; fail "Phase-43 never read WRITER43.ELF off disk"; }
grep -q -F "$LAUNCH43"   "$SERIAL" || { dump_serial; fail "Phase-43 reader+writer EL0 tasks never launched"; }
# CORE proof: the reader must call pipe_read on an EMPTY ring and GENUINELY
# block (descheduled into SLEEPING / parked), then be woken by a write that
# delivers the queued bytes. Assert both the block marker and the wake marker.
grep -q -F "$RBLOCK43"   "$SERIAL" || { dump_serial; fail "Phase-43 reader never blocked on an empty pipe (it polled or pre-mapped?)"; }
grep -q -F "$RWAKE43"    "$SERIAL" || { dump_serial; fail "Phase-43 blocked reader was never woken by a write"; }
# REVERSE proof: the small ring fills mid-message so the writer blocks on a
# FULL ring until the reader's next pipe_read drains it and wakes the writer.
grep -q -F "$WBLOCK43"   "$SERIAL" || { dump_serial; fail "Phase-43 writer never filled the ring (full-pipe block path not exercised)"; }
grep -q -F "$WWAKE43"    "$SERIAL" || { dump_serial; fail "Phase-43 blocked writer was never woken by a drain"; }
grep -q -F "$SUMMARY43"  "$SERIAL" || { dump_serial; fail "Phase-43 summary line not emitted"; }
grep -q -F "$P43_PASS"   "$SERIAL" || { dump_serial; fail "'$P43_PASS' not found (Phase 43 blocking pipe IPC did not verify)"; }

echo "[test_arm64_phase43] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase43] phase 40 OK (regr)    : $(grep -F "$P40_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase43] phase 41 OK (regr)    : $(grep -F "$P41_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase43] phase 42 OK (regr)    : $(grep -F "$P42_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase43] phase 43 start        : $(grep -F "$PHASE43" "$SERIAL" | head -1)"
echo "[test_arm64_phase43] reader/writer loaded  :"
grep -F "$READA43" "$SERIAL" | sed 's/^/[test_arm64_phase43]   | /'
grep -F "$READB43" "$SERIAL" | sed 's/^/[test_arm64_phase43]   | /'
echo "[test_arm64_phase43] launch                : $(grep -F "$LAUNCH43" "$SERIAL" | head -1)"
echo "[test_arm64_phase43] reader blocked (empty): $(grep -F "$RBLOCK43" "$SERIAL" | head -1)"
echo "[test_arm64_phase43] reader woken by write : $(grep -F "$RWAKE43" "$SERIAL" | head -1)"
echo "[test_arm64_phase43] writer blocked (full) : $(grep -F "$WBLOCK43" "$SERIAL" | head -1)"
echo "[test_arm64_phase43] writer woken by drain : $(grep -F "$WWAKE43" "$SERIAL" | head -1)"
echo "[test_arm64_phase43] summary line          : $(grep -F "$SUMMARY43" "$SERIAL" | head -1)"
echo "[test_arm64_phase43] phase 43 PASS line    : $(grep -F "$P43_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase43] (qemu rc=$RC; a 124 timeout with all PASS banners is acceptable)"
echo "[test_arm64_phase43] PASS"
