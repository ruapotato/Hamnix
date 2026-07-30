#!/usr/bin/env bash
# scripts/test_arm64_phase16.sh — PHASE 16 multi-arch milestone: EL0 mmap/munmap
# with DEMAND-PAGED ANONYMOUS MAPPINGS on bare-metal aarch64.
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
# Builds on Phases 4-15. Phase 14 demand-paged a HARD-CODED window (the abort
# handler knew the two demand VAs by constant). Phase 16 makes it DYNAMIC, exactly
# like Linux mmap: a single EL0 task asks the kernel for an anonymous region of a
# given length; the kernel records a VMA (a [base,len) span) and returns the base
# WITHOUT mapping any page. The pages materialise lazily ON FIRST TOUCH, and ONLY
# because the faulting VA falls inside a LIVE VMA. munmap then tears the region
# down so a later touch of the SAME address faults fatally (a real SIGSEGV).
#
# After Phase 15 prints "[arm64] EL1 safe user access OK", kmain hands off to
# Phase 16. The EL0 task:
#   1. mmap(len)              -> kernel records a VMA, returns the anon base VA
#   2. str sentinel,[base]    -> translation fault; the abort handler walks the VMA
#                               table, finds the VA covered, demand-maps a fresh
#                               page and RESUMES the store (it now completes)
#   3. ldr back               -> reads the sentinel through the new mapping
#   4. mmap_report(readback)  -> kernel verifies the value reached the backing page
#   5. write(1,msg,len)       -> echoes a buffer through the mapped page
#   6. munmap(base,len)       -> kernel clears the L3 entry, drops the VMA, flushes
#   7. str sentinel2,[base]   -> translation fault AGAIN, now in NO VMA, so the
#                               handler reaps the task (a real SIGSEGV)
#
# A PASS proves: the anon region was lazily backed only inside its VMA (exactly one
# demand fault), the read-back reached the backing physical page, AND munmap
# genuinely removed the mapping (the post-munmap touch faulted and was NOT silently
# re-paged) — the full Linux mmap/munmap lifecycle on bare aarch64. Phases 4-15
# must still run to completion (no regression — every prior PASS marker appears).
#
# Prints "[test_arm64_phase16] PASS" on success or "[test_arm64_phase16] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
DEMAND_OK="[arm64] EL0 demand paging OK"
FP_OK="[arm64] EL0 FP context switch OK"
SCHED_OK="[arm64] SMP scheduling OK"
SIG_OK="[arm64] EL0 signal delivery OK"
BRK_OK="[arm64] EL0 page-table brk OK"
UACCESS_OK="[arm64] EL1 safe user access OK"

PHASE16="[arm64] Phase 16: EL0 mmap/munmap with demand-paged anonymous mappings"
MMAP_CALL="[arm64] EL0 mmap(anon, len="
DEMAND_FAULT="[arm64] mmap demand fault: paged in anon VA "
READBACK="[arm64] EL0 mmap read-back -> "
BACKING="[arm64] mmap backing phys -> "
PAGED_OK="[arm64] mmap demand-paged store/load OK"
MUNMAP_CALL="[arm64] EL0 munmap(base="
SEGV="[arm64] mmap post-munmap fault (no VMA) at VA "
NORE="[arm64] munmap region unmapped; touch faulted (no re-page)"
FAULTS="[arm64] mmap demand faults serviced -> 0x0000000000000001"
LAZY="[arm64] anon mmap lazily backed; munmap removed it"
MMAP_OK="[arm64] EL0 mmap/munmap OK"

fail() {
    echo "[test_arm64_phase16] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase16] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase16] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase16_test"
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
# -smp 2 lets the Phase-10/12 SMP demos run before Phase 16. After Phase 16's
# final SIGSEGV the kernel masks IRQs and spins in WFI, so QEMU keeps running until
# the timeout kills it. aarch64 qemu tests are load-independent in CORRECTNESS but
# boot is slow under host load, so use a generous timeout.
timeout 360 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase16] captured serial:"
    sed 's/^/[test_arm64_phase16]   | /' "$SERIAL"
}

# Guard against any explicit failure markers.
if grep -q -F "EL0 mmap/munmap FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-16 mmap/munmap reported FAIL"
fi
if grep -q -F "mmap backing phys mismatch FAIL" "$SERIAL"; then
    dump_serial
    fail "the demand map did not reach the backing physical page"
