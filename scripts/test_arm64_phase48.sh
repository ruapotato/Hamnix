#!/usr/bin/env bash
# scripts/test_arm64_phase48.sh — PHASE 48 milestone: EL0 THREE-STAGE PIPELINE (a parent
# forks THREE distinct children connected by TWO kernel pipes: producer | filter |
# consumer) on bare aarch64 (qemu-virt). Chains off the Phase-47 PASS branch.
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
# A PARENT EL0 task creates TWO kernel pipes (ring A: producer -> filter; ring B: filter
# -> consumer), then fork()'s THREE genuinely DISTINCT child tasks, each with a fresh pid
# into its OWN private address space (separate L1 root + ASID + backing pages). Each
# child execve()'s a DIFFERENT on-disk ELF off the live FAT16 virtio-blk volume:
#   * PRODP48.ELF (producer P) writes a known message into ring A, GENUINELY BLOCKING
#     when the small ring fills until the filter drains it.
#   * FILTP48.ELF (filter F) — the NEW core mechanism — simultaneously CONSUMES ring A
#     and PRODUCES ring B: it reads one byte from A (BLOCKING when A is empty), XOR-
#     transforms it, and writes it to B (BLOCKING when B is full), for the whole stream.
#     A single EL0 process thus blocks on BOTH pipes in BOTH directions, proving back-
#     pressure propagates through the middle stage.
#   * CONSP48.ELF (consumer C) reads the transformed stream out of ring B (BLOCKING when
#     B is empty) and reports it; the kernel cross-checks it byte-for-byte against
#     XOR(known producer message) — C cannot fake the transformed round-trip.
# Each child is woken ONLY by its peer's pipe op — real blocking IPC chained through a
# middle filter stage across THREE SEPARATE forked processes. The PARENT wait()'s for
# ALL THREE children, GENUINELY BLOCKING (descheduled, state WAITING) until each exit()'s;
# the kernel reaps them + wakes the parent with their statuses. Each task runs under its
# OWN TTBR0+ASID throughout (real process isolation). The kernel prints "Phase 48 PASS:".
#
# The PASS is kernel-verified and cannot be faked: it requires THREE forks returning
# distinct child pids each wired into its own private address space, each child to execve
# a DIFFERENT on-disk ELF into its own text + run it, the producer to BLOCK on a full
# ring A, the filter to BLOCK on BOTH an empty ring A and a full ring B, the consumer to
# BLOCK on an empty ring B, the picker to skip the blocked tasks, the byte counts to flow
# prod_out == filt_in == filt_out == cons_in == MSG_LEN, the consumer's bytes to equal
# XOR(producer message) byte-for-byte, the parent to BLOCK in wait() + reap ALL THREE
# children with their expected statuses, and all four to exit with their expected statuses.
#
# Phase 48 runs only AFTER Phase 47 prints its PASS marker, so every prior phase
# (4..47) must still run to completion (no regression).
#
# Prints "[test_arm64_phase48] PASS" on success or "[test_arm64_phase48] FAIL ...".
#
# A QEMU teardown rc 139/143/124 AFTER all PASS banners is acceptable (the kernel halts
# in a WFI loop at the Phase-48 verdict; the grep assertions below are authoritative).
#
# ---- (verbatim Phase-43 prelude follows; all prior phases must still pass) ----
# scripts/test_arm64_phase43.sh — PHASE 42 milestone: REAL EL0 FILE-backed mmap,
# demand-paged from the on-disk virtio-blk device on bare aarch64 (qemu-virt).
# A single EL0 task maps a FILE (a known on-disk extent with known contents) as a
# lazily-backed read-only window that is initially UNMAPPED; the kernel
# materialises it on demand by READING the file's bytes off disk on each fault.
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
# Prints "[test_arm64_phase48] PASS" on success or "[test_arm64_phase48] FAIL ...".
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
# Phase 43 PASS is now a REGRESSION guard (Phase 44 chains off Phase 43).
P43_PASS="[arm64] Phase 43 PASS: EL0 blocking pipe IPC (reader slept on empty pipe, writer woke it; writer slept on full pipe, reader woke it; message round-tripped byte-for-byte)"

# Phase 44 progress + verdict markers (EL0 async signal delivery + sigreturn).
PHASE44="[arm64] Phase 44: EL0 userspace signal delivery + sigreturn (async timer-delivered signal to a running EL0 task)"
LAUNCH44="[arm64] Phase 44: launching EL0 signal task (ASID 44) under the timer; entry="
DELIVER44="[arm64] Phase 44: timer delivered signal to the RUNNING EL0 task; pushed signal frame @ "
HANDLER44="[arm64] Phase 44: EL0 signal handler ran; signo="
SIGRET44="[arm64] Phase 44: sigreturn restored the interrupted frame; resuming EL0 loop at PC="
RESULT44="[arm64] Phase 44: task reported final accumulator="
SUMMARY44="[arm64] Phase 44 summary: delivered="
# Phase 44 PASS is now a REGRESSION guard (Phase 45 chains off Phase 44).
P44_PASS="[arm64] Phase 44 PASS: EL0 userspace signal delivery + sigreturn (timer delivered a signal to a running task, pushed a real frame on its EL0 stack, ran a user handler that set an observable sentinel, and sigreturn restored the frame so the interrupted loop resumed and completed with the expected value)"

# Phase 45 progress + verdict markers (EL0 CROSS-TASK signal delivery; two EL0 tasks).
PHASE45="[arm64] Phase 45: EL0 cross-task signal delivery (two EL0 tasks, one address space: SIGNALLER A + TARGET B; A kills B, kernel queues + delivers on B's return-to-EL0)"
LAUNCH45="[arm64] Phase 45: launching task A (signaller) + task B (target) in ONE address space (ASID 45); entry_a="
KILL45="kill -> QUEUED signo "
DELIVER45="[arm64] Phase 45: delivered the QUEUED signal to target task B on its return-to-EL0; pushed signal frame @ "
HANDLER45="[arm64] Phase 45: target task B EL0 signal handler ran; signo="
SIGRET45="[arm64] Phase 45: sigreturn restored B's interrupted frame; resuming B's EL0 loop at PC="
RESULT45="[arm64] Phase 45: target task B reported final accumulator="
SUMMARY45="[arm64] Phase 45 summary: queued_by="
P45_PASS="[arm64] Phase 45 PASS: EL0 cross-task signal delivery (task A queued a pending signal on task B; the kernel delivered it asynchronously on B's next return-to-EL0, pushed a real frame on B's EL0 stack, ran B's user handler with the right signo + set an observable sentinel, and B's sigreturn restored B's frame so its interrupted loop resumed and completed with the expected value)"

# Phase 46 progress + verdict markers (EL0 process lifecycle: fork + exec + wait).
PHASE46="[arm64] Phase 46: EL0 process lifecycle (fork + exec + wait)"
LAUNCH46="[arm64] Phase 46: launching the PARENT task (private ASID "
FORK46="[arm64] Phase 46: parent fork() -> created DISTINCT child task (pid "
EXEC46="[arm64] Phase 46: child execve(CHILDB46.ELF) replaced its image ("
CHILDRESULT46="[arm64] Phase 46: exec'd child reported accumulation sum="
BLOCK46="[arm64] Phase 46: parent wait(pid="
WOKE46="[arm64] Phase 46: child exit reaped -> WOKE the BLOCKED parent (wait returns status="
REAPED46="[arm64] Phase 46: parent reported REAPED child status="
SUMMARY46="[arm64] Phase 46 summary: forked="
P46_PASS="[arm64] Phase 46 PASS: EL0 process lifecycle (fork created a distinct child in a private address space; the child execve'd a different on-disk ELF and ran it to completion with the kernel-verified result; the parent blocked in wait() and was woken on the child's exit; the reaped exit status matched what the child returned)"

