#!/usr/bin/env bash
# scripts/test_arm64_syscalls.sh — PHASE 8 multi-arch milestone: a BROADER EL0
# SYSCALL SURFACE dispatched by syscall number (x8) on bare-metal aarch64,
# driven from Adder.
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
# Builds on Phase 4 (EL0 + svc write/exit), Phase 5 (preemptive scheduling),
# Phase 6 (EL0 page-fault reaping) and Phase 7 (per-task TTBR0 isolation). After
# Phase 5 prints its PASS marker ("[arm64] EL0 preempt sched OK"), kmain hands off
# to Phase 8: a single EL0 task issues a sequence of syscalls mirroring the Linux
# aarch64 ABI (number in x8, args x0..x5, return in x0):
#   getpid()              -> the kernel-assigned PID (42 = 0x2A)
#   gettid()              -> the TID (== PID for our single thread)
#   sched_yield()         -> 0 (kernel acknowledges)
#   clock read (CNTVCT)x2 -> the virtual counter; the kernel latches the first
#                            value and confirms the second strictly advanced
#                            (live, monotonic time visible to EL0)
#   brk(0)                -> the current program break (query)
#   brk(BASE + 4 KiB)     -> moves the break, returns the new value (sbrk-style)
#   write(1, msg, len)    -> echoes a buffer to the UART, returns the length
#   exit(0)               -> records the code and halts the boot
#
# A PASS proves: (a) the svc dispatcher correctly demultiplexes MANY syscalls by
# x8 (not just write/exit); (b) each returns a correct, distinct result in x0;
# (c) the kernel observes monotonically advancing time (CNTVCT) read from EL0;
# (d) a brk/sbrk-style program break can be queried and moved; (e) the kernel
# stays alive through the whole sequence and halts cleanly on exit(0).
#
# Prints "[test_arm64_syscalls] PASS" on success or "[test_arm64_syscalls] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
SCHED_PASS="[arm64] EL0 preempt sched OK"
PHASE8="[arm64] Phase 8: broader EL0 syscall surface"
GETPID="[arm64] EL0 getpid -> 0x000000000000002A"
GETTID="[arm64] EL0 gettid -> 0x000000000000002A"
YIELD="[arm64] EL0 sched_yield serviced"
CLOCK1="[arm64] EL0 clock read #1 -> "
CLOCK_ADV="[arm64] EL0 clock advanced OK"
BRK_QUERY="[arm64] EL0 brk query -> 0x0000000040230000"
BRK_SET="[arm64] EL0 brk set -> 0x0000000040231000"
WRITE_OK="[arm64] EL0 write syscall serviced"
USERMSG="Hello from the EL0 syscall surface"
EXIT_OK="[arm64] EL0 exit syscall serviced"
SURFACE_OK="[arm64] EL0 syscall surface OK"

fail() {
    echo "[test_arm64_syscalls] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_syscalls] qemu-system-aarch64 not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y qemu-system-arm >/dev/null 2>&1 || true
    fi
    if command -v qemu-system-aarch64 >/dev/null 2>&1; then
        QEMU="qemu-system-aarch64"
    else
        fail "qemu-system-aarch64 not installed (apt install qemu-system-arm)"
    fi
fi

# --- check / install the aarch64 assembler+linker ----------------------
if ! command -v aarch64-linux-gnu-as >/dev/null 2>&1; then
    echo "[test_arm64_syscalls] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_syscalls_test"
mkdir -p "$WORK"
ELF="$WORK/hamnix-arm64.elf"
SERIAL="$WORK/serial.txt"
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
echo "$HDR" | grep -q "Entry point address: *0x40080000" || \
    fail "entry point is not QEMU virt's 0x40080000:
$HDR"

# --- boot under qemu-system-aarch64 ------------------------------------
# After Phase 8's exit(0) the kernel masks IRQs and spins in WFI, so QEMU keeps
# running until the timeout kills it (exit 124). All assertions run on the serial
# log. This test uses no virtio-blk and is load-independent, safe under concurrency.
timeout 30 "$QEMU" \
    -M virt -cpu cortex-a72 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_syscalls] captured serial:"
    sed 's/^/[test_arm64_syscalls]   | /' "$SERIAL"
}

grep -q "$BANNER"        "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$SCHED_PASS" "$SERIAL" || { dump_serial; fail "Phase-5 sched stage did not complete (Phase 8 not reached)"; }
grep -q -F "$PHASE8"     "$SERIAL" || { dump_serial; fail "Phase-8 syscall stage did not start"; }
grep -q -F "$GETPID"     "$SERIAL" || { dump_serial; fail "getpid did not return the assigned PID (0x2A)"; }
grep -q -F "$GETTID"     "$SERIAL" || { dump_serial; fail "gettid did not return the TID (0x2A)"; }
grep -q -F "$YIELD"      "$SERIAL" || { dump_serial; fail "sched_yield was not serviced"; }
grep -q -F "$CLOCK1"     "$SERIAL" || { dump_serial; fail "clock read #1 marker not found"; }
grep -q -F "$CLOCK_ADV"  "$SERIAL" || { dump_serial; fail "CNTVCT clock did not advance between reads"; }
grep -q -F "$BRK_QUERY"  "$SERIAL" || { dump_serial; fail "brk(0) did not return the initial break"; }
grep -q -F "$BRK_SET"    "$SERIAL" || { dump_serial; fail "brk(grow) did not move the break to BASE+4KiB"; }
grep -q -F "$WRITE_OK"   "$SERIAL" || { dump_serial; fail "write syscall was not serviced"; }
grep -q -F "$USERMSG"    "$SERIAL" || { dump_serial; fail "EL0 write() buffer was not echoed to the UART"; }
grep -q -F "$EXIT_OK"    "$SERIAL" || { dump_serial; fail "exit syscall was not serviced"; }
grep -q -F "$SURFACE_OK" "$SERIAL" || { dump_serial; fail "'$SURFACE_OK' not found (syscall surface did not complete cleanly)"; }

echo "[test_arm64_syscalls] boot banner   : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_syscalls] phase 8 start  : $(grep -F "$PHASE8" "$SERIAL" | head -1)"
echo "[test_arm64_syscalls] getpid         : $(grep -F "$GETPID" "$SERIAL" | head -1)"
echo "[test_arm64_syscalls] gettid         : $(grep -F "$GETTID" "$SERIAL" | head -1)"
echo "[test_arm64_syscalls] sched_yield    : $(grep -F "$YIELD" "$SERIAL" | head -1)"
echo "[test_arm64_syscalls] clock read #1  : $(grep -F "$CLOCK1" "$SERIAL" | head -1)"
echo "[test_arm64_syscalls] clock advanced : $(grep -F "$CLOCK_ADV" "$SERIAL" | head -1)"
echo "[test_arm64_syscalls] brk query      : $(grep -F "$BRK_QUERY" "$SERIAL" | head -1)"
echo "[test_arm64_syscalls] brk set        : $(grep -F "$BRK_SET" "$SERIAL" | head -1)"
echo "[test_arm64_syscalls] write echoed   : $(grep -F "$USERMSG" "$SERIAL" | head -1)"
echo "[test_arm64_syscalls] surface marker : $(grep -F "$SURFACE_OK" "$SERIAL" | head -1)"
echo "[test_arm64_syscalls] PASS"
