#!/usr/bin/env bash
# scripts/test_arm64_phase18.sh — PHASE 18 multi-arch milestone: MULTI-PAGE
# anonymous mmap with PER-PAGE demand faulting + a PARTIAL munmap that SPLITS a
# VMA on bare-metal aarch64.
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
# Builds on Phases 4-17. Every prior phase backed exactly ONE 4 KiB page and
# tracked a single span. Phase 18 closes the genuinely-multi-page half of the
# Linux mmap family: a 3-page (0x3000) anonymous region whose pages fault in
# INDEPENDENTLY on first touch (THREE translation faults), then a partial
# munmap of the MIDDLE page that CARVES A HOLE and SPLITS the single VMA into
# two live spans [base, base+0x1000) and [base+0x2000, base+0x3000).
#
# After Phase 17 prints "[arm64] EL0 mprotect OK", kmain hands off to Phase 18.
# The EL0 task:
#   1. mmap(3*4KiB)            -> kernel records ONE VMA, returns the anon base VA
#   2. str s0,[base+0]         -> translation fault; demand-map page 0
#   3. str s1,[base+0x1000]    -> translation fault; demand-map page 1
#   4. str s2,[base+0x2000]    -> translation fault; demand-map page 2
#   5. ldr each ; report       -> kernel verifies all 3 reached distinct pages
#   6. munmap(base+0x1000,4KiB)-> PARTIAL unmap: clears the middle L3 + SPLITS VMA
#   7. ldr base+0; ldr base+0x2000; survive -> the two survivors still hold sentinels
#   8. str s3,[base+0x1000]    -> translation fault in the HOLE (no VMA) -> SIGSEGV
#
# A PASS proves: a multi-page anon region was lazily backed one page per touch
# (EXACTLY three translation faults), all three read-backs reached three distinct
# backing pages, the partial munmap SPLIT the VMA, the two surviving pages STAYED
# mapped across the split, AND the carved-out hole faults fatally (it is in no
# live VMA) — the full Linux multi-page-mmap + VMA-splitting munmap lifecycle on
# bare aarch64. Phases 4-17 must still run to completion (no regression).
#
# Prints "[test_arm64_phase18] PASS" on success or "[test_arm64_phase18] FAIL ...".

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
MPROT_OK="[arm64] EL0 mprotect OK"

PHASE18="[arm64] Phase 18: multi-page mmap + partial munmap that splits a VMA"
MMAP_CALL="[arm64] EL0 mmap(anon multi, len="
DEMAND_FAULT="[arm64] multipage demand fault: paged in anon VA "
READBACK="[arm64] EL0 multipage read-back p0="
RW_OK="[arm64] multipage 3-page demand store/load OK"
MUNMAP_CALL="[arm64] EL0 munmap(partial, addr="
SPLIT="[arm64] munmap split VMA: low [base,hole) + high [hole_end,end)"
SURV_CALL="[arm64] EL0 post-split survivors p0="
SURV_OK="[arm64] multipage split survivors still mapped OK"
HOLE_FAULT="[arm64] multipage hole fault at VA "
DENIED="[arm64] multipage touch of unmapped hole denied (no VMA)"
FAULTS="[arm64] multipage demand faults serviced -> 0x0000000000000003"
ENFORCED="[arm64] multipage mmap split; survivors mapped, hole faults"
MP_OK="[arm64] EL0 multipage mmap split OK"

fail() {
    echo "[test_arm64_phase18] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase18] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase18] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase18_test"
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
# -smp 2 lets the Phase-10/12 SMP demos run before Phase 18. After Phase 18's
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
    echo "[test_arm64_phase18] captured serial:"
    sed 's/^/[test_arm64_phase18]   | /' "$SERIAL"
}

# Guard against any explicit failure markers.
if grep -q -F "multipage mmap split FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-18 multipage reported FAIL"
fi
if grep -q -F "multipage read-back mismatch FAIL" "$SERIAL"; then
    dump_serial
    fail "a pre-munmap read-back did not match its sentinel (page-in/distinct-page failure)"