# Phase 47 progress + verdict markers (EL0 shell pipeline: fork TWO children + a pipe).
PHASE47="[arm64] Phase 47: EL0 shell pipeline (writer | reader): a parent forks TWO distinct children connected by a kernel pipe"
LAUNCH47="[arm64] Phase 47: launching the PARENT task (private ASID "
# Two distinct forks (writer pid + reader pid) into separate private address spaces.
FORK47="[arm64] Phase 47: parent fork() -> created DISTINCT child task (pid "
# Each child execve'd a DIFFERENT on-disk ELF (read off the live FAT16 disk).
EXECW47="[arm64] Phase 47: child W execve(WRITP47.ELF) replaced its image ("
EXECR47="[arm64] Phase 47: child R execve(READP47.ELF) replaced its image ("
# CORE blocking-IPC evidence across the two SEPARATE forked processes.
RBLOCK47="[arm64] Phase 47: child R pipe_read on EMPTY pipe -> SLEEPING"
RWAKE47="[arm64] Phase 47: pipe_write delivered to + woke the BLOCKED reader (child R) -> RUNNABLE"
WBLOCK47="[arm64] Phase 47: child W pipe_write filled the ring"
WWAKE47="[arm64] Phase 47: a read drained the ring -> woke the BLOCKED writer (child W) -> RUNNABLE"
# The reader reports the received bytes; the kernel cross-checks them byte-for-byte.
REPORT47="[arm64] Phase 47: child R report received "
# The parent BLOCKS in wait() and is woken on each child's exit, reaping both.
BLOCK47="[arm64] Phase 47: parent wait(pid="
WOKE47="[arm64] Phase 47: child exit reaped -> WOKE the BLOCKED parent (wait pid="
# Second-child reap: the parent (already runnable) re-enters wait() and finds the
# reader child already-exited, reaping it without having to block again.
REAPED47="[arm64] Phase 47: parent wait(pid="
SUMMARY47="[arm64] Phase 47 summary: forks="
P47_PASS="[arm64] Phase 47 PASS: EL0 shell pipeline (parent forked TWO distinct children connected by a kernel pipe; the writer-child blocked on a full ring + the reader-child blocked on an empty pipe, each woken by the peer across separate address spaces; the message round-tripped byte-for-byte; the parent reaped both children)"

# --- Phase 48 markers: 3-stage pipeline (producer | filter | consumer) over TWO pipes ---
PHASE48="[arm64] Phase 48: EL0 three-stage pipeline (producer | filter | consumer)"
LAUNCH48="[arm64] Phase 48: launching the PARENT task (private ASID "
FORK48="[arm64] Phase 48: parent fork() -> created DISTINCT child task (pid "
EXECP48="[arm64] Phase 48: child P execve(PRODP48.ELF) replaced its image ("
EXECF48="[arm64] Phase 48: child F execve(FILTP48.ELF) replaced its image ("
EXECC48="[arm64] Phase 48: child C execve(CONSP48.ELF) replaced its image ("
# Producer P blocks on a FULL ring A; the filter's read_A drains it + wakes P.
PBLOCK48="[arm64] Phase 48: producer P write_A filled ring A -> SLEEPING (parked, sleep #"
PWAKE48="[arm64] Phase 48: read_A drained ring A -> woke the BLOCKED producer P (full ring A) -> RUNNABLE"
# Filter F blocks on an EMPTY ring A; the producer's write_A delivers + wakes F.
FBLOCKA48="[arm64] Phase 48: filter F read_A on EMPTY ring A -> SLEEPING (parked, sleep #"
FWAKEA48="[arm64] Phase 48: write_A delivered to + woke the BLOCKED filter F (empty ring A) -> RUNNABLE"
# Filter F blocks on a FULL ring B; the consumer's read_B drains it + wakes F.
FBLOCKB48="[arm64] Phase 48: filter F write_B filled ring B -> SLEEPING (parked, sleep #"
FWAKEB48="[arm64] Phase 48: read_B drained ring B -> woke the BLOCKED filter F (full ring B) -> RUNNABLE"
# Consumer C blocks on an EMPTY ring B; the filter's write_B delivers + wakes C.
CBLOCK48="[arm64] Phase 48: consumer C read_B on EMPTY ring B -> SLEEPING (parked, sleep #"
CWAKE48="[arm64] Phase 48: write_B delivered to + woke the BLOCKED consumer C (empty ring B) -> RUNNABLE"
# Consumer reports the transformed bytes; kernel cross-checks them byte-for-byte (match=1).
REPORT48="[arm64] Phase 48: consumer C report received "
# Parent blocks in wait(); a child exit reaps + wakes it.
BLOCK48="[arm64] Phase 48: parent wait(pid="
WOKE48="[arm64] Phase 48: child exit reaped -> WOKE the BLOCKED parent (wait pid="
REAPED48="[arm64] Phase 48: parent wait(pid="
SUMMARY48="[arm64] Phase 48 summary: forks="
P48_PASS="[arm64] Phase 48 PASS: EL0 three-stage pipeline (producer | filter | consumer over TWO kernel pipes; the producer blocked on a full ring A, the filter blocked on BOTH an empty ring A and a full ring B while transforming each byte, the consumer blocked on an empty ring B, each woken by its peer across separate address spaces; the XOR-transformed stream round-tripped byte-for-byte; the parent reaped all three children)"

