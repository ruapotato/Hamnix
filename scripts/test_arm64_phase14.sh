#!/usr/bin/env bash
# scripts/test_arm64_phase14.sh — PHASE 14 multi-arch milestone: DEMAND PAGING via
# a TRANSLATION-FAULT HANDLER on bare-metal aarch64.
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
# Builds on Phases 4-13 (EL0 + svc, preemptive scheduling, page-fault reaping,
# per-task TTBR0 isolation, broader syscall surface, page-table brk, SMP
# secondary bring-up, EL0 signal delivery, SMP scheduling under a spinlock, EL0
# FP/SIMD context save/restore). Phase 9 grew the heap, but only when EL0 EXPLICITLY
# asked via a brk syscall — the mapping was installed BEFORE the EL0 store ran.
# Phase 14 makes paging LAZY/first-touch: a region is left UNMAPPED and the page is
# materialised by the abort handler when the EL0 store itself faults, then the very
# faulting instruction is RESUMED so it completes transparently. The EL0 task never
# issues a "grow" syscall; it just touches unbacked memory and the kernel pages it
# in.
#
# After Phase 13 prints "[arm64] EL0 FP context switch OK", kmain hands off to
# Phase 14:
#   1. The demand window's L2 slot is forced UNMAPPED so the first EL0 store there
#      raises a TRANSLATION Data Abort.
#   2. The EL0 task stores a sentinel to P14_DEMAND_BASE (FAULTS), reads it back,
#      then stores a second sentinel to a DISTINCT page P14_DEMAND_BASE2 (a SECOND
#      first-touch fault) and reads that back.
#   3. The kernel's abort path classifies the fault via ESR_EL1.ISS.DFSC: a
#      TRANSLATION fault inside the demand window is paged in (a fresh physical page
#      is mapped into the live TTBR0 tables) and EL0 is RESUMED at the faulting
#      instruction. A PERMISSION fault (the Phase-6 EL1-only access) is still reaped
#      — the same handler does both, distinguished by DFSC.
#   4. The task reports both read-back values; the kernel verifies them AND that
#      each BACKING PHYSICAL page holds the sentinel, then prints the Phase-14 PASS.
#
# A PASS proves: (a) two first-touch translation faults were serviced by mapping a
# fresh page each and resuming EL0 (transparent demand paging); (b) the stores/loads
# through the demand-paged pages succeeded with the correct sentinels in the backing
# physical pages; (c) Phases 4-13 still run to completion (no regression — the
# Phase-9 brk, Phase-10 SMP, Phase-12 spinlock-scheduling, Phase-11 signal and
# Phase-13 FP markers all appear).
#
# Prints "[test_arm64_phase14] PASS" on success or "[test_arm64_phase14] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
FP_OK="[arm64] EL0 FP context switch OK"
SCHED_OK="[arm64] SMP scheduling OK"
SIG_OK="[arm64] EL0 signal delivery OK"
BRK_OK="[arm64] EL0 page-table brk OK"
PHASE14="[arm64] Phase 14: demand paging via translation-fault handler"
LAUNCH="[arm64] launching EL0 demand-paging task"
FAULT0="[arm64] demand fault: paged in VA 0x0000000040E00000"
FAULT1="[arm64] demand fault: paged in VA 0x0000000040E01000"
READ0="[arm64] EL0 demand read-back #0 -> 0xDEADBEEF11112222"
READ1="[arm64] EL0 demand read-back #1 -> 0xFEEDFACE33334444"
PHYS0="[arm64] demand backing phys #0 -> 0xDEADBEEF11112222"
PHYS1="[arm64] demand backing phys #1 -> 0xFEEDFACE33334444"
STORE_OK="[arm64] demand-paged store/load OK"
FAULTS="[arm64] demand faults serviced -> 0x0000000000000002"
FIRST_TOUCH="[arm64] first-touch pages faulted in on demand"
DEMAND_OK="[arm64] EL0 demand paging OK"

