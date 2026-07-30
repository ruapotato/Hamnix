#!/usr/bin/env bash
# scripts/test_arm64_phase17.sh — PHASE 17 multi-arch milestone: EL0 mprotect
# (nr 226) — CHANGING PAGE PERMISSIONS with a real permission-fault check on
# bare-metal aarch64.
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
# Builds on Phases 4-16. Phase 16 proved an anon mapping materialises on first
# touch (TRANSLATION fault) and tears down via munmap. Phase 17 closes the
# permissions half of the Linux mmap family: a mapped, WRITABLE anon page is
# downgraded to READ-ONLY in place, exactly like Linux mprotect(addr, len,
# PROT_READ). The kernel rewrites the page's L3 descriptor AP[2:1] from RW (0b01)
# to RO (0b11); the next EL0 STORE now raises a genuine PERMISSION Data Abort
# (ESR_EL1.ISS.DFSC = 0b0011xx) — a real SIGSEGV (SEGV_ACCERR) — while a LOAD
# still succeeds (RO is readable).
#
# After Phase 16 prints "[arm64] EL0 mmap/munmap OK", kmain hands off to Phase 17.
# The EL0 task:
#   1. mmap(len)               -> kernel records a VMA, returns the anon base VA
#   2. str sentinel,[base]     -> TRANSLATION fault; handler demand-maps RW, resumes
#   3. ldr back ; report       -> kernel verifies the RW store/load reached the page
#   4. mprotect(base,len,RD)   -> kernel flips the live L3 AP[2:1] RW->RO, flushes
#   5. ldr after-protect       -> STILL succeeds (RO permits reads); report it
#   6. str sentinel2,[base]    -> PERMISSION fault (write to RO) -> real SIGSEGV
#
# A PASS proves: the page was demand-mapped RW (exactly one TRANSLATION fault),
# the RW read-back matched, mprotect flipped the live descriptor to RO, a post-
# mprotect READ STILL succeeded (RO is readable), AND the post-mprotect WRITE
# raised a genuine PERMISSION fault (NOT a translation fault — the page is still
# mapped, just not writable) — the full Linux mprotect lifecycle on bare aarch64.
# Phases 4-16 must still run to completion (no regression — every prior PASS
# marker appears).
#
# Prints "[test_arm64_phase17] PASS" on success or "[test_arm64_phase17] FAIL ...".

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
MMAP_OK="[arm64] EL0 mmap/munmap OK"

PHASE17="[arm64] Phase 17: EL0 mprotect (change page permissions, permission-fault check)"
MMAP_CALL="[arm64] EL0 mmap(anon, len="
DEMAND_FAULT="[arm64] mprotect demand fault: paged in RW anon VA "
RW_READBACK="[arm64] EL0 mprotect RW read-back -> "
RW_OK="[arm64] mprotect RW store/load OK"
MPROT_CALL="[arm64] EL0 mprotect(base="
SET_RO="[arm64] mprotect set page read-only (PROT_READ)"
RD_AFTER="[arm64] EL0 read after mprotect(RO) -> "
RD_STILL_OK="[arm64] mprotect read-only page still readable OK"
PERM_FAULT="[arm64] mprotect store-to-RO fault at VA "
DENIED="[arm64] mprotect write to read-only page denied (permission fault)"
FAULTS="[arm64] mprotect demand faults serviced -> 0x0000000000000001"
ENFORCED="[arm64] mprotect RW->RO enforced; read OK, write denied"
MPROT_OK="[arm64] EL0 mprotect OK"

fail() {
    echo "[test_arm64_phase17] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase17] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase17] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase17_test"
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
# -smp 2 lets the Phase-10/12 SMP demos run before Phase 17. After Phase 17's
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
    echo "[test_arm64_phase17] captured serial:"
    sed 's/^/[test_arm64_phase17]   | /' "$SERIAL"
}