fail() {
    echo "[test_arm64_phase48] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase48] qemu-system-aarch64 not found; attempting apt install"
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
WORK="$PROJ_ROOT/build/arm64_phase46_test"
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

# ---- Phase-46 ABI (must match kmain.ad constants) ----------------------
SYS_P46_FORK   = 770
SYS_P46_EXEC   = 771
SYS_P46_WAIT   = 772
SYS_P46_REPORT = 773
SYS_P46_EXIT   = 774
P46_CHK_CHILD_RESULT = 0
P46_CHILD_EXIT  = 0x4C   # 76 — the child's exit status (the parent reaps it)
P46_LOOP_N      = 0x40000
P46C_TEXT_VA    = 0x47C00000   # child text (the exec'd image's load VA)
P46C_STACK_VA   = 0x47E00000   # child stack (kernel pre-wires it)
P46_RESULT_VA   = 0x48000000   # child writes marker @ +0, accumulation sum @ +8
P46_RESULT_MAGIC = 0x46C0DE4600000046

# ---- assemble CHILDB46.ELF (the DIFFERENT on-disk image the child execve's) -------
# The freshly-loaded image accumulates 0+1+...+(N-1) into x19, stores an observable
# result marker + the sum into its data page (pre-wired RW by the kernel), reports the
# sum (kernel cross-checks it == expected), and exits with P46_CHILD_EXIT. Text loads
# at P46C_TEXT_VA so the exec loader maps it into the child's own text page; the data
# page is wired + zeroed by the kernel's build_child_space (no data segment here).
def build_childb46():
    words = []
    words += load_imm64(19, 0)                              # x19 = accumulator
    words += load_imm64(20, 0)                              # x20 = i
    words += load_imm64(21, P46_LOOP_N)                     # x21 = N
    loop_idx = len(words)
    words.append(0x8B000000 | (20 << 16) | (19 << 5) | 19)  # add x19, x19, x20
    words.append(0x91000400 | (20 << 5) | 20)               # add x20, x20, #1
    words.append(0xEB000000 | (21 << 16) | (20 << 5) | 31)  # cmp x20, x21
    branch_idx = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)               # b.lt placeholder
    rel = loop_idx - branch_idx
    words[branch_idx] = 0x54000000 | ((rel & 0x7FFFF) << 5) | 0xB
    # store the observable marker @ P46_RESULT_VA[0]
    words += load_imm64(9, P46_RESULT_MAGIC)
    words += load_imm64(10, P46_RESULT_VA)
    words.append(0xF9000000 | (10 << 5) | 9)                # str x9, [x10]
    # store the accumulation sum @ P46_RESULT_VA[1]
    words += load_imm64(10, P46_RESULT_VA + 8)
    words.append(0xF9000000 | (10 << 5) | 19)               # str x19, [x10]
    # report(CHK_CHILD_RESULT, x19)
    words += load_imm64(0, P46_CHK_CHILD_RESULT)
    words.append(0xAA0003E0 | (19 << 16) | 1)               # mov x1, x19
    words += load_imm64(8, SYS_P46_REPORT)
    words.append(SVC0)
    # exit(CHILD_EXIT)
    syscall(words, SYS_P46_EXIT, x0=P46_CHILD_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    return assemble_elf(P46C_TEXT_VA, P46C_STACK_VA, code, bytes(data_seg),
                        data_va_override=P46_RESULT_VA, no_data_seg=True)

# ---- Phase-47 ABI (must match kmain.ad constants) ----------------------
# The on-disk ELFs the two forked children execve. WRITP47.ELF loops pipe_write over
# the kernel-seeded source until the whole message is sent (BLOCKING on the small full
# ring); READP47.ELF loops pipe_read until it has the whole message (BLOCKING on the
# empty pipe), then reports the received bytes for the kernel's byte-for-byte check.
SYS_P47_FORK       = 780
SYS_P47_EXEC       = 781
SYS_P47_PIPE_WRITE = 782
SYS_P47_PIPE_READ  = 783
SYS_P47_REPORT     = 784
SYS_P47_WAIT       = 785
SYS_P47_EXIT       = 786
P47_CHK_PIPE       = 0
P47_WRITER_EXIT    = 0x57   # 87  — child W's exit status (kernel cross-checks it)
P47_READER_EXIT    = 0x52   # 82  — child R's exit status (kernel cross-checks it)
P47_MSG_LEN        = 40
# Child W (writer) text load VA + its source data VA; child R (reader) text load VA +
# its receive data VA. These are the exec'd images' load addresses (the kernel maps each
# into the child's OWN text page). Match the kmain.ad P47W_*/P47R_* globals.
P47W_TEXT_VA = 0x49000000      # writer-child text (the exec'd image's load VA)
P47R_TEXT_VA = 0x49600000      # reader-child text (the exec'd image's load VA)
P47_SRC_VA   = 0x49400000      # = P47W_DATA_VA: writer's kernel-seeded source message
P47_RECV_VA  = 0x49A00000      # = P47R_DATA_VA: reader's reassembled bytes

# ---- assemble WRITP47.ELF (the writer-child's exec'd image) ------------
# Loop pipe_write(SRC_VA + total, MSG_LEN - total) accumulating the returned count into
# x19 until x19 == MSG_LEN. The kernel ring is small (CAP < MSG_LEN), so an early write
# fills it and the writer BLOCKS on the full ring until the reader drains it; then
# exit(WRITER_EXIT). The source data page is seeded with the known message by the kernel.
# (Same loop shape as the Phase-43 writer, but with Phase-47 syscalls/VAs.)
def build_writp47():
    words = []
    words += load_imm64(19, 0)                              # x19 = total sent
    loop_idx = len(words)
    words += load_imm64(20, P47_SRC_VA)
    words.append(0x8B000000 | (19 << 16) | (20 << 5) | 0)   # add x0, x20, x19  (src) -- a0 = buf
    words += load_imm64(21, P47_MSG_LEN)
    words.append(0xCB000000 | (19 << 16) | (21 << 5) | 1)   # sub x1, x21, x19  (len) -- a1 = len
    words += load_imm64(8, SYS_P47_PIPE_WRITE)
    words.append(SVC0)
    words.append(0x8B000000 | (0 << 16) | (19 << 5) | 19)   # add x19, x19, x0
    words += load_imm64(22, P47_MSG_LEN)
    words.append(0xEB000000 | (22 << 16) | (19 << 5) | 31)  # cmp x19, x22
    branch_idx = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)               # b.lt placeholder
    rel = loop_idx - branch_idx
    words[branch_idx] = 0x54000000 | ((rel & 0x7FFFF) << 5) | 0xB
    syscall(words, SYS_P47_EXIT, x0=P47_WRITER_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    return assemble_elf(P47W_TEXT_VA, P47_SRC_VA, code, bytes(data_seg),
                        data_va_override=P47_SRC_VA, no_data_seg=True)

# ---- assemble READP47.ELF (the reader-child's exec'd image) ------------
# Loop pipe_read(RECV_VA + total, MSG_LEN - total) accumulating the returned count into
# x19 until x19 == MSG_LEN (the first read BLOCKS on the empty pipe); then
# report(CHK_PIPE, RECV_VA, MSG_LEN) so the kernel cross-checks the bytes byte-for-byte,
# and exit(READER_EXIT). (Same loop shape as the Phase-43 reader, with Phase-47
# syscalls/VAs.)
def build_readp47():
    words = []
    words += load_imm64(19, 0)                              # x19 = total received
    loop_idx = len(words)
    words += load_imm64(20, P47_RECV_VA)
    words.append(0x8B000000 | (19 << 16) | (20 << 5) | 0)   # add x0, x20, x19  (dst) -- a0 = buf
    words += load_imm64(21, P47_MSG_LEN)
    words.append(0xCB000000 | (19 << 16) | (21 << 5) | 1)   # sub x1, x21, x19  (len) -- a1 = len
    words += load_imm64(8, SYS_P47_PIPE_READ)
    words.append(SVC0)
    words.append(0x8B000000 | (0 << 16) | (19 << 5) | 19)   # add x19, x19, x0
    words += load_imm64(22, P47_MSG_LEN)
    words.append(0xEB000000 | (22 << 16) | (19 << 5) | 31)  # cmp x19, x22
    branch_idx = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)               # b.lt placeholder
    rel = loop_idx - branch_idx
    words[branch_idx] = 0x54000000 | ((rel & 0x7FFFF) << 5) | 0xB
    syscall(words, SYS_P47_REPORT, x0=P47_CHK_PIPE, x1=P47_RECV_VA, x2=P47_MSG_LEN)
    syscall(words, SYS_P47_EXIT, x0=P47_READER_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    data_seg = bytearray(0x40)
    return assemble_elf(P47R_TEXT_VA, P47_RECV_VA, code, bytes(data_seg),
                        data_va_override=P47_RECV_VA, no_data_seg=True)

# ---- Phase-48 ABI (must match kmain.ad constants) ----------------------
# The on-disk ELFs the three forked children execve. PRODP48 writes the kernel-seeded
# source into ring A; FILTP48 reads ring A one byte at a time, XORs it with 0x5A, and
# writes ring B (blocking on BOTH rings); CONSP48 reads ring B until it has the whole
# transformed message, then reports it for the kernel's byte-for-byte check.
SYS_P48_FORK    = 790
SYS_P48_EXEC    = 791
SYS_P48_READ_A  = 792
SYS_P48_WRITE_A = 793
SYS_P48_READ_B  = 794
SYS_P48_WRITE_B = 795
SYS_P48_REPORT  = 796
SYS_P48_WAIT    = 797
SYS_P48_EXIT    = 798
P48_CHK_PIPE    = 0
P48_PROD_EXIT   = 0x61   # 97  — producer's exit status (kernel cross-checks it)
P48_FILT_EXIT   = 0x62   # 98  — filter's exit status
P48_CONS_EXIT   = 0x63   # 99  — consumer's exit status
P48_MSG_LEN     = 40
P48_XOR_KEY     = 0x5A
# Each exec'd image's text load VA + its data VA (match the kmain.ad P48*_*_VA globals).
P48P_TEXT_VA = 0x4A400000      # producer text
P48F_TEXT_VA = 0x4AA00000      # filter text
P48C_TEXT_VA = 0x4B400000      # consumer text
P48_PROD_VA  = 0x4A800000      # producer's kernel-seeded source message
P48_FILT_VA  = 0x4AE00000      # filter's 1-byte scratch
P48_RECV_VA  = 0x4B800000      # consumer's reassembled transformed bytes

# AArch64 byte load/store + register EOR encoders (32-bit forms).
def ldrb_imm0(rt, rn):  return 0x39400000 | (rn << 5) | rt   # ldrb wRt, [xRn]
def strb_imm0(rt, rn):  return 0x39000000 | (rn << 5) | rt   # strb wRt, [xRn]
def eor_reg(rd, rn, rm): return 0x4A000000 | (rm << 16) | (rn << 5) | rd  # eor wRd, wRn, wRm

# ---- assemble PRODP48.ELF (producer): write the message into ring A in SMALL chunks ----
# Loop write_A(PROD_VA + total, CHUNK) accumulating the returned count into x19 until
# x19 == MSG_LEN. Writing in chunks SMALLER than the filter's per-batch appetite means the
# filter often drains ring A and loops back to read_A before the producer has been
# rescheduled to refill it, so the filter deterministically BLOCKS on an EMPTY ring A. Ring A
# is also small (CAP < MSG_LEN), so the producer still BLOCKS on a FULL ring A when the filter
# lags. Then exit(PROD_EXIT).
P48_PROD_CHUNK = 8    # small chunks: keep ring A frequently drained to empty
def build_prodp48():
    words = []
    words += load_imm64(19, 0)                              # x19 = total sent
    # ---- write_A(PROD_VA + total, CHUNK) until x19 == MSG_LEN ----
    loop_idx = len(words)
    words += load_imm64(20, P48_PROD_VA)
    words.append(0x8B000000 | (19 << 16) | (20 << 5) | 0)   # add x0, x20, x19  (src) -- a0
    words += load_imm64(1, P48_PROD_CHUNK)                  # x1 = CHUNK (small) -- a1
    words += load_imm64(8, SYS_P48_WRITE_A)
    words.append(SVC0)
    words.append(0x8B000000 | (0 << 16) | (19 << 5) | 19)   # add x19, x19, x0
    words += load_imm64(22, P48_MSG_LEN)
    words.append(0xEB000000 | (22 << 16) | (19 << 5) | 31)  # cmp x19, x22
    branch_idx = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)               # b.lt placeholder
    rel = loop_idx - branch_idx
    words[branch_idx] = 0x54000000 | ((rel & 0x7FFFF) << 5) | 0xB
    syscall(words, SYS_P48_EXIT, x0=P48_PROD_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    return assemble_elf(P48P_TEXT_VA, P48_PROD_VA, code, b"",
                        data_va_override=P48_PROD_VA, no_data_seg=True)

# ---- assemble FILTP48.ELF (filter): read A in chunks -> XOR -> BULK write B ----
# The filter assembles a BATCH (up to BATCH bytes, > ring-B capacity) by reading ring A in
# small READ_CHUNK-sized reads -- so whenever it drains ring A faster than the producer
# refills it, the next read_A finds ring A EMPTY and the filter BLOCKS on it. It then XOR-
# transforms the whole batch and BULK-writes it to ring B; because the batch is LARGER than
# ring B's (smaller) capacity, the write cannot fit in one go and the filter BLOCKS on a FULL
# ring B until the consumer drains it. Thus a single run genuinely blocks on BOTH rings in
# BOTH directions, structurally (not by scheduler luck).
#   x19 = total processed, x23 = XOR key, x24 = scratch base (FILT_VA), x25 = batch got.
P48_FILT_BATCH      = 16   # bytes accumulated before each bulk write_B (> ring-B capacity)
P48_FILT_READ_CHUNK = 8    # per-read_A chunk: small, so ring A frequently drains to empty
def build_filtp48():
    words = []
    words += load_imm64(19, 0)                              # x19 = total processed
    words += load_imm64(23, P48_XOR_KEY)                    # x23 = key
    words += load_imm64(24, P48_FILT_VA)                    # x24 = scratch base
    outer_idx = len(words)
    # ---- accumulate a BATCH into scratch via small chunked read_A's. x25 = got so far. ----
    # want = min(BATCH, MSG_LEN - x19); read in READ_CHUNK-sized reads until x25 == want.
    words += load_imm64(25, 0)                              # x25 = got in this batch
    words += load_imm64(30, P48_FILT_BATCH)                 # x30 = want (BATCH)
    words += load_imm64(21, P48_MSG_LEN)
    words.append(0xCB000000 | (19 << 16) | (21 << 5) | 9)   # sub x9, x21, x19  (remaining)
    words.append(0xEB000000 | (9 << 16) | (30 << 5) | 31)   # cmp x30, x9   (subs xzr, x30, x9)
    # if want(x30) <= remaining(x9) keep BATCH, else clamp want = remaining
    clamp_branch = len(words)
    words.append(0x54000000 | (0 << 5) | 0xD)               # b.le skip_clamp (placeholder)
    words.append(0x8B000000 | (31 << 16) | (9 << 5) | 30)   # mov x30, x9  (want = remaining)
    words[clamp_branch] = 0x54000000 | (((len(words) - clamp_branch) & 0x7FFFF) << 5) | 0xD
    rd_idx = len(words)
    # buf = scratch + x25 ; len = min(READ_CHUNK, want - x25)
    words.append(0x8B000000 | (25 << 16) | (24 << 5) | 0)   # add x0, x24, x25  (buf)
    words.append(0xCB000000 | (25 << 16) | (30 << 5) | 1)   # sub x1, x30, x25  (want - got)
    words += load_imm64(10, P48_FILT_READ_CHUNK)
    words.append(0xEB000000 | (10 << 16) | (1 << 5) | 31)   # cmp x1, x10  (subs xzr, x1, x10)
    chunk_branch = len(words)
    words.append(0x54000000 | (0 << 5) | 0xD)               # b.le keep_len (placeholder)
    words.append(0x8B000000 | (31 << 16) | (10 << 5) | 1)   # mov x1, x10  (len = READ_CHUNK)
    words[chunk_branch] = 0x54000000 | (((len(words) - chunk_branch) & 0x7FFFF) << 5) | 0xD
    words += load_imm64(8, SYS_P48_READ_A)
    words.append(SVC0)
    # x25 += x0  (x0 may be 0 on a bare wake -> loop re-reads)
    words.append(0x8B000000 | (0 << 16) | (25 << 5) | 25)   # add x25, x25, x0
    words.append(0xEB000000 | (30 << 16) | (25 << 5) | 31)  # cmp x25, x30  (subs xzr, x25, x30)
    rd_branch = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)               # b.lt rd_idx (placeholder)
    rd_rel = rd_idx - rd_branch
    words[rd_branch] = 0x54000000 | ((rd_rel & 0x7FFFF) << 5) | 0xB
    # ---- transform the batch in place: for j in 0..got: scratch[j] ^= key ----
    words += load_imm64(26, 0)                              # x26 = j
    xform_idx = len(words)
    words.append(0x8B000000 | (26 << 16) | (24 << 5) | 27)  # add x27, x24, x26  (&scratch[j])
    words.append(ldrb_imm0(21, 27))                         # ldrb w21, [x27]
    words.append(eor_reg(21, 21, 23))                       # eor  w21, w21, w23
    words.append(strb_imm0(21, 27))                         # strb w21, [x27]
    words += load_imm64(22, 1)
    words.append(0x8B000000 | (22 << 16) | (26 << 5) | 26)  # add x26, x26, 1
    words.append(0xEB000000 | (25 << 16) | (26 << 5) | 31)  # cmp x26, x25
    xform_branch = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)               # b.lt xform_idx (placeholder)
    xform_rel = xform_idx - xform_branch
    words[xform_branch] = 0x54000000 | ((xform_rel & 0x7FFFF) << 5) | 0xB
    # ---- write_B drain: x28 = pushed_in_batch; loop write_B(scratch+pushed, got-pushed) ----
    words += load_imm64(28, 0)                              # x28 = pushed in this batch
    wr_idx = len(words)
    words.append(0x8B000000 | (28 << 16) | (24 << 5) | 0)   # add x0, x24, x28  (src)
    words.append(0xCB000000 | (28 << 16) | (25 << 5) | 1)   # sub x1, x25, x28  (len)
    words += load_imm64(8, SYS_P48_WRITE_B)
    words.append(SVC0)
    words.append(0x8B000000 | (0 << 16) | (28 << 5) | 28)   # add x28, x28, x0  (x0 may be 0 on wake)
    words.append(0xEB000000 | (25 << 16) | (28 << 5) | 31)  # cmp x28, x25
    wr_branch = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)               # b.lt wr_idx (placeholder)
    wr_rel = wr_idx - wr_branch
    words[wr_branch] = 0x54000000 | ((wr_rel & 0x7FFFF) << 5) | 0xB
    # ---- x19 += got ; cmp x19, MSG_LEN ; b.lt outer ----
    words.append(0x8B000000 | (25 << 16) | (19 << 5) | 19)  # add x19, x19, x25
    words += load_imm64(22, P48_MSG_LEN)
    words.append(0xEB000000 | (22 << 16) | (19 << 5) | 31)  # cmp x19, x22
    branch_idx = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)               # b.lt outer (placeholder)
    rel = outer_idx - branch_idx
    words[branch_idx] = 0x54000000 | ((rel & 0x7FFFF) << 5) | 0xB
    syscall(words, SYS_P48_EXIT, x0=P48_FILT_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    return assemble_elf(P48F_TEXT_VA, P48_FILT_VA, code, b"",
                        data_va_override=P48_FILT_VA, no_data_seg=True)

# ---- assemble CONSP48.ELF (consumer): read the transformed stream off ring B ----
# Loop read_B(RECV_VA + total, CHUNK) in SMALL fixed-size chunks, accumulating the returned
# count into x19 until x19 == MSG_LEN. The first read BLOCKS on the empty ring B. Reading in
# small chunks deliberately drains ring B SLOWLY so it stays near-full while the filter bulk-
# writes, which deterministically forces the filter to BLOCK on a FULL ring B (the consumer's
# next small read then drains + wakes it). Then report(CHK_PIPE, RECV_VA, MSG_LEN) so the
# kernel cross-checks XOR(producer message), and exit(CONS_EXIT).
P48_CONS_CHUNK = 4
def build_consp48():
    words = []
    words += load_imm64(19, 0)                              # x19 = total received
    loop_idx = len(words)
    words += load_imm64(20, P48_RECV_VA)
    words.append(0x8B000000 | (19 << 16) | (20 << 5) | 0)   # add x0, x20, x19  (dst) -- a0
    words += load_imm64(1, P48_CONS_CHUNK)                  # x1 = CHUNK (small) -- a1
    words += load_imm64(8, SYS_P48_READ_B)
    words.append(SVC0)
    words.append(0x8B000000 | (0 << 16) | (19 << 5) | 19)   # add x19, x19, x0
    words += load_imm64(22, P48_MSG_LEN)
    words.append(0xEB000000 | (22 << 16) | (19 << 5) | 31)  # cmp x19, x22
    branch_idx = len(words)
    words.append(0x54000000 | (0 << 5) | 0xB)               # b.lt placeholder
    rel = loop_idx - branch_idx
    words[branch_idx] = 0x54000000 | ((rel & 0x7FFFF) << 5) | 0xB
    syscall(words, SYS_P48_REPORT, x0=P48_CHK_PIPE, x1=P48_RECV_VA, x2=P48_MSG_LEN)
    syscall(words, SYS_P48_EXIT, x0=P48_CONS_EXIT)
    code = b"".join(struct.pack("<I", w) for w in words)
    return assemble_elf(P48C_TEXT_VA, P48_RECV_VA, code, b"",
                        data_va_override=P48_RECV_VA, no_data_seg=True)

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
CHILDB46_ELF = build_childb46()
WRITP47_ELF  = build_writp47()
READP47_ELF  = build_readp47()
PRODP48_ELF  = build_prodp48()
FILTP48_ELF  = build_filtp48()
CONSP48_ELF  = build_consp48()

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
childb46_clusters = write_clusters(writer43_clusters[-1] + 1, CHILDB46_ELF)
writp47_clusters = write_clusters(childb46_clusters[-1] + 1, WRITP47_ELF)
readp47_clusters = write_clusters(writp47_clusters[-1] + 1, READP47_ELF)
prodp48_clusters = write_clusters(readp47_clusters[-1] + 1, PRODP48_ELF)
filtp48_clusters = write_clusters(prodp48_clusters[-1] + 1, FILTP48_ELF)
consp48_clusters = write_clusters(filtp48_clusters[-1] + 1, CONSP48_ELF)

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
    chain(childb46_clusters)
    chain(writp47_clusters)
    chain(readp47_clusters)
    chain(prodp48_clusters)
    chain(filtp48_clusters)
    chain(consp48_clusters)
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
    (b"CHILDB46ELF", childb46_clusters[0], len(CHILDB46_ELF)),
    (b"WRITP47 ELF", writp47_clusters[0], len(WRITP47_ELF)),
    (b"READP47 ELF", readp47_clusters[0], len(READP47_ELF)),
    (b"PRODP48 ELF", prodp48_clusters[0], len(PRODP48_ELF)),
    (b"FILTP48 ELF", filtp48_clusters[0], len(FILTP48_ELF)),
    (b"CONSP48 ELF", consp48_clusters[0], len(CONSP48_ELF)),
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
assert CHILDB46_ELF[:4] == b"\x7fELF", "CHILDB46.ELF is not a valid ELF"
assert WRITP47_ELF[:4] == b"\x7fELF", "WRITP47.ELF is not a valid ELF"
assert READP47_ELF[:4] == b"\x7fELF", "READP47.ELF is not a valid ELF"
assert PRODP48_ELF[:4] == b"\x7fELF", "PRODP48.ELF is not a valid ELF"
assert FILTP48_ELF[:4] == b"\x7fELF", "FILTP48.ELF is not a valid ELF"
assert CONSP48_ELF[:4] == b"\x7fELF", "CONSP48.ELF is not a valid ELF"
# The Phase-48 child-image data clusters must not overrun the Phase-42 file extent at
# LBA 3072 (consp48 is the last cluster allocated).
consp48_last_lba = data_lba + (consp48_clusters[-1] - 2 + 1) * SPC
assert consp48_last_lba <= P42_FILE_LBA, \
    "phase-48 child clusters (last LBA %d) overrun the phase-42 file extent at %d" % (consp48_last_lba, P42_FILE_LBA)
print("[fat16-builder] READER43=%s WRITER43=%s CHILDB46=%s" % (reader43_clusters, writer43_clusters, childb46_clusters))
print("[fat16-builder] WRITP47=%s READP47=%s" % (writp47_clusters, readp47_clusters))
print("[fat16-builder] PRODP48=%s FILTP48=%s CONSP48=%s" % (prodp48_clusters, filtp48_clusters, consp48_clusters))
print("[fat16-builder] phase48 disk built; data_lba=%d file_lba=%d consp48_last_lba=%d" % (data_lba, P42_FILE_LBA, consp48_last_lba))
PYEOF

[ -s "$DISK" ] || fail "FAT16 disk image was not created"

cp -f "$DISK" "$SCRATCH" || fail "could not create writable scratch disk"
[ -s "$SCRATCH" ] || fail "writable scratch disk was not created"

# --- boot under qemu-system-aarch64: WRITABLE virtio-blk + virtio-net ---
#     The SAME machine/flags + virtio-blk disk backing prior phases. The kernel
#     halts in a WFI loop at the Phase-42 verdict, so QEMU never exits on its own;
#     the timeout (and a 124 rc) is expected and fine as long as every PASS banner
#     below is present.
timeout 600 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -m 256M -nographic -no-reboot \
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
    echo "[test_arm64_phase48] captured serial (tail):"
    tail -200 "$SERIAL" | sed 's/^/[test_arm64_phase48]   | /'
}

