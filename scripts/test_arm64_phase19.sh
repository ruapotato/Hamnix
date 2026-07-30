#!/usr/bin/env bash
# scripts/test_arm64_phase19.sh — PHASE 19 multi-arch milestone: TWO
# preemptively-scheduled EL0 tasks, EACH in its OWN TTBR0_EL1 address space WITH
# its own ASID, where the timer-IRQ context switch swaps TTBR0+ASID as well as the
# saved register context — real per-ASID dual-address-space multitasking on bare
# aarch64.
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
# Builds on Phases 4-18. Phase 5 already round-robins two EL0 tasks under the EL1
# timer IRQ, but BOTH share the single identity TTBR0 (one address space). Phase 7
# proves two tasks CAN have private TTBR0 spaces, but only as a one-shot, non-
# preemptive hand-switch. Phase 19 FUSES the two AND adds genuine ASID handling:
# two tasks run concurrently, each in a PRIVATE translation regime (private L1/L2
# root mapping the SAME shared VA to a DIFFERENT physical page, seeded with a
# DISTINCT sentinel) tagged by a DISTINCT ASID (A=1, B=2). Every preemptive timer
# tick swaps BOTH the register context AND TTBR0_EL1 (with the ASID in bits[63:48]).
#
# CRUX: on each swap the scheduler does NOT issue a broad `tlbi vmalle1is` flush —
# it relies on per-ASID TLB tagging to keep each task's translation of the SHARED
# VA distinct. Each task loops: read its private sentinel at the shared VA via its
# own TTBR0+ASID, report it (kernel-private syscall 546), busy-loop, repeat. The
# kernel tallies, per task, how many reports carried the CORRECT (own) sentinel,
# and counts any LEAK (a report carrying the OTHER task's sentinel — which would
# mean an ASID-untagged stale TLB entry leaked across the swap).
#
# After Phase 18 prints "[arm64] EL0 multipage mmap split OK", kmain hands off to
# Phase 19. A PASS proves: BOTH tasks actually ran (each reported its own sentinel
# at least once), MANY preemptive TTBR0+ASID swaps occurred, AND zero cross-task
# leaks happened — every task's private translation of the SHARED VA stayed
# private across every swap, i.e. real ASID-tagged dual-address-space preemptive
# multitasking. Phases 4-18 must still run to completion (no regression).
#
# Prints "[test_arm64_phase19] PASS" on success or "[test_arm64_phase19] FAIL ...".

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

PHASE19="[arm64] Phase 19: dual-address-space preemptive scheduling with per-task ASID"
LAUNCH="[arm64] launching dual-address-space EL0 tasks (ASID A=1, B=2)"
SWAP="[arm64] dualspace TTBR0+ASID swap"
REPORT="[arm64] dualspace report: task "
ISO_HELD="[arm64] dualspace both tasks ran private; ASID isolation held"
P19_OK="[arm64] EL0 dual-address-space ASID sched OK"

fail() {
    echo "[test_arm64_phase19] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase19] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase19] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase19_test"
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
# -smp 2 lets the Phase-10/12 SMP demos run before Phase 19. After Phase 19's
# verdict the kernel masks IRQs and spins in WFI, so QEMU keeps running until the
# timeout kills it. aarch64 qemu tests are load-independent in CORRECTNESS but
# boot is slow under host load, so use a generous timeout.
timeout 360 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase19] captured serial:"
    sed 's/^/[test_arm64_phase19]   | /' "$SERIAL"
}

# Guard against any explicit failure markers.
if grep -q -F "dual-address-space ASID sched FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-19 dual-address-space scheduling reported FAIL"
fi
if grep -q -F "dualspace LEAK" "$SERIAL"; then
    dump_serial
    fail "a task read the OTHER task's sentinel — ASID-tagged isolation leaked across a swap"
fi
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort paniced the kernel"
fi
if grep -q -F "unknown syscall (phase 19)" "$SERIAL"; then
    dump_serial
    fail "Phase-19 task issued an unexpected syscall"
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
grep -q -F "$MP_OK"      "$SERIAL" || { dump_serial; fail "Phase-18 multipage mmap split did not complete (Phase 19 not reached) — regression"; }

# --- Phase 19 assertions ----------------------------------------------
grep -q -F "$PHASE19"  "$SERIAL" || { dump_serial; fail "Phase-19 demo did not start"; }
grep -q -F "$LAUNCH"   "$SERIAL" || { dump_serial; fail "Phase-19 did not launch the two dual-space EL0 tasks"; }

# MANY preemptive TTBR0+ASID swaps (the demo's goal is 12; require a solid run).
NSWAPS="$(grep -c -F "$SWAP" "$SERIAL")"
[ "$NSWAPS" -ge 8 ] || { dump_serial; fail "expected at least 8 TTBR0+ASID swaps, saw $NSWAPS"; }

# BOTH tasks must have run and reported through their private TTBR0+ASID. The
# traced reports name the task index (0x..0 = A, 0x..1 = B).
grep -q -F "${REPORT}0x0000000000000000" "$SERIAL" || { dump_serial; fail "task A never reported a read through its private TTBR0+ASID"; }
grep -q -F "${REPORT}0x0000000000000001" "$SERIAL" || { dump_serial; fail "task B never reported a read through its private TTBR0+ASID"; }

grep -q -F "$ISO_HELD" "$SERIAL" || { dump_serial; fail "'$ISO_HELD' missing (both-ran + zero-leak invariant not proven)"; }
grep -q -F "$P19_OK"   "$SERIAL" || { dump_serial; fail "'$P19_OK' not found (Phase 19 did not complete cleanly)"; }

echo "[test_arm64_phase19] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase19] phase 18 OK (regr)    : $(grep -F "$MP_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase19] phase 19 start        : $(grep -F "$PHASE19" "$SERIAL" | head -1)"
echo "[test_arm64_phase19] launch                : $(grep -F "$LAUNCH" "$SERIAL" | head -1)"
echo "[test_arm64_phase19] TTBR0+ASID swaps      : $NSWAPS (>= 8)"
echo "[test_arm64_phase19] task A report         : $(grep -F "${REPORT}0x0000000000000000" "$SERIAL" | head -1)"
echo "[test_arm64_phase19] task B report         : $(grep -F "${REPORT}0x0000000000000001" "$SERIAL" | head -1)"
echo "[test_arm64_phase19] tallies               : $(grep -F "dualspace swaps=" "$SERIAL" | head -1)"
echo "[test_arm64_phase19] isolation held        : $(grep -F "$ISO_HELD" "$SERIAL" | head -1)"
echo "[test_arm64_phase19] dual-space OK         : $(grep -F "$P19_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase19] PASS"