fail() {
    echo "[test_arm64_phase14] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase14] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase14] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase14_test"
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

# --- boot under qemu-system-aarch64 with TWO cores ---------------------
# -smp 2 lets the Phase-10/12 SMP demos run before the demand-paging demo. After
# the demos the kernel masks IRQs and spins in WFI, so QEMU keeps running until the
# timeout kills it. All assertions run on the serial log. aarch64 qemu tests are
# load-independent in CORRECTNESS but boot is slow under host load, so use a
# generous timeout.
timeout 240 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase14] captured serial:"
    sed 's/^/[test_arm64_phase14]   | /' "$SERIAL"
}

# Guard against any demand-paging mismatch being reported.
if grep -q -F "demand read-back mismatch FAIL" "$SERIAL"; then
    dump_serial
    fail "an EL0 demand read-back did not match its sentinel — demand paging broke"
fi
if grep -q -F "demand backing phys mismatch FAIL" "$SERIAL"; then
    dump_serial
    fail "a demand-paged backing physical page did not hold the sentinel"
fi
if grep -q -F "EL0 demand paging FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-14 demand paging reported FAIL"
fi

grep -q "$BANNER"          "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$BRK_OK"       "$SERIAL" || { dump_serial; fail "Phase-9 brk did not complete (Phase 14 not reached) — regression"; }
grep -q -F "$SCHED_OK"     "$SERIAL" || { dump_serial; fail "Phase-12 SMP scheduling did not complete — regression"; }
grep -q -F "$SIG_OK"       "$SERIAL" || { dump_serial; fail "Phase-11 signal demo did not complete — regression"; }
grep -q -F "$FP_OK"        "$SERIAL" || { dump_serial; fail "Phase-13 FP context switch did not complete (Phase 14 not reached) — regression"; }
grep -q -F "$PHASE14"      "$SERIAL" || { dump_serial; fail "Phase-14 demand-paging demo did not start"; }
grep -q -F "$LAUNCH"       "$SERIAL" || { dump_serial; fail "EL0 demand-paging task was not launched"; }
grep -q -F "$FAULT0"       "$SERIAL" || { dump_serial; fail "first demand page was not faulted in (no translation fault serviced)"; }
grep -q -F "$FAULT1"       "$SERIAL" || { dump_serial; fail "second demand page was not faulted in"; }
grep -q -F "$READ0"        "$SERIAL" || { dump_serial; fail "EL0 did not read back sentinel #0 through the demand-paged page"; }
grep -q -F "$READ1"        "$SERIAL" || { dump_serial; fail "EL0 did not read back sentinel #1 through the demand-paged page"; }
grep -q -F "$PHYS0"        "$SERIAL" || { dump_serial; fail "backing physical page #0 did not hold sentinel #0"; }
grep -q -F "$PHYS1"        "$SERIAL" || { dump_serial; fail "backing physical page #1 did not hold sentinel #1"; }
grep -q -F "$STORE_OK"     "$SERIAL" || { dump_serial; fail "'$STORE_OK' missing"; }
grep -q -F "$FAULTS"       "$SERIAL" || { dump_serial; fail "exactly 2 demand faults were not serviced"; }
grep -q -F "$FIRST_TOUCH"  "$SERIAL" || { dump_serial; fail "'$FIRST_TOUCH' missing"; }
grep -q -F "$DEMAND_OK"    "$SERIAL" || { dump_serial; fail "'$DEMAND_OK' not found (demand paging did not complete cleanly)"; }

echo "[test_arm64_phase14] boot banner       : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase14] phase 13 OK (regr) : $(grep -F "$FP_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase14] phase 14 start     : $(grep -F "$PHASE14" "$SERIAL" | head -1)"
echo "[test_arm64_phase14] demand fault #0    : $(grep -F "$FAULT0" "$SERIAL" | head -1)"
echo "[test_arm64_phase14] demand fault #1    : $(grep -F "$FAULT1" "$SERIAL" | head -1)"
echo "[test_arm64_phase14] read-back #0       : $(grep -F "$READ0" "$SERIAL" | head -1)"
echo "[test_arm64_phase14] read-back #1       : $(grep -F "$READ1" "$SERIAL" | head -1)"
echo "[test_arm64_phase14] faults serviced    : $(grep -F "$FAULTS" "$SERIAL" | head -1)"
echo "[test_arm64_phase14] store/load OK      : $(grep -F "$STORE_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase14] demand paging OK   : $(grep -F "$DEMAND_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase14] PASS"