# --- guard against explicit failure markers / panics -------------------
for ph in 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48; do
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
if grep -q -F "EL0 unknown syscall (phase 44)" "$SERIAL"; then
    dump_serial
    fail "a Phase-44 task issued an unknown syscall"
fi
if grep -q -F "EL0 unknown syscall (phase 45)" "$SERIAL"; then
    dump_serial
    fail "a Phase-45 task issued an unknown syscall"
fi
if grep -q -F "EL0 unknown syscall (phase 46)" "$SERIAL"; then
    dump_serial
    fail "a Phase-46 task issued an unknown syscall"
fi
if grep -q -F "EL0 unknown syscall (phase 47)" "$SERIAL"; then
    dump_serial
    fail "a Phase-47 task issued an unknown syscall"
fi
if grep -q -F "EL0 unknown syscall (phase 48)" "$SERIAL"; then
    dump_serial
    fail "a Phase-48 task issued an unknown syscall"
fi
if grep -q -F "Phase 44 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-44 reported FAIL"
fi
if grep -q -F "Phase 45 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-45 reported FAIL"
fi
if grep -q -F "Phase 46 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-46 reported FAIL"
fi
if grep -q -F "Phase 47 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-47 reported FAIL"
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
# Phase 43 PASS is now a REGRESSION guard (Phase 44 chains off it).
grep -q -F "$P43_PASS"   "$SERIAL" || { dump_serial; fail "Phase-43 blocking pipe IPC regressed (Phase 44 not reached)"; }