fi
if grep -q -F "multipage survivor mismatch FAIL" "$SERIAL"; then
    dump_serial
    fail "a surviving page did not keep its sentinel across the VMA split"
fi
if grep -q -F "hole store did NOT fault" "$SERIAL"; then
    dump_serial
    fail "the post-split hole store was allowed instead of faulting — the split did not unmap the middle page"
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
grep -q -F "$MMAP_OK"    "$SERIAL" || { dump_serial; fail "Phase-16 mmap/munmap did not complete — regression"; }
grep -q -F "$MPROT_OK"   "$SERIAL" || { dump_serial; fail "Phase-17 mprotect did not complete (Phase 18 not reached) — regression"; }

# --- Phase 18 assertions ----------------------------------------------
grep -q -F "$PHASE18"     "$SERIAL" || { dump_serial; fail "Phase-18 demo did not start"; }
grep -q -F "$MMAP_CALL"   "$SERIAL" || { dump_serial; fail "EL0 multi-page mmap(anon) was not serviced"; }
# EXACTLY three distinct demand faults (one per page).
NFAULTS="$(grep -c -F "$DEMAND_FAULT" "$SERIAL")"
[ "$NFAULTS" -eq 3 ] || { dump_serial; fail "expected exactly 3 per-page demand faults, saw $NFAULTS"; }
grep -q -F "$READBACK"    "$SERIAL" || { dump_serial; fail "EL0 did not report the three pre-munmap read-backs"; }
grep -q -F "$RW_OK"       "$SERIAL" || { dump_serial; fail "the 3-page demand store/load was not verified OK"; }
grep -q -F "$MUNMAP_CALL" "$SERIAL" || { dump_serial; fail "the partial munmap was not serviced"; }
grep -q -F "$SPLIT"       "$SERIAL" || { dump_serial; fail "the partial munmap did not split the VMA"; }
grep -q -F "$SURV_CALL"   "$SERIAL" || { dump_serial; fail "EL0 did not report the post-split survivors"; }
grep -q -F "$SURV_OK"     "$SERIAL" || { dump_serial; fail "the two surviving pages were not still mapped after the split"; }
grep -q -F "$HOLE_FAULT"  "$SERIAL" || { dump_serial; fail "the post-split hole touch did not fault"; }
grep -q -F "$DENIED"      "$SERIAL" || { dump_serial; fail "the touch of the carved-out hole was not denied (no live VMA)"; }
grep -q -F "$FAULTS"      "$SERIAL" || { dump_serial; fail "the demand fault counter was not exactly 3"; }
grep -q -F "$ENFORCED"    "$SERIAL" || { dump_serial; fail "'$ENFORCED' missing"; }
grep -q -F "$MP_OK"       "$SERIAL" || { dump_serial; fail "'$MP_OK' not found (Phase 18 did not complete cleanly)"; }

echo "[test_arm64_phase18] boot banner         : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] phase 17 OK (regr)   : $(grep -F "$MPROT_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] phase 18 start       : $(grep -F "$PHASE18" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] mmap call            : $(grep -F "$MMAP_CALL" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] per-page faults      : $NFAULTS (expected 3)"
echo "[test_arm64_phase18] read-back            : $(grep -F "$READBACK" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] 3-page store/load OK : $(grep -F "$RW_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] partial munmap       : $(grep -F "$MUNMAP_CALL" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] VMA split            : $(grep -F "$SPLIT" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] survivors            : $(grep -F "$SURV_CALL" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] survivors mapped OK  : $(grep -F "$SURV_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] hole fault (SIGSEGV) : $(grep -F "$HOLE_FAULT" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] hole denied          : $(grep -F "$DENIED" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] faults serviced      : $(grep -F "$FAULTS" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] multipage OK         : $(grep -F "$MP_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase18] PASS"
