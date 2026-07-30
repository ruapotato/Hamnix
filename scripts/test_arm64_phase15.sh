#!/usr/bin/env bash
# scripts/test_arm64_phase15.sh — PHASE 15 multi-arch milestone: SAFE USER-MEMORY
# ACCESS with EFAULT FAULT-TRAPPING (Linux-shape copy_from_user / copy_to_user) on
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
# Builds on Phases 4-14 (EL0 + svc, preemptive scheduling, page-fault reaping,
# per-task TTBR0 isolation, broader syscall surface, page-table brk, SMP secondary
# bring-up + scheduling, EL0 signal delivery, EL0 FP/SIMD save-restore, demand
# paging). Phases 6/14 trap aborts taken FROM EL0; Phase 15 closes the other half:
# an abort taken FROM EL1 because the KERNEL ITSELF dereferenced a bad user
# pointer. A real kernel must never trust user pointers — a bad one must yield
# -EFAULT, never a crash.
#
# After Phase 14 prints "[arm64] EL0 demand paging OK", kmain hands off to Phase
# 15. Running entirely at EL1 (no EL0 task), the kernel exercises its own safe
# accessors:
#   1. A new current-EL synchronous vector entry (arm64_el1_sync_entry) routes EL1h
#      synchronous exceptions to arm64_el1_sync_handler. If a uaccess is in flight
#      and the exception is a data abort (the kernel touched a bad user pointer),
#      the handler latches the fault and advances ELR_EL1 past the faulting
#      instruction so the kernel RESUMES (exactly Linux's exception-table fixup) —
#      otherwise it reports the syndrome and halts (a genuine kernel bug).
#   2. The _uaccess_get64 / _uaccess_put64 codegen intrinsics emit a single
#      faultable load/store; arm64_copy_from_user_u64 / arm64_copy_to_user_u64 wrap
#      them, arming the uaccess window only across the access and returning 0 or
#      -EFAULT (-14) per the copy_*_user contract.
#   3. The demo performs five accesses: a VALID copy_from_user (returns the seed),
#      TWO copy_from_user from distinct wholly-unmapped VAs (-EFAULT each), a
#      copy_to_user to an unmapped VA (-EFAULT), and a VALID copy_to_user whose
#      value the kernel then re-reads to confirm it landed.
#
# A PASS proves: (a) the kernel survived dereferencing bad user pointers on BOTH
# the read and write side and returned EFAULT instead of crashing (3 faults
# trapped); (b) valid copy_from_user/copy_to_user still work; (c) Phases 4-14 still
# run to completion (no regression — every prior PASS marker appears).
#
# Prints "[test_arm64_phase15] PASS" on success or "[test_arm64_phase15] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
DEMAND_OK="[arm64] EL0 demand paging OK"
FP_OK="[arm64] EL0 FP context switch OK"
SCHED_OK="[arm64] SMP scheduling OK"
SIG_OK="[arm64] EL0 signal delivery OK"
BRK_OK="[arm64] EL0 page-table brk OK"

PHASE15="[arm64] Phase 15: safe user access with EFAULT trapping"
READ_GOOD="[arm64] copy_from_user(good) -> rc 0x0000000000000000 val 0x5151ABCD0000F00D"
# -EFAULT (-14) returned as an unsigned 64-bit rc by the safe accessors.
EFAULT_RC="0xFFFFFFFFFFFFFFF2"
READ_BAD1="[arm64] copy_from_user(unmapped#1) -> rc ${EFAULT_RC}"
READ_BAD2="[arm64] copy_from_user(unmapped#2) -> rc ${EFAULT_RC}"
WRITE_BAD="[arm64] copy_to_user(unmapped) -> rc ${EFAULT_RC}"
EFAULT_READ="[arm64] copy_from_user returned -EFAULT (no crash)"
EFAULT_WRITE="[arm64] copy_to_user returned -EFAULT (no crash)"
WRITE_GOOD="[arm64] copy_to_user(good) -> rc 0x0000000000000000 val 0xCA11AB1E99990000"
FAULTS="[arm64] uaccess EFAULTs trapped -> 0x0000000000000003"
TRAPPED="[arm64] bad user pointers trapped, valid accesses OK"
UACCESS_OK="[arm64] EL1 safe user access OK"

fail() {
    echo "[test_arm64_phase15] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase15] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase15] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase15_test"
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
# -smp 2 lets the Phase-10/12 SMP demos run before Phase 15. After the demos the
# kernel masks IRQs and spins in WFI, so QEMU keeps running until the timeout
# kills it. All assertions run on the serial log. aarch64 qemu tests are
# load-independent in CORRECTNESS but boot is slow under host load, so use a
# generous timeout.
timeout 300 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase15] captured serial:"
    sed 's/^/[test_arm64_phase15]   | /' "$SERIAL"
}