# --- Phase 44 assertions ----------------------------------------------
grep -q -F "$PHASE44"    "$SERIAL" || { dump_serial; fail "Phase-44 signal-delivery demo did not start"; }
grep -q -F "$LAUNCH44"   "$SERIAL" || { dump_serial; fail "Phase-44 EL0 signal task never launched"; }
# CORE proof 1: the timer DELIVERED a signal to the RUNNING task (pushed a real frame
# on its EL0 stack while its PC was mid-loop).
grep -q -F "$DELIVER44"  "$SERIAL" || { dump_serial; fail "Phase-44 never delivered a signal to the running EL0 task"; }
# CORE proof 2: the EL0 handler genuinely ran (with the right signal number).
grep -q -F "$HANDLER44"  "$SERIAL" || { dump_serial; fail "Phase-44 EL0 signal handler never ran"; }
# CORE proof 3: sigreturn restored the interrupted frame off the EL0 stack.
grep -q -F "$SIGRET44"   "$SERIAL" || { dump_serial; fail "Phase-44 sigreturn never restored the interrupted frame"; }
# CORE proof 4: the resumed loop produced + reported a value (kernel cross-checks it).
grep -q -F "$RESULT44"   "$SERIAL" || { dump_serial; fail "Phase-44 resumed loop never reported its final value"; }
grep -q -F "$SUMMARY44"  "$SERIAL" || { dump_serial; fail "Phase-44 summary line not emitted"; }
# Phase 44 PASS is now a REGRESSION guard (Phase 45 chains off it).
grep -q -F "$P44_PASS"   "$SERIAL" || { dump_serial; fail "Phase-44 signal delivery + sigreturn regressed (Phase 45 not reached)"; }

