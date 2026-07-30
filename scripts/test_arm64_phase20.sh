#!/usr/bin/env bash
# scripts/test_arm64_phase20.sh — PHASE 20 multi-arch milestone: DYNAMIC TASK
# SPAWN + EXIT/REAPING on bare aarch64, built on Phase 19's per-ASID dual-address-
# space scheduler.
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
# Every prior phase ran a FIXED set of statically-built EL0 tasks that either loop
# forever (Phases 5/19) or run a scripted syscall sequence then exit and HALT the
# whole boot. None proved the two pillars of a real process model:
#   (a) a task can EXIT mid-run and the scheduler REAPS it (stops scheduling the
#       dead slot) while the OTHER tasks keep running;
#   (b) a task can be CREATED at runtime — a fresh EL0 task with its OWN private
#       ASID-tagged address space, entry and context block built on the fly — and
#       scheduled in alongside the survivors (a fork-like dynamic spawn).
#
# Phase 20 proves BOTH. It starts two preemptively-scheduled EL0 tasks in private
# ASID-tagged spaces: slot A (ASID 4) and slot B (ASID 5). Each loops reading its
# OWN private sentinel byte at a SHARED VA (resolved through its own TTBR0+ASID)
# and reporting it. After a few reports slot A is steered into exit(7); the kernel
# REAPS slot 0 — the scheduler never selects it again — while slot B keeps running.
# On the next tick the scheduler DYNAMICALLY SPAWNS slot C (ASID 6): a brand-new
# private address space (private shared-VA -> C's own physical block seeded with
# sentinel C), a fresh EL0 routine, a fresh context block, ASID recycle — none of
# which existed before the demo started. The scheduler then round-robins the
# RUNNABLE survivors {B, C}, each reading ONLY its own sentinel through its own
# TTBR0+ASID.
#
# CRUX: a PASS requires that slot A actually ran AND exited AND was reaped; slot B
# survived the whole demo (ran both before AND after the reap+spawn); slot C was
# DYNAMICALLY created at runtime AND ran in its own private ASID space; and ZERO
# cross-task sentinel leaks occurred across every preemptive TTBR0+ASID swap (each
# slot's private translation of the shared VA stayed private — proving the
# dynamically-spawned task got a genuinely isolated ASID-tagged address space).
#
# Phase 20 runs only AFTER Phase 19 prints its PASS marker (the hand-off point), so
# every prior phase (4..19) must still run to completion (no regression).
#
# Prints "[test_arm64_phase20] PASS" on success or "[test_arm64_phase20] FAIL ...".

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

PHASE20="[arm64] Phase 20: dynamic task spawn + exit/reaping"
LAUNCH="[arm64] launching spawn-demo EL0 tasks (slot A ASID 4, slot B ASID 5)"
SWAP="[arm64] spawn-demo TTBR0+ASID swap"
REPORT="[arm64] spawn-demo report: slot "
EXITREQ="[arm64] spawn-demo: slot A requesting exit(7)"
REAP="[arm64] spawn-demo: reaping slot "
SPAWN="[arm64] spawn: dynamically creating slot C (ASID 6) at runtime"
SURVIVED="[arm64] spawn-demo: slot A reaped, slot B survived, slot C dynamically spawned + ran"
P20_OK="[arm64] EL0 dynamic spawn + exit/reaping OK"

fail() {
    echo "[test_arm64_phase20] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase20] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase20] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase20_test"
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
    echo "[test_arm64_phase20] captured serial:"
    sed 's/^/[test_arm64_phase20]   | /' "$SERIAL"
}

# --- guard against any explicit failure markers ------------------------
if grep -q -F "dynamic spawn + exit/reaping FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-20 dynamic spawn / exit-reaping reported FAIL"
fi
if grep -q -F "spawn-demo LEAK" "$SERIAL"; then
    dump_serial
    fail "a slot read ANOTHER slot's sentinel — ASID-tagged isolation leaked across a swap"