# Guard against any explicit failure markers.
if grep -q -F "EL0 mprotect FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-17 mprotect reported FAIL"
fi
if grep -q -F "mprotect backing phys mismatch FAIL" "$SERIAL"; then
    dump_serial
    fail "the demand RW map did not reach the backing physical page"
fi
if grep -q -F "mprotect RW read-back mismatch FAIL" "$SERIAL"; then
    dump_serial
    fail "the EL0 RW read-back did not match the stored sentinel"
fi
if grep -q -F "mprotect post-RO read mismatch FAIL" "$SERIAL"; then
    dump_serial
    fail "the post-mprotect read returned the wrong value"
fi
if grep -q -F "RO store did NOT fault" "$SERIAL"; then
    dump_serial
    fail "the post-mprotect store was allowed instead of faulting — mprotect did not enforce RO"
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
grep -q -F "$UACCESS_OK" "$SERIAL" || { dump_serial; fail "Phase-15 safe user access did not complete — regression"; }
grep -q -F "$MMAP_OK"    "$SERIAL" || { dump_serial; fail "Phase-16 mmap/munmap did not complete (Phase 17 not reached) — regression"; }

# --- Phase 17 assertions ----------------------------------------------
grep -q -F "$PHASE17"     "$SERIAL" || { dump_serial; fail "Phase-17 demo did not start"; }
grep -q -F "$MMAP_CALL"   "$SERIAL" || { dump_serial; fail "EL0 mmap(anon) was not serviced"; }
grep -q -F "$DEMAND_FAULT" "$SERIAL" || { dump_serial; fail "the first anon touch did not demand-fault into an RW page"; }
grep -q -F "$RW_READBACK" "$SERIAL" || { dump_serial; fail "EL0 did not report the RW read-back"; }
grep -q -F "$RW_OK"       "$SERIAL" || { dump_serial; fail "the demand-paged RW store/load was not verified OK"; }
grep -q -F "$MPROT_CALL"  "$SERIAL" || { dump_serial; fail "EL0 mprotect was not serviced"; }
grep -q -F "$SET_RO"      "$SERIAL" || { dump_serial; fail "mprotect did not set the page read-only"; }
grep -q -F "$RD_AFTER"    "$SERIAL" || { dump_serial; fail "EL0 did not report the post-mprotect read"; }
grep -q -F "$RD_STILL_OK" "$SERIAL" || { dump_serial; fail "the read-only page was not still readable (RO read should succeed)"; }
grep -q -F "$PERM_FAULT"  "$SERIAL" || { dump_serial; fail "the post-mprotect store did not take a permission fault"; }
grep -q -F "$DENIED"      "$SERIAL" || { dump_serial; fail "the write to the read-only page was not denied via a permission fault"; }
grep -q -F "$FAULTS"      "$SERIAL" || { dump_serial; fail "exactly one demand (translation) fault was not serviced"; }
grep -q -F "$ENFORCED"    "$SERIAL" || { dump_serial; fail "'$ENFORCED' missing"; }
grep -q -F "$MPROT_OK"    "$SERIAL" || { dump_serial; fail "'$MPROT_OK' not found (mprotect did not complete cleanly)"; }

echo "[test_arm64_phase17] boot banner        : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] phase 16 OK (regr)  : $(grep -F "$MMAP_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] phase 17 start      : $(grep -F "$PHASE17" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] mmap call           : $(grep -F "$MMAP_CALL" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] RW demand fault     : $(grep -F "$DEMAND_FAULT" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] RW read-back        : $(grep -F "$RW_READBACK" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] RW store/load OK    : $(grep -F "$RW_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] mprotect call       : $(grep -F "$MPROT_CALL" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] set read-only       : $(grep -F "$SET_RO" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] read after RO        : $(grep -F "$RD_AFTER" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] RO still readable    : $(grep -F "$RD_STILL_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] perm fault (SIGSEGV) : $(grep -F "$PERM_FAULT" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] write denied         : $(grep -F "$DENIED" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] faults serviced      : $(grep -F "$FAULTS" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] mprotect OK          : $(grep -F "$MPROT_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase17] PASS"