# --- Phase 45 assertions ----------------------------------------------
grep -q -F "$PHASE45"    "$SERIAL" || { dump_serial; fail "Phase-45 cross-task signal-delivery demo did not start"; }
grep -q -F "$LAUNCH45"   "$SERIAL" || { dump_serial; fail "Phase-45 signaller + target EL0 tasks never launched"; }
# CORE proof 1: task A's kill QUEUED the signal as PENDING on task B (cross-task, not a
# synchronous self-signal). The kernel records queued_by=A / queued_target=B.
grep -q -F "$KILL45"     "$SERIAL" || { dump_serial; fail "Phase-45 task A never QUEUED a pending signal via kill"; }
# CORE proof 2: the kernel DELIVERED the queued signal to the RUNNING task B on its
# return-to-EL0 (pushed a real frame on B's OWN EL0 stack while B's PC was mid-loop).
grep -q -F "$DELIVER45"  "$SERIAL" || { dump_serial; fail "Phase-45 never delivered the queued signal to the running target task B"; }
# CORE proof 3: task B's EL0 handler genuinely ran (with the right signal number).
grep -q -F "$HANDLER45"  "$SERIAL" || { dump_serial; fail "Phase-45 target task B's EL0 signal handler never ran"; }
# CORE proof 4: sigreturn restored B's interrupted frame off B's EL0 stack.
grep -q -F "$SIGRET45"   "$SERIAL" || { dump_serial; fail "Phase-45 sigreturn never restored B's interrupted frame"; }
# CORE proof 5: B's resumed loop produced + reported a value (kernel cross-checks it).
grep -q -F "$RESULT45"   "$SERIAL" || { dump_serial; fail "Phase-45 target task B's resumed loop never reported its final value"; }
grep -q -F "$SUMMARY45"  "$SERIAL" || { dump_serial; fail "Phase-45 summary line not emitted"; }
# Phase 45 PASS is now a REGRESSION guard (Phase 46 chains off it).
grep -q -F "$P45_PASS"   "$SERIAL" || { dump_serial; fail "Phase-45 cross-task signal delivery regressed (Phase 46 not reached)"; }