# Guard against any explicit failure markers.
if grep -q -F "EL1 safe user access FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-15 safe user access reported FAIL"
fi
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort was NOT trapped as a uaccess fault — the kernel paniced (a bad pointer crashed the kernel)"
fi

# --- regression: every prior phase must still complete -----------------
grep -q "$BANNER"        "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$BRK_OK"     "$SERIAL" || { dump_serial; fail "Phase-9 brk did not complete — regression"; }
grep -q -F "$SCHED_OK"   "$SERIAL" || { dump_serial; fail "Phase-12 SMP scheduling did not complete — regression"; }
grep -q -F "$SIG_OK"     "$SERIAL" || { dump_serial; fail "Phase-11 signal demo did not complete — regression"; }
grep -q -F "$FP_OK"      "$SERIAL" || { dump_serial; fail "Phase-13 FP context switch did not complete — regression"; }
grep -q -F "$DEMAND_OK"  "$SERIAL" || { dump_serial; fail "Phase-14 demand paging did not complete (Phase 15 not reached) — regression"; }

# --- Phase 15 assertions ----------------------------------------------
grep -q -F "$PHASE15"     "$SERIAL" || { dump_serial; fail "Phase-15 demo did not start"; }
grep -q -F "$READ_GOOD"   "$SERIAL" || { dump_serial; fail "copy_from_user(good) did not return rc 0 with the seeded value"; }
grep -q -F "$READ_BAD1"   "$SERIAL" || { dump_serial; fail "copy_from_user(unmapped#1) did not return -EFAULT"; }
grep -q -F "$READ_BAD2"   "$SERIAL" || { dump_serial; fail "copy_from_user(unmapped#2) did not return -EFAULT"; }
grep -q -F "$WRITE_BAD"   "$SERIAL" || { dump_serial; fail "copy_to_user(unmapped) did not return -EFAULT"; }
grep -q -F "$EFAULT_READ"  "$SERIAL" || { dump_serial; fail "copy_from_user bad-pointer access did not announce a trapped -EFAULT"; }
grep -q -F "$EFAULT_WRITE" "$SERIAL" || { dump_serial; fail "copy_to_user(bad) did not announce a trapped -EFAULT"; }
grep -q -F "$WRITE_GOOD"   "$SERIAL" || { dump_serial; fail "copy_to_user(good) did not return rc 0 with the written value re-read"; }
[ "$(grep -c -F "${EFAULT_RC}" "$SERIAL")" -ge 3 ] || { dump_serial; fail "fewer than 3 accesses returned the -EFAULT rc"; }
grep -q -F "$FAULTS"       "$SERIAL" || { dump_serial; fail "exactly 3 EFAULTs were not trapped"; }
grep -q -F "$TRAPPED"      "$SERIAL" || { dump_serial; fail "'$TRAPPED' missing"; }
grep -q -F "$UACCESS_OK"   "$SERIAL" || { dump_serial; fail "'$UACCESS_OK' not found (safe user access did not complete cleanly)"; }

echo "[test_arm64_phase15] boot banner       : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase15] phase 14 OK (regr) : $(grep -F "$DEMAND_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase15] phase 15 start     : $(grep -F "$PHASE15" "$SERIAL" | head -1)"
echo "[test_arm64_phase15] read good          : $(grep -F "$READ_GOOD" "$SERIAL" | head -1)"
echo "[test_arm64_phase15] read bad #1        : $(grep -F "$READ_BAD1" "$SERIAL" | head -1)"
echo "[test_arm64_phase15] read bad #2        : $(grep -F "$READ_BAD2" "$SERIAL" | head -1)"
echo "[test_arm64_phase15] EFAULT rc count    : $(grep -c -F "${EFAULT_RC}" "$SERIAL") accesses returned -EFAULT"
echo "[test_arm64_phase15] write EFAULT       : $(grep -F "$WRITE_BAD" "$SERIAL" | head -1)"
echo "[test_arm64_phase15] write good         : $(grep -F "$WRITE_GOOD" "$SERIAL" | head -1)"
echo "[test_arm64_phase15] faults trapped     : $(grep -F "$FAULTS" "$SERIAL" | head -1)"
echo "[test_arm64_phase15] safe access OK     : $(grep -F "$UACCESS_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase15] PASS"
