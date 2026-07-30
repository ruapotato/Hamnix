#!/usr/bin/env bash
# scripts/test_arm64_isolation.sh — PHASE 7 multi-arch milestone: per-task
# TTBR0_EL1 ADDRESS-SPACE ISOLATION on bare-metal aarch64, driven from Adder.
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
# Builds on Phase 4 (EL0 + svc), Phase 5 (preemptive scheduling) and Phase 6
# (EL0 page-fault reaping). After the Phase-6 fault demo reaps its faulting task
# ("[arm64] EL0 page-fault OK"), kmain proceeds to Phase 7:
#   1. Builds TWO independent level-1 translation tables (one per EL0 task).
#      Both map the SAME virtual address (0x4060_0000) but to DIFFERENT physical
#      pages: task A -> phys 0x4080_0000 (sentinel 0xAA), task B -> phys
#      0x40A0_0000 (sentinel 0xBB). Each table also clones the kernel identity
#      map + the EL0 code window, and lives in EL1-only RAM (EL0 can't tamper).
#   2. Points TTBR0_EL1 at task A's table (with tlbi vmalle1is + dsb + isb TLB
#      maintenance) and ERETs into an EL0 routine that does `ldrb w0,[shared_VA]`
#      then reports the byte via a kernel-private syscall (x8=512).
#   3. The kernel records A's value (0xAA), switches TTBR0_EL1 to task B's table
#      (again with full TLB maintenance), and ERETs into the SAME EL0 routine.
#      Task B reads the SAME virtual address and reports 0xBB.
#   4. The kernel verifies each task read its OWN sentinel at the shared VA and
#      that the two values differ — proving the same VA resolves to private
#      physical memory per task, i.e. tasks cannot see each other's memory.
#      It prints "[arm64] EL0 TTBR0 isolation OK", restores the kernel TTBR0,
#      and hands off to Phase 5 (preemptive scheduling) so that stays reachable.
#
# A PASS proves: (a) each EL0 task runs under its OWN TTBR0_EL1 translation
# root; (b) a load from one shared virtual address yields task-private physical
# data (A reads 0xAA, B reads 0xBB) — hard memory isolation; (c) the scheduler
# correctly switches TTBR0 + performs the mandatory TLB maintenance so no stale
# translation leaks across the switch; (d) the kernel keeps running afterwards
# (Phase 5 round-robins two EL0 tasks).
#
# Prints "[test_arm64_isolation] PASS" on success or "[test_arm64_isolation] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
PF_OK="[arm64] EL0 page-fault OK"
PHASE7="[arm64] Phase 7: per-task TTBR0 isolation"
ENTER_A="[arm64] iso entering task A (TTBR0=A)"
A_VAL="[arm64] iso task A read VA value=0x00000000000000AA"
SWITCH_B="[arm64] iso switching TTBR0 to task B"
B_VAL="[arm64] iso task B read VA value=0x00000000000000BB"
ISO_OK="[arm64] EL0 TTBR0 isolation OK"
# The kernel must keep running afterwards: Phase 5 launches and round-robins.
SCHED_PASS="[arm64] EL0 preempt sched OK"

fail() {
    echo "[test_arm64_isolation] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_isolation] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_isolation] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_isolation_test"
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
# After the isolation demo the kernel proceeds to Phase 5, which masks IRQs and
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
    echo "[test_arm64_isolation] captured serial:"
    sed 's/^/[test_arm64_isolation]   | /' "$SERIAL"
}

grep -q "$BANNER"        "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$PF_OK"      "$SERIAL" || { dump_serial; fail "Phase-6 page-fault stage did not complete"; }
grep -q -F "$PHASE7"     "$SERIAL" || { dump_serial; fail "Phase-7 isolation stage did not start"; }
grep -q -F "$ENTER_A"    "$SERIAL" || { dump_serial; fail "task A (TTBR0=A) was not entered"; }
grep -q -F "$A_VAL"      "$SERIAL" || { dump_serial; fail "task A did not read its own sentinel 0xAA at the shared VA"; }
grep -q -F "$SWITCH_B"   "$SERIAL" || { dump_serial; fail "TTBR0 switch to task B marker not found"; }
grep -q -F "$B_VAL"      "$SERIAL" || { dump_serial; fail "task B did not read its own sentinel 0xBB at the SAME shared VA"; }
grep -q -F "$ISO_OK"     "$SERIAL" || { dump_serial; fail "'$ISO_OK' not found (isolation did not hold)"; }
# Crucial survival proof: the kernel kept running and reached Phase 5.
grep -q -F "$SCHED_PASS" "$SERIAL" || { dump_serial; fail "kernel did not survive to Phase 5 after the isolation demo"; }

echo "[test_arm64_isolation] boot banner     : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_isolation] phase 7 start    : $(grep -F "$PHASE7" "$SERIAL" | head -1)"
echo "[test_arm64_isolation] task A (TTBR0=A)  : $(grep -F "$A_VAL" "$SERIAL" | head -1)"
echo "[test_arm64_isolation] TTBR0 switch      : $(grep -F "$SWITCH_B" "$SERIAL" | head -1)"
echo "[test_arm64_isolation] task B (TTBR0=B)  : $(grep -F "$B_VAL" "$SERIAL" | head -1)"
echo "[test_arm64_isolation] isolation marker  : $(grep -F "$ISO_OK" "$SERIAL" | head -1)"
echo "[test_arm64_isolation] survived to sched : $(grep -F "$SCHED_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_isolation] PASS"