# --- Phase 46 assertions ----------------------------------------------
# CORE proof of a real EL0 fork+exec+wait process lifecycle. Every verdict
# is computed from actual observations the kernel emitted; no placeholders.
grep -q -F "$PHASE46"      "$SERIAL" || { dump_serial; fail "Phase-46 process-lifecycle demo did not start"; }
grep -q -F "$LAUNCH46"     "$SERIAL" || { dump_serial; fail "Phase-46 parent EL0 task never launched (under its own private ASID)"; }
# CORE proof 1: fork() created a GENUINELY DISTINCT child task with a fresh pid
# in its OWN private address space (separate L1 root + ASID + backing pages).
grep -q -F "$FORK46"       "$SERIAL" || { dump_serial; fail "Phase-46 fork() never created a distinct child task"; }
# CORE proof 2: the child execve()'d a DIFFERENT on-disk ELF (read off the live
# FAT16 virtio-blk volume) and the kernel replaced its image with the new entry.
grep -q -F "$EXEC46"       "$SERIAL" || { dump_serial; fail "Phase-46 child never execve'd the different on-disk CHILDB46.ELF"; }
# CORE proof 3: the freshly-loaded child image ran to completion, producing the
# kernel-verified expected accumulation sum.
grep -q -F "$CHILDRESULT46" "$SERIAL" || { dump_serial; fail "Phase-46 exec'd child never reported its kernel-verified accumulation sum"; }
# CORE proof 4: the parent's wait() GENUINELY BLOCKED (descheduled, state WAITING)
# on the not-yet-exited child.
grep -q -F "$BLOCK46"      "$SERIAL" || { dump_serial; fail "Phase-46 parent never blocked in wait() (it polled or the child had already exited?)"; }
# CORE proof 5: the child exit()'d, the kernel reaped it and WOKE the blocked
# parent, returning the child's exit status from wait().
grep -q -F "$WOKE46"       "$SERIAL" || { dump_serial; fail "Phase-46 child exit never reaped+woke the blocked parent"; }
# CORE proof 6: the parent observed the REAPED status (matching the child's
# actual exit status).
grep -q -F "$REAPED46"     "$SERIAL" || { dump_serial; fail "Phase-46 parent never reported the reaped child status"; }
grep -q -F "$SUMMARY46"    "$SERIAL" || { dump_serial; fail "Phase-46 summary line not emitted"; }
# Phase 46 PASS is now a REGRESSION guard (Phase 47 chains off it).
grep -q -F "$P46_PASS"     "$SERIAL" || { dump_serial; fail "Phase-46 fork+exec+wait lifecycle regressed (Phase 47 not reached)"; }

# --- Phase 47 assertions ----------------------------------------------
# CORE proof of a real EL0 shell pipeline: a parent forks TWO distinct children
# connected by a kernel pipe (writer | reader). Every verdict is computed from
# actual observations the kernel emitted; no placeholders.
grep -q -F "$PHASE47"      "$SERIAL" || { dump_serial; fail "Phase-47 shell-pipeline demo did not start"; }
grep -q -F "$LAUNCH47"     "$SERIAL" || { dump_serial; fail "Phase-47 parent EL0 task never launched (under its own private ASID)"; }
# CORE proof 1: the parent fork()'d TWO genuinely DISTINCT children, each with a
# fresh pid in its OWN private address space. Assert BOTH the writer pid (0x1f) and
# the reader pid (0x20) were created.
grep -q -F "$FORK47"       "$SERIAL" || { dump_serial; fail "Phase-47 fork() never created a distinct child task"; }
grep -q -F "${FORK47}0x000000000000001F)" "$SERIAL" || { dump_serial; fail "Phase-47 never forked the WRITER child (pid 0x1f)"; }
grep -q -F "${FORK47}0x0000000000000020)" "$SERIAL" || { dump_serial; fail "Phase-47 never forked the READER child (pid 0x20)"; }
# CORE proof 2: EACH child execve()'d a DIFFERENT on-disk ELF (read off the live
# FAT16 virtio-blk volume) into its OWN text, and the kernel replaced its image.
grep -q -F "$EXECW47"      "$SERIAL" || { dump_serial; fail "Phase-47 writer child never execve'd WRITP47.ELF off disk"; }
grep -q -F "$EXECR47"      "$SERIAL" || { dump_serial; fail "Phase-47 reader child never execve'd READP47.ELF off disk"; }
# CORE proof 3: the reader GENUINELY BLOCKED on the EMPTY pipe (descheduled into
# SLEEPING / parked) and was WOKEN by a write that delivered the queued bytes.
grep -q -F "$RBLOCK47"     "$SERIAL" || { dump_serial; fail "Phase-47 reader child never blocked on an empty pipe (it polled?)"; }
grep -q -F "$RWAKE47"      "$SERIAL" || { dump_serial; fail "Phase-47 blocked reader child was never woken by a write"; }
# CORE proof 4 (REVERSE): the small ring fills mid-message so the writer GENUINELY
# BLOCKS on the FULL ring until the reader's next pipe_read drains it + wakes it.
grep -q -F "$WBLOCK47"     "$SERIAL" || { dump_serial; fail "Phase-47 writer child never filled the ring (full-pipe block path not exercised)"; }
grep -q -F "$WWAKE47"      "$SERIAL" || { dump_serial; fail "Phase-47 blocked writer child was never woken by a drain"; }
# CORE proof 5: the reader reported the received bytes and the kernel cross-checked
# them byte-for-byte (match=1) — the full message round-tripped from W to R.
grep -q -F "$REPORT47"     "$SERIAL" || { dump_serial; fail "Phase-47 reader child never reported its received bytes"; }
grep -q -F "match=0x0000000000000001" "$SERIAL" || { dump_serial; fail "Phase-47 round-trip bytes did NOT match the kernel's known sequence"; }
# CORE proof 6: the parent's wait() GENUINELY BLOCKED (descheduled, WAITING) on the
# not-yet-exited children.
grep -q -F "$BLOCK47"      "$SERIAL" || { dump_serial; fail "Phase-47 parent never blocked in wait() (it polled or a child had already exited?)"; }
# CORE proof 7: each child exit()'d and the kernel reaped it, returning the child's exit
# status to the parent — for BOTH the writer (pid 0x1f, status 0x57) and the reader
# (pid 0x20, status 0x52). The writer exits FIRST while the parent is BLOCKED in wait(),
# so its reap WAKES the blocked parent. The reader exits while the parent (already woken)
# is RUNNABLE and re-entering wait() for the second child, so the kernel reaps it via the
# already-exited path. Both are genuine reaps that hand the parent the exact exit status.
grep -q -F "$WOKE47"       "$SERIAL" || { dump_serial; fail "Phase-47 a child exit never reaped+woke the blocked parent"; }
grep -q -F "${WOKE47}0x000000000000001F returns status=0x0000000000000057)" "$SERIAL" || { dump_serial; fail "Phase-47 writer child was never reaped (status 0x57) to wake the parent"; }
grep -q -F "${REAPED47}0x0000000000000020) reaped already-exited child; status=0x0000000000000052" "$SERIAL" || { dump_serial; fail "Phase-47 reader child was never reaped (status 0x52) by the parent"; }
grep -q -F "$SUMMARY47"    "$SERIAL" || { dump_serial; fail "Phase-47 summary line not emitted"; }
# Phase 47 PASS is now a REGRESSION guard (Phase 48 chains off it).
grep -q -F "$P47_PASS"     "$SERIAL" || { dump_serial; fail "Phase-47 shell pipeline regressed (Phase 48 not reached)"; }