fi
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort paniced the kernel"
fi
if grep -q -F "unknown syscall (phase 20)" "$SERIAL"; then
    dump_serial
    fail "Phase-20 slot issued an unexpected syscall"
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
grep -q -F "$P19_OK"     "$SERIAL" || { dump_serial; fail "Phase-19 dual-space ASID sched did not complete (Phase 20 not reached) — regression"; }

# --- Phase 20 assertions ----------------------------------------------
grep -q -F "$PHASE20" "$SERIAL" || { dump_serial; fail "Phase-20 demo did not start"; }
grep -q -F "$LAUNCH"  "$SERIAL" || { dump_serial; fail "Phase-20 did not launch the two spawn-demo EL0 tasks"; }

# Slot A must have run and reported through its private TTBR0+ASID.
grep -q -F "${REPORT}0x0000000000000000" "$SERIAL" || { dump_serial; fail "slot A never reported a read through its private TTBR0+ASID"; }
# Slot B must have run and reported through its private TTBR0+ASID.
grep -q -F "${REPORT}0x0000000000000001" "$SERIAL" || { dump_serial; fail "slot B never reported a read through its private TTBR0+ASID"; }

# Slot A exited and was reaped (process-exit + reaping pillar).
grep -q -F "$EXITREQ" "$SERIAL" || { dump_serial; fail "slot A never requested exit"; }
grep -q -F "${REAP}0x0000000000000000" "$SERIAL" || { dump_serial; fail "slot A was never reaped after exit"; }

# Slot C was DYNAMICALLY spawned at runtime (dynamic-task-creation pillar)...
grep -q -F "$SPAWN" "$SERIAL" || { dump_serial; fail "slot C was never dynamically spawned at runtime"; }
# ...and the dynamically-spawned slot C actually RAN in its own private ASID space.
grep -q -F "${REPORT}0x0000000000000002" "$SERIAL" || { dump_serial; fail "dynamically-spawned slot C never reported a read through its private TTBR0+ASID"; }

# MANY preemptive TTBR0+ASID swaps (the survivors keep being preempted).
NSWAPS="$(grep -c -F "$SWAP" "$SERIAL")"
[ "$NSWAPS" -ge 8 ] || { dump_serial; fail "expected at least 8 TTBR0+ASID swaps, saw $NSWAPS"; }

grep -q -F "$SURVIVED" "$SERIAL" || { dump_serial; fail "'$SURVIVED' missing (reaped-A + survivor-B + spawned-C + zero-leak invariant not proven)"; }
grep -q -F "$P20_OK"   "$SERIAL" || { dump_serial; fail "'$P20_OK' not found (Phase 20 did not complete cleanly)"; }

echo "[test_arm64_phase20] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase20] phase 19 OK (regr)    : $(grep -F "$P19_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase20] phase 20 start        : $(grep -F "$PHASE20" "$SERIAL" | head -1)"
echo "[test_arm64_phase20] launch                : $(grep -F "$LAUNCH" "$SERIAL" | head -1)"
echo "[test_arm64_phase20] slot A report         : $(grep -F "${REPORT}0x0000000000000000" "$SERIAL" | head -1)"
echo "[test_arm64_phase20] slot A exit/reap      : $(grep -F "${REAP}0x0000000000000000" "$SERIAL" | head -1)"
echo "[test_arm64_phase20] dynamic spawn         : $(grep -F "$SPAWN" "$SERIAL" | head -1)"
echo "[test_arm64_phase20] slot B report         : $(grep -F "${REPORT}0x0000000000000001" "$SERIAL" | head -1)"
echo "[test_arm64_phase20] slot C report         : $(grep -F "${REPORT}0x0000000000000002" "$SERIAL" | head -1)"
echo "[test_arm64_phase20] TTBR0+ASID swaps      : $NSWAPS (>= 8)"
echo "[test_arm64_phase20] tallies               : $(grep -F "spawn-demo swaps=" "$SERIAL" | head -1)"
echo "[test_arm64_phase20] invariant held        : $(grep -F "$SURVIVED" "$SERIAL" | head -1)"
echo "[test_arm64_phase20] spawn/reap OK         : $(grep -F "$P20_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase20] PASS"