fi
if grep -q -F "mmap read-back mismatch FAIL" "$SERIAL"; then
    dump_serial
    fail "the EL0 read-back did not match the stored sentinel"
fi
if grep -q -F "touch did NOT fault" "$SERIAL"; then
    dump_serial
    fail "the post-munmap touch was re-paged instead of faulting — munmap did not remove the mapping"
fi
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort paniced the kernel"
fi

# --- regression: every prior phase must still complete -----------------
grep -q "$BANNER"        "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$BRK_OK"     "$SERIAL" || { dump_serial; fail "Phase-9 brk did not complete — regression"; }
grep -q -F "$SCHED_OK"   "$SERIAL" || { dump_serial; fail "Phase-12 SMP scheduling did not complete — regression"; }
grep -q -F "$SIG_OK"     "$SERIAL" || { dump_serial; fail "Phase-11 signal demo did not complete — regression"; }
grep -q -F "$FP_OK"      "$SERIAL" || { dump_serial; fail "Phase-13 FP context switch did not complete — regression"; }
grep -q -F "$DEMAND_OK"  "$SERIAL" || { dump_serial; fail "Phase-14 demand paging did not complete — regression"; }
grep -q -F "$UACCESS_OK" "$SERIAL" || { dump_serial; fail "Phase-15 safe user access did not complete (Phase 16 not reached) — regression"; }

# --- Phase 16 assertions ----------------------------------------------
grep -q -F "$PHASE16"     "$SERIAL" || { dump_serial; fail "Phase-16 demo did not start"; }
grep -q -F "$MMAP_CALL"   "$SERIAL" || { dump_serial; fail "EL0 mmap(anon) was not serviced"; }
grep -q -F "$DEMAND_FAULT" "$SERIAL" || { dump_serial; fail "the first anon touch did not demand-fault into the VMA"; }
grep -q -F "$READBACK"    "$SERIAL" || { dump_serial; fail "EL0 did not report the demand-paged read-back"; }
grep -q -F "$BACKING"     "$SERIAL" || { dump_serial; fail "kernel did not verify the backing physical page"; }
grep -q -F "$PAGED_OK"    "$SERIAL" || { dump_serial; fail "the demand-paged store/load was not verified OK"; }
grep -q -F "$MUNMAP_CALL" "$SERIAL" || { dump_serial; fail "EL0 munmap was not serviced"; }
grep -q -F "$SEGV"        "$SERIAL" || { dump_serial; fail "the post-munmap touch did not fault (no VMA)"; }
grep -q -F "$NORE"        "$SERIAL" || { dump_serial; fail "munmap-removed mapping was not confirmed (touch may have been re-paged)"; }
grep -q -F "$FAULTS"      "$SERIAL" || { dump_serial; fail "exactly one demand fault was not serviced inside the VMA"; }
grep -q -F "$LAZY"        "$SERIAL" || { dump_serial; fail "'$LAZY' missing"; }
grep -q -F "$MMAP_OK"     "$SERIAL" || { dump_serial; fail "'$MMAP_OK' not found (mmap/munmap did not complete cleanly)"; }

echo "[test_arm64_phase16] boot banner       : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase16] phase 15 OK (regr) : $(grep -F "$UACCESS_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase16] phase 16 start     : $(grep -F "$PHASE16" "$SERIAL" | head -1)"
echo "[test_arm64_phase16] mmap call          : $(grep -F "$MMAP_CALL" "$SERIAL" | head -1)"
echo "[test_arm64_phase16] demand fault       : $(grep -F "$DEMAND_FAULT" "$SERIAL" | head -1)"
echo "[test_arm64_phase16] read-back          : $(grep -F "$READBACK" "$SERIAL" | head -1)"
echo "[test_arm64_phase16] backing phys       : $(grep -F "$BACKING" "$SERIAL" | head -1)"
echo "[test_arm64_phase16] paged OK           : $(grep -F "$PAGED_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase16] munmap call        : $(grep -F "$MUNMAP_CALL" "$SERIAL" | head -1)"
echo "[test_arm64_phase16] post-munmap SIGSEGV: $(grep -F "$SEGV" "$SERIAL" | head -1)"
echo "[test_arm64_phase16] faults serviced    : $(grep -F "$FAULTS" "$SERIAL" | head -1)"
echo "[test_arm64_phase16] mmap/munmap OK     : $(grep -F "$MMAP_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase16] PASS"