# --- Phase 48 assertions ----------------------------------------------
# CORE proof of a real EL0 three-stage pipeline: a parent forks THREE distinct
# children connected by TWO kernel pipes (producer P | filter F | consumer C).
# The FILTER is the novel mechanism: ONE EL0 process that blocks on BOTH pipes
# in BOTH directions (read ring A on empty, write ring B on full) while
# XOR-transforming every byte. Every verdict is computed from real observations.
grep -q -F "$PHASE48"      "$SERIAL" || { dump_serial; fail "Phase-48 three-stage pipeline demo did not start"; }
grep -q -F "$LAUNCH48"     "$SERIAL" || { dump_serial; fail "Phase-48 parent EL0 task never launched (under its own private ASID)"; }
# CORE proof 1: the parent fork()'d THREE genuinely DISTINCT children, each with a
# fresh pid in its OWN private address space. Assert producer (0x41), filter (0x42)
# and consumer (0x43) pids were all created.
grep -q -F "$FORK48"       "$SERIAL" || { dump_serial; fail "Phase-48 fork() never created a distinct child task"; }
grep -q -F "${FORK48}0x0000000000000041)" "$SERIAL" || { dump_serial; fail "Phase-48 never forked the PRODUCER child (pid 0x41)"; }
grep -q -F "${FORK48}0x0000000000000042)" "$SERIAL" || { dump_serial; fail "Phase-48 never forked the FILTER child (pid 0x42)"; }
grep -q -F "${FORK48}0x0000000000000043)" "$SERIAL" || { dump_serial; fail "Phase-48 never forked the CONSUMER child (pid 0x43)"; }
# CORE proof 2: EACH child execve()'d a DIFFERENT on-disk ELF (read off the live
# FAT16 virtio-blk volume) into its OWN text, and the kernel replaced its image.
grep -q -F "$EXECP48"      "$SERIAL" || { dump_serial; fail "Phase-48 producer child never execve'd PRODP48.ELF off disk"; }
grep -q -F "$EXECF48"      "$SERIAL" || { dump_serial; fail "Phase-48 filter child never execve'd FILTP48.ELF off disk"; }
grep -q -F "$EXECC48"      "$SERIAL" || { dump_serial; fail "Phase-48 consumer child never execve'd CONSP48.ELF off disk"; }
# CORE proof 3 (ring A): the producer GENUINELY BLOCKED on the FULL ring A and was
# WOKEN by the filter's read_A; AND the filter GENUINELY BLOCKED on the EMPTY ring A
# and was WOKEN by the producer's write_A. Both block+wake directions on pipe A.
grep -q -F "$PBLOCK48"     "$SERIAL" || { dump_serial; fail "Phase-48 producer never filled ring A (full-pipe block path not exercised)"; }
grep -q -F "$PWAKE48"      "$SERIAL" || { dump_serial; fail "Phase-48 blocked producer was never woken by a read_A drain"; }
grep -q -F "$FBLOCKA48"    "$SERIAL" || { dump_serial; fail "Phase-48 filter never blocked on an empty ring A (it polled?)"; }
grep -q -F "$FWAKEA48"     "$SERIAL" || { dump_serial; fail "Phase-48 blocked filter (empty A) was never woken by a write_A"; }
# CORE proof 4 (ring B): the filter GENUINELY BLOCKED on the FULL ring B and was
# WOKEN by the consumer's read_B; AND the consumer GENUINELY BLOCKED on the EMPTY
# ring B and was WOKEN by the filter's write_B. Both block+wake directions on pipe B.
grep -q -F "$FBLOCKB48"    "$SERIAL" || { dump_serial; fail "Phase-48 filter never filled ring B (full-pipe block path not exercised)"; }
grep -q -F "$FWAKEB48"     "$SERIAL" || { dump_serial; fail "Phase-48 blocked filter (full B) was never woken by a read_B drain"; }
grep -q -F "$CBLOCK48"     "$SERIAL" || { dump_serial; fail "Phase-48 consumer never blocked on an empty ring B (it polled?)"; }
grep -q -F "$CWAKE48"      "$SERIAL" || { dump_serial; fail "Phase-48 blocked consumer (empty B) was never woken by a write_B"; }
# CORE proof 5: the consumer reported the transformed bytes and the kernel
# cross-checked them byte-for-byte (match=1) — consumer bytes == XOR(producer msg).
grep -q -F "$REPORT48"     "$SERIAL" || { dump_serial; fail "Phase-48 consumer child never reported its received bytes"; }
grep -q -F "match=0x0000000000000001" "$SERIAL" || { dump_serial; fail "Phase-48 transformed stream did NOT match XOR(producer message) byte-for-byte"; }
# CORE proof 6: the parent's wait() GENUINELY BLOCKED (descheduled, WAITING) on a
# not-yet-exited child.
grep -q -F "$BLOCK48"      "$SERIAL" || { dump_serial; fail "Phase-48 parent never blocked in wait() (it polled or a child had already exited?)"; }
# CORE proof 7: each child exit()'d and the kernel reaped it, returning the child's
# exit status to the parent — producer (0x61), filter (0x62), consumer (0x63). At
# least one reap WAKES the blocked parent.
grep -q -F "$WOKE48"       "$SERIAL" || { dump_serial; fail "Phase-48 a child exit never reaped+woke the blocked parent"; }
grep -q -F "status=0x0000000000000061" "$SERIAL" || { dump_serial; fail "Phase-48 producer child was never reaped (status 0x61)"; }
grep -q -F "status=0x0000000000000062" "$SERIAL" || { dump_serial; fail "Phase-48 filter child was never reaped (status 0x62)"; }
grep -q -F "status=0x0000000000000063" "$SERIAL" || { dump_serial; fail "Phase-48 consumer child was never reaped (status 0x63)"; }
grep -q -F "$SUMMARY48"    "$SERIAL" || { dump_serial; fail "Phase-48 summary line not emitted"; }
grep -q -F "$P48_PASS"     "$SERIAL" || { dump_serial; fail "'$P48_PASS' not found (Phase 48 three-stage pipeline did not verify)"; }

echo "[test_arm64_phase48] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] phase 43 OK (regr)    : $(grep -F "$P43_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] phase 44 OK (regr)    : $(grep -F "$P44_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] phase 45 OK (regr)    : $(grep -F "$P45_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] phase 46 PASS (regr)  : $(grep -F "$P46_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] phase 47 PASS (regr)  : $(grep -F "$P47_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] phase 48 start        : $(grep -F "$PHASE48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] parent launch         : $(grep -F "$LAUNCH48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] fork -> producer pid   : $(grep -F "${FORK48}0x0000000000000041)" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] fork -> filter pid     : $(grep -F "${FORK48}0x0000000000000042)" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] fork -> consumer pid   : $(grep -F "${FORK48}0x0000000000000043)" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] producer execve'd ELF : $(grep -F "$EXECP48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] filter execve'd ELF   : $(grep -F "$EXECF48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] consumer execve'd ELF : $(grep -F "$EXECC48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] producer blocked (A)  : $(grep -F "$PBLOCK48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] filter woke producer  : $(grep -F "$PWAKE48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] filter blocked (A emp): $(grep -F "$FBLOCKA48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] producer woke filter  : $(grep -F "$FWAKEA48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] filter blocked (B ful): $(grep -F "$FBLOCKB48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] consumer woke filter  : $(grep -F "$FWAKEB48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] consumer blocked (B)  : $(grep -F "$CBLOCK48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] filter woke consumer  : $(grep -F "$CWAKE48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] consumer report(verif): $(grep -F "$REPORT48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] parent blocked wait   : $(grep -F "$BLOCK48" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] reaped -> woke parent  :"
grep -F "$WOKE48" "$SERIAL" | sed 's/^/[test_arm64_phase48]   | /'
echo "[test_arm64_phase48] summary               :"
grep -F "$SUMMARY48" "$SERIAL" | sed 's/^/[test_arm64_phase48]   | /'
echo "[test_arm64_phase48] phase 48 PASS line    : $(grep -F "$P48_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase48] (qemu rc=$RC; a 124/139/143 teardown with all PASS banners is acceptable)"
echo "[test_arm64_phase48] PASS"
