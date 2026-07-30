#!/usr/bin/env bash
# scripts/test_arm64_pagefault.sh — PHASE 6 multi-arch milestone: the aarch64
# kernel spine catches an EL0 (userspace) page fault, reports the faulting
# address from FAR_EL1, and TERMINATES the offending task instead of hanging —
# all driven from Adder.
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
# Builds on Phase 4 (EL0 + svc) and Phase 5 (preemptive scheduling). After the
# Phase-4 single-task EL0 demo exits cleanly ("[arm64] EL0 syscall OK"), kmain
# proceeds to Phase 6:
#   1. Hand-emits a deliberately-faulting EL0 routine: it loads x1 with an
#      EL1-only RAM VA (0x40400000, a 2 MiB L2 block mapped WITHOUT AP[1]) and
#      executes `ldr x0, [x1]`. From EL0 that load is a permission fault.
#   2. ERETs into it at EL0t. The load raises a Data Abort, taken to the
#      "Lower EL using AArch64" Synchronous vector (the same 0x400 vector as
#      svc). arm64_sync_handler reads ESR_EL1.EC, sees 0x24 (Data Abort from a
#      lower EL), and routes to arm64_handle_el0_fault.
#   3. The handler reads FAR_EL1 (faulting VA) + ELR_EL1 (EL0 PC) + ESR_EL1,
#      prints them in hex, marks the fault handled, and reaps the task by NOT
#      ERET-ing back into the faulting instruction. It then hands off to Phase 5
#      (preemptive scheduling), proving the kernel survived and kept running.
#
# A PASS proves: (a) a wild EL0 memory access is trapped (not silently ignored
# or hung); (b) the kernel reports the exact faulting VA via FAR_EL1 — and that
# VA is the sentinel 0x40400000 we deliberately touched; (c) the kernel does NOT
# wedge — it continues into Phase 5 and round-robins two EL0 tasks afterwards.
# This is the aarch64 analogue of delivering SIGSEGV and reaping the process,
# with the fault policy written in pure Adder.
#
# Prints "[test_arm64_pagefault] PASS" on success or "[test_arm64_pagefault] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
EL0_OK="[arm64] EL0 syscall OK"
LAUNCH_FAULT="[arm64] launching faulting EL0 task"
DABORT="[arm64] EL0 data abort"
# FAR_EL1 must report the exact sentinel VA we deliberately dereferenced.
FAR_LINE="[arm64] fault VA (FAR_EL1)=0x0000000040400000"
TERM="[arm64] EL0 task terminated; kernel survived"
PASS_MARK="[arm64] EL0 page-fault OK"
# The kernel must keep running afterwards: Phase 5 launches and round-robins.
SCHED_PASS="[arm64] EL0 preempt sched OK"

fail() {
    echo "[test_arm64_pagefault] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_pagefault] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_pagefault] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_pagefault_test"
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
# After catching the fault the kernel proceeds to Phase 5, which masks IRQs and
# spins in WFI after its own PASS, so QEMU keeps running until the timeout kills
# it (exit 124). All assertions run on the serial log. This test uses no
# virtio-blk and is load-independent, safe under concurrency.
timeout 30 "$QEMU" \
    -M virt -cpu cortex-a72 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_pagefault] captured serial:"
    sed 's/^/[test_arm64_pagefault]   | /' "$SERIAL"
}

grep -q "$BANNER"          "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$EL0_OK"       "$SERIAL" || { dump_serial; fail "Phase-4 EL0 syscall stage did not complete"; }
grep -q -F "$LAUNCH_FAULT" "$SERIAL" || { dump_serial; fail "faulting-task launch marker not found"; }
grep -q -F "$DABORT"       "$SERIAL" || { dump_serial; fail "EL0 data abort was not caught"; }
grep -q -F "$FAR_LINE"     "$SERIAL" || { dump_serial; fail "FAR_EL1 did not report the sentinel fault VA 0x40400000"; }
grep -q -F "$TERM"         "$SERIAL" || { dump_serial; fail "task-termination marker not found"; }
grep -q -F "$PASS_MARK"    "$SERIAL" || { dump_serial; fail "'$PASS_MARK' not found"; }
# Crucial survival proof: the kernel kept running and reached Phase 5.
grep -q -F "$SCHED_PASS"   "$SERIAL" || { dump_serial; fail "kernel did not survive to Phase 5 after the fault"; }

echo "[test_arm64_pagefault] boot banner    : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_pagefault] data abort      : $(grep -F "$DABORT" "$SERIAL" | head -1)"
echo "[test_arm64_pagefault] FAR_EL1         : $(grep -F "$FAR_LINE" "$SERIAL" | head -1)"
echo "[test_arm64_pagefault] fault PC line    : $(grep -F "[arm64] fault PC (ELR_EL1)=" "$SERIAL" | head -1)"
echo "[test_arm64_pagefault] terminated       : $(grep -F "$TERM" "$SERIAL" | head -1)"
echo "[test_arm64_pagefault] page-fault marker: $(grep -F "$PASS_MARK" "$SERIAL" | head -1)"
echo "[test_arm64_pagefault] survived to sched: $(grep -F "$SCHED_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_pagefault] PASS"
