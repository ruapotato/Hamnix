#!/usr/bin/env bash
# scripts/test_arm64_phase39.sh — PHASE 39 multi-arch milestone: REAL EL0
# FUTEX-BASED THREAD SYNCHRONIZATION between TWO EL0 THREADS that SHARE ONE
# address space (CLONE_VM-style) running CONCURRENTLY under the live preemptive
# timer scheduler on bare aarch64 (qemu-virt). This is the Linux pthread foundation.
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
# Handed off from the Phase-38 PASS, the kernel:
#   1. reads THRDA39.ELF (waiter) and THRDB39.ELF (waker) off the FAT16 disk and
#      loads BOTH into ONE shared ASID-tagged EL0 address space (same page tables +
#      same ASID), at DISTINCT text/stack VAs but a SHARED data VA — so both threads
#      observe ALL of each other's user memory directly (the futex word + the handoff
#      value live in the one shared data page);
#   2. runs BOTH at EL0 concurrently — the EL1 generic-timer IRQ round-robins the two
#      threads (no address-space swap between them: it is one TTBR0+ASID);
#   3. thread A (the waiter) issues futex_wait(&futex, EXPECTED) on the shared futex
#      word still holding EXPECTED — the compare-and-block check holds, so thread A
#      GENUINELY BLOCKS (descheduled into a BLOCKED state, parked on a self-loop,
#      SKIPPED by the round-robin picker, enqueued on the kernel wait-queue keyed by
#      the futex's user VA — it is NOT spinning);
#   4. thread B (the waker) stores a known handoff value into the SHARED data page,
#      bumps the futex word, then futex_wake(&futex, 1); the kernel cross-checks the
#      handoff bytes landed in the SHARED physical page (read directly off the data
#      page PA) and WAKES the blocked waiter (BLOCKED -> RUNNABLE);
#   5. thread A resumes, reads the handoff value out of the SHARED page (through the
#      shared address space), report()s it (the kernel cross-checks it byte-for-byte
#      against the known handoff value), and exit(0x77)s; thread B exit(0x88)s;
#   6. the kernel runs the verdict and prints "[arm64] Phase 39 PASS: ...".
#
# EL0 syscalls exercised: futex_wait(730)/futex_wake(731)/report(732)/exit(733).
# The PASS is kernel-verified: the waiter cannot fake the round-trip (the kernel
# compares the reported handoff value against the known value, AND requires both
# threads resolve the futex uaddr to the SAME physical memory (one shared AS), AND
# that the waiter actually blocked in futex_wait and was woken by the futex_wake).
#
# Phase 39 runs only AFTER Phase 38 prints its PASS marker, so every prior phase
# (4..38) must still run to completion (no regression).
#
# Prints "[test_arm64_phase39] PASS" on success or "[test_arm64_phase39] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
P30_PASS="[arm64] Phase 30 PASS: virtio-blk read sector 0 -> HAMNIXARM"
P31_PASS="[arm64] Phase 31 PASS: FAT16 read HELLO.TXT -> HAMNIX-ARM64-FS-OK"
P32_PASS="[arm64] Phase 32 PASS: loaded PROG.ELF from FAT16 disk and ran it at EL0"
P35_PASS="[arm64] Phase 35 PASS: virtio-blk WRITE + FAT16 filesystem write round-trip -> ARM64-WRITE-OK-A64"
P36_PASS="[arm64] Phase 36 PASS: multi-process FAT16 userland (INITA file round-trip + spawned CHILDB + reaped exit status + ordering)"
P37_PASS="[arm64] Phase 37 PASS: pipe IPC blocking round-trip"
P38_PASS="[arm64] Phase 38 PASS: shm IPC zero-copy round-trip"

PHASE39="[arm64] Phase 39: futex thread synchronization (two EL0 threads sharing ONE address space: THRDA39 + THRDB39)"
READA39="[arm64] Phase 39: read THRDA39.ELF off disk"
READB39="[arm64] Phase 39: read THRDB39.ELF off disk"
LAUNCH39="[arm64] Phase 39: launching thread A (waiter) + thread B (waker) in ONE address space (ASID 30)"
BLOCK39="[arm64] Phase 39: thread A futex_wait on unchanged futex word -> BLOCKED"
WAKE39="[arm64] Phase 39: futex_wake woke the BLOCKED waiter (thread A) -> RUNNABLE"
SUMMARY39="[arm64] Phase 39 summary: futex_va="
P39_PASS="[arm64] Phase 39 PASS: futex thread-sync round-trip"

