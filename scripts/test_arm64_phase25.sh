#!/usr/bin/env bash
# scripts/test_arm64_phase25.sh — PHASE 25 multi-arch milestone: COPY-ON-WRITE
# fork() for an EL0 task on bare aarch64.
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
# The parent runs in its OWN ASID-tagged address space (ASID 13) mapping a single
# 4 KiB COW data page (VA 0x4240_0000, via its own L3 table) RW-private and seeded
# with a sentinel. The parent writes a pre-fork value, then FORKs: the kernel
# builds a SECOND wholly-independent address space (ASID 14) that aliases the SAME
# backing physical page, and flips BOTH parent and child's L3 PTE for that page to
# EL0 READ-ONLY (a copy-on-write share). A WRITE by either side then takes a
# PERMISSION data abort; the COW handler allocates a FRESH physical page, copies
# the shared page into it, remaps ONLY the faulting space's L3 PTE to the new page
# RW-PRIVATE (leaving the other side untouched), flushes that ASID and resumes.
#
# Parent and child each write a DIFFERENT value to the SAME VA and read it back;
# the kernel verifies each side sees its OWN value, that EXACTLY 2 COW faults were
# serviced (one per side), and that the two backing physical pages DIVERGED — i.e.
# genuine COW address-space isolation. Deterministic + abort-driven (IRQs masked,
# no scheduler): the child runs to completion first, then the parent resumes past
# the fork to its own exit + verdict.
#
# Phase 25 runs only AFTER Phase 24 prints its PASS marker (the hand-off point),
# so every prior phase (4..24) must still run to completion (no regression).
#
# Prints "[test_arm64_phase25] PASS" on success or "[test_arm64_phase25] FAIL ...".

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
MP_OK="[arm64] EL0 multipage mmap split OK"
P19_OK="[arm64] EL0 dual-address-space ASID sched OK"
P20_OK="[arm64] EL0 dynamic spawn + exit/reaping OK"
P21_OK="[arm64] EL0 nanosleep block/wake scheduling OK"
P22_OK="[arm64] EL0 futex wait/wake scheduling OK"
P23_OK="[arm64] EL0 thread-local storage (TPIDR_EL0) scheduling OK"
P24_PASS="[arm64] Phase 24 PASS"

PHASE25="[arm64] Phase 25: copy-on-write fork() for an EL0 task"
LAUNCH="[arm64] launching EL0 COW-fork parent task (ASID 13)"
FORKED="[arm64] Phase 25 fork: built child space (ASID "
COW_FAULT="[arm64] Phase 25 COW fault: "
RESUME="[arm64] Phase 25: child done -> resuming parent past fork"
ISOLATED="[arm64] Phase 25: fork gave child a private COW address space"
P25_PASS="[arm64] Phase 25 PASS"

fail() {
    echo "[test_arm64_phase25] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase25] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase25] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase25_test"
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
timeout 360 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase25] captured serial:"
    sed 's/^/[test_arm64_phase25]   | /' "$SERIAL"
}

# --- guard against any explicit failure markers ------------------------
if grep -q -F "Phase 25 COW-fork FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-25 COW-fork reported FAIL"
fi
if grep -q -F "unknown syscall (phase 25)" "$SERIAL"; then
    dump_serial
    fail "Phase-25 task issued an unexpected syscall"
fi
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort paniced the kernel"
fi
if grep -q -F "EL0 non-SVC sync exception" "$SERIAL"; then
    dump_serial
    fail "an unexpected EL0 non-SVC sync exception fired (a COW fault was not serviced)"
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
grep -q -F "$MPROT_OK"   "$SERIAL" || { dump_serial; fail "Phase-17 mprotect did not complete — regression"; }
grep -q -F "$MP_OK"      "$SERIAL" || { dump_serial; fail "Phase-18 multipage mmap split did not complete — regression"; }
grep -q -F "$P19_OK"     "$SERIAL" || { dump_serial; fail "Phase-19 dual-space ASID sched did not complete — regression"; }
grep -q -F "$P20_OK"     "$SERIAL" || { dump_serial; fail "Phase-20 dynamic spawn + reaping did not complete — regression"; }
grep -q -F "$P21_OK"     "$SERIAL" || { dump_serial; fail "Phase-21 nanosleep block/wake did not complete — regression"; }
grep -q -F "$P22_OK"     "$SERIAL" || { dump_serial; fail "Phase-22 futex wait/wake did not complete — regression"; }
grep -q -F "$P23_OK"     "$SERIAL" || { dump_serial; fail "Phase-23 thread-local storage did not complete — regression"; }
grep -q -F "$P24_PASS"   "$SERIAL" || { dump_serial; fail "Phase-24 demand paging did not complete (Phase 25 not reached) — regression"; }

# --- Phase 25 assertions ----------------------------------------------
grep -q -F "$PHASE25" "$SERIAL" || { dump_serial; fail "Phase-25 demo did not start"; }
grep -q -F "$LAUNCH"  "$SERIAL" || { dump_serial; fail "Phase-25 did not launch the COW-fork parent task"; }
grep -q -F "$FORKED"  "$SERIAL" || { dump_serial; fail "Phase-25 fork() did not build the child space"; }

# EXACTLY 2 COW permission faults must have been serviced (one per side).
NCOW="$(grep -c -F "$COW_FAULT" "$SERIAL")"
[ "$NCOW" -eq 2 ] || { dump_serial; fail "expected exactly 2 COW faults, saw $NCOW"; }

# Both a child COW fault and a parent COW fault must have fired.
grep -q -F "${COW_FAULT}child"  "$SERIAL" || { dump_serial; fail "child COW fault never fired"; }
grep -q -F "${COW_FAULT}parent" "$SERIAL" || { dump_serial; fail "parent COW fault never fired"; }

grep -q -F "$RESUME"   "$SERIAL" || { dump_serial; fail "parent was not resumed past the fork"; }
grep -q -F "$ISOLATED" "$SERIAL" || { dump_serial; fail "COW isolation invariant not proven"; }
grep -q -F "$P25_PASS" "$SERIAL" || { dump_serial; fail "'$P25_PASS' not found (Phase 25 did not complete cleanly)"; }

echo "[test_arm64_phase25] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase25] phase 24 OK (regr)    : $(grep -F "$P24_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase25] phase 25 start        : $(grep -F "$PHASE25" "$SERIAL" | head -1)"
echo "[test_arm64_phase25] fork built child      : $(grep -F "$FORKED" "$SERIAL" | head -1)"
echo "[test_arm64_phase25] COW faults            : $NCOW (== 2)"
echo "[test_arm64_phase25] parent resumed        : $(grep -F "$RESUME" "$SERIAL" | head -1)"
echo "[test_arm64_phase25] isolation invariant   : $(grep -F "$ISOLATED" "$SERIAL" | head -1)"
echo "[test_arm64_phase25] phase 25 PASS line    : $(grep -F "$P25_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase25] PASS"