fail() {
    echo "[test_arm64_phase39] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase39] qemu-system-aarch64 not found; attempting apt install"
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
WORK="$PROJ_ROOT/build/arm64_phase39_test"
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

# --- build the FAT16 backing disk: prior-phase files plus Phase-39
#     THRDA39.ELF + THRDB39.ELF --------------------------------------------
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

PA_TEXT_VA = 0x42600000
PA_DATA_VA = 0x42800000
PB_TEXT_VA = 0x42C00000
PB_DATA_VA = 0x42E00000
PA_SEQ_OFF = 0x00
PB_BUF_OFF = 0x00

# ---- Phase-38 ABI (must match kmain.ad constants) ----------------------
SYS_SHM_GET    = 720
SYS_SHM_ATTACH = 721
SYS_SIGNAL     = 722
SYS_WAIT       = 723
SYS_P38_REPORT = 724
SYS_P38_EXIT   = 725
P38_CHK_SHM    = 0
P38_PROD_EXIT  = 0x55   # 85
P38_CONS_EXIT  = 0x66   # 102
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

# ---- Phase-39 ABI (must match kmain.ad constants) ----------------------
SYS_P39_FUTEX_WAIT = 730
SYS_P39_FUTEX_WAKE = 731
SYS_P39_REPORT     = 732
SYS_P39_EXIT       = 733
P39_CHK_HANDOFF    = 0
P39_A_EXIT         = 0x77   # 119
P39_B_EXIT         = 0x88   # 136
P39_FUTEX_VA       = 0x42E00000     # shared data VA + futex off 0
P39_HANDOFF_VA     = 0x42E00040     # shared data VA + handoff off 0x40
P39_FUTEX_EXPECTED = 0x11
P39_FUTEX_BUMP     = 0x12           # thread B bumps the futex word past EXPECTED
P39_HANDOFF_VAL    = 0x5AC3

# Thread A (THRDA39) text/stack VAs; thread B (THRDB39) text/stack VAs. These match
# the kmain.ad Phase-39 P39A_*/P39B_* shared-address-space segment VAs.
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

def mov_reg(rd, rn):                       # mov rd, rn  (orr rd, xzr, rn)
    return 0xAA0003E0 | (rn << 16) | rd

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

# ---- assemble PRODA.ELF (Phase 37 producer) ---------------------------
def build_proda():
    words = []
    syscall(words, SYS_PIPE_WRITE, x0=PA_DATA_VA + PA_SEQ_OFF, x1=PROD_LEN)
    syscall(words, SYS_P37_EXIT, x0=PROD_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    data_seg[PA_SEQ_OFF:PA_SEQ_OFF + PROD_LEN] = PROD_PAYLOAD
    return assemble_elf(PA_TEXT_VA, PA_DATA_VA, code, bytes(data_seg))

# ---- assemble CONSB.ELF (Phase 37 consumer) ---------------------------
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

# ---- assemble PRODA38.ELF (Phase 38 producer) -------------------------
def build_proda38():
    words = []
    syscall(words, SYS_SHM_GET, x0=0)
    syscall(words, SYS_SHM_ATTACH, x0=0)
    words.append(mov_reg(19, 0))                       # x19 = shm VA
    words += load_imm64(20, P38A_DATA_VA + P38A_SEQ_OFF)
    words += load_imm64(21, 0)                          # i = 0
    words += load_imm64(22, P38_SHM_LEN)
    cpy_idx = len(words)
    words.append(0x38606800 | (21 << 16) | (20 << 5) | 0)  # ldrb w0,[x20,x21]
    words.append(0x38206800 | (21 << 16) | (19 << 5) | 0)  # strb w0,[x19,x21]
    words.append(0x91000400 | (21 << 5) | 21)              # add x21,x21,#1
    words.append(0xEB000000 | (22 << 16) | (21 << 5) | 31) # cmp x21,x22
    br_idx = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)              # b.lt cpy
    rel = cpy_idx - br_idx
    words[br_idx] = 0x54000000 | ((rel & 0x7FFFF) << 5) | 0xB
    syscall(words, SYS_SIGNAL, x0=P38_SIGNAL_VAL)
    syscall(words, SYS_P38_EXIT, x0=P38_PROD_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    data_seg[P38A_SEQ_OFF:P38A_SEQ_OFF + P38_SHM_LEN] = SHM_PAYLOAD
    return assemble_elf(P38A_TEXT_VA, P38A_DATA_VA, code, bytes(data_seg))

# ---- assemble CONSB38.ELF (Phase 38 consumer) -------------------------
def build_consb38():
    words = []
    syscall(words, SYS_SHM_GET, x0=0)
    syscall(words, SYS_SHM_ATTACH, x0=0)
    words.append(mov_reg(19, 0))                       # x19 = shm VA
    words += load_imm64(8, SYS_WAIT)
    words.append(SVC0)
    words += load_imm64(0, P38_CHK_SHM)
    words.append(mov_reg(1, 19))                       # x1 = shm VA
    words += load_imm64(2, P38_SHM_LEN)
    words += load_imm64(8, SYS_P38_REPORT)
    words.append(SVC0)
    syscall(words, SYS_P38_EXIT, x0=P38_CONS_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    return assemble_elf(P38B_TEXT_VA, P38B_DATA_VA, code, bytes(data_seg))

# ---- assemble THRDA39.ELF (Phase 39 thread A, the waiter) -------------
# futex_wait(&futex, EXPECTED) -> BLOCKS until thread B futex_wakes; then read the
# 32-bit handoff value out of the SHARED data page (through the shared address
# space) and report() it; then exit(A_EXIT).
#   futex_wait(x0=FUTEX_VA, x1=EXPECTED, x8=730) ; svc
#   x19 = HANDOFF_VA ; ldr w20, [x19] (32-bit load of the handoff value)
#   report(x0=CHK_HANDOFF, x1=w20, x8=732) ; svc
#   exit(A_EXIT)
def build_thrda39():
    words = []
    syscall(words, SYS_P39_FUTEX_WAIT, x0=P39_FUTEX_VA, x1=P39_FUTEX_EXPECTED)
    words += load_imm64(19, P39_HANDOFF_VA)
    # ldr w20, [x19]   (LDR (immediate, unsigned offset), 32-bit): 0xB9400000 | (Rn<<5)|Rt
    words.append(0xB9400000 | (19 << 5) | 20)
    # report(CHK_HANDOFF, x1=x20)
    words += load_imm64(0, P39_CHK_HANDOFF)
    words.append(mov_reg(1, 20))                       # x1 = handoff value read
    words += load_imm64(8, SYS_P39_REPORT)
    words.append(SVC0)
    syscall(words, SYS_P39_EXIT, x0=P39_A_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    return assemble_elf(P39A_TEXT_VA, P39A_STACK_VA, code, bytes(data_seg),
                        data_va_override=P39_DATA_VA, no_data_seg=True)

# ---- assemble THRDB39.ELF (Phase 39 thread B, the waker) -------------
# store the known handoff value into the SHARED data page; bump the futex word past
# EXPECTED (so a late futex_wait would not block); futex_wake(&futex, 1); exit(B).
#   x19 = HANDOFF_VA ; x20 = HANDOFF_VAL ; str w20, [x19]
#   x21 = FUTEX_VA   ; x22 = FUTEX_BUMP  ; str w22, [x21]
#   futex_wake(x0=FUTEX_VA, x1=1, x8=731) ; svc
#   exit(B_EXIT)
def build_thrdb39():
    words = []
    words += load_imm64(19, P39_HANDOFF_VA)
    words += load_imm64(20, P39_HANDOFF_VAL)
    # str w20, [x19]   (STR (immediate, unsigned offset), 32-bit): 0xB9000000 | (Rn<<5)|Rt
    words.append(0xB9000000 | (19 << 5) | 20)
    words += load_imm64(21, P39_FUTEX_VA)
    words += load_imm64(22, P39_FUTEX_BUMP)
    words.append(0xB9000000 | (21 << 5) | 22)          # str w22, [x21]
    syscall(words, SYS_P39_FUTEX_WAKE, x0=P39_FUTEX_VA, x1=1)
    syscall(words, SYS_P39_EXIT, x0=P39_B_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    return assemble_elf(P39B_TEXT_VA, P39B_STACK_VA, code, bytes(data_seg),
                        data_va_override=P39_DATA_VA, no_data_seg=True)

def assemble_elf(text_va, data_va, code, data_bytes,
                 data_va_override=None, no_data_seg=False):
    # data_va is the writable segment VA used for the PT_LOAD #2 RW segment. For the
    # Phase-39 threads we want the RW segment to declare the SHARED data VA (so the
    # kernel loader recognizes + skips it, leaving its seeded futex word intact) and
    # carry NO file bytes (the page is kernel-seeded). no_data_seg makes the RW
    # segment zero-length-filesz at the override VA.
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

PROG_ELF     = build_prog()
INITA_ELF    = build_inita()
CHILDB_ELF   = build_childb()
PRODA_ELF    = build_proda()
CONSB_ELF    = build_consb()
PRODA38_ELF  = build_proda38()
CONSB38_ELF  = build_consb38()
THRDA39_ELF  = build_thrda39()
THRDB39_ELF  = build_thrdb39()

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
]
for i, (n83, fc, sz) in enumerate(entries):
    img[root_off + i * 32:root_off + i * 32 + 32] = dir_entry(n83, fc, sz)

with open(disk_path, "wb") as f:
    f.write(img)

assert img[510] == 0x55 and img[511] == 0xAA, "bad boot signature"
assert THRDA39_ELF[:4] == b"\x7fELF" and THRDB39_ELF[:4] == b"\x7fELF"
print("[fat16-builder] THRDA39=%s THRDB39=%s" % (thrda39_clusters, thrdb39_clusters))
print("[fat16-builder] THRDA39.ELF=%d THRDB39.ELF=%d bytes; data_lba=%d"
      % (len(THRDA39_ELF), len(THRDB39_ELF), data_lba))
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
    echo "[test_arm64_phase39] captured serial (tail):"
    tail -160 "$SERIAL" | sed 's/^/[test_arm64_phase39]   | /'
}

# --- guard against explicit failure markers / panics -------------------
for ph in 30 31 32 35 36 37 38 39; do
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
if grep -q -F "EL0 unknown syscall (phase 39)" "$SERIAL"; then
    dump_serial
    fail "a Phase-39 thread issued an unknown syscall"
fi

# --- regression: prior phase milestones must still complete ------------
grep -q "$BANNER"        "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$P30_PASS"   "$SERIAL" || { dump_serial; fail "Phase-30 virtio-blk read regressed"; }
grep -q -F "$P31_PASS"   "$SERIAL" || { dump_serial; fail "Phase-31 FAT16 read regressed"; }
grep -q -F "$P32_PASS"   "$SERIAL" || { dump_serial; fail "Phase-32 on-disk ELF run regressed"; }
grep -q -F "$P35_PASS"   "$SERIAL" || { dump_serial; fail "Phase-35 FAT16 write regressed"; }
grep -q -F "$P36_PASS"   "$SERIAL" || { dump_serial; fail "Phase-36 multi-process userland regressed"; }
grep -q -F "$P37_PASS"   "$SERIAL" || { dump_serial; fail "Phase-37 blocking-pipe IPC regressed"; }
grep -q -F "$P38_PASS"   "$SERIAL" || { dump_serial; fail "Phase-38 shm IPC regressed (Phase 39 not reached)"; }

# --- Phase 39 assertions ----------------------------------------------
grep -q -F "$PHASE39"   "$SERIAL" || { dump_serial; fail "Phase-39 futex demo did not start"; }
grep -q -F "$READA39"   "$SERIAL" || { dump_serial; fail "Phase-39 did not read THRDA39.ELF off disk"; }
grep -q -F "$READB39"   "$SERIAL" || { dump_serial; fail "Phase-39 did not read THRDB39.ELF off disk"; }
grep -q -F "$LAUNCH39"  "$SERIAL" || { dump_serial; fail "Phase-39 did not launch both threads"; }
grep -q -F "$BLOCK39"   "$SERIAL" || { dump_serial; fail "Phase-39 waiter never BLOCKED in futex_wait (no blocking proof)"; }
grep -q -F "$WAKE39"    "$SERIAL" || { dump_serial; fail "Phase-39 futex_wake never woke the blocked waiter"; }
grep -q -F "$SUMMARY39" "$SERIAL" || { dump_serial; fail "Phase-39 summary line not emitted"; }
grep -q -F "$P39_PASS"  "$SERIAL" || { dump_serial; fail "'$P39_PASS' not found (Phase 39 futex round-trip did not verify)"; }

echo "[test_arm64_phase39] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase39] phase 38 OK (regr)    : $(grep -F "$P38_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase39] phase 39 start        : $(grep -F "$PHASE39" "$SERIAL" | head -1)"
echo "[test_arm64_phase39] waiter blocked        : $(grep -F "$BLOCK39" "$SERIAL" | head -1)"
echo "[test_arm64_phase39] futex_wake woke waiter: $(grep -F "$WAKE39" "$SERIAL" | head -1)"
echo "[test_arm64_phase39] summary line          : $(grep -F "$SUMMARY39" "$SERIAL" | head -1)"
echo "[test_arm64_phase39] phase 39 PASS line    : $(grep -F "$P39_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase39] PASS"
