#!/usr/bin/env bash
# scripts/test_arm64_phase28.sh — PHASE 28 multi-arch milestone: a REAL BLOCKING
# scheduler with a per-task state model + a blocking sleep/yield syscall +
# timer-driven wake, scaled to THREE concurrent EL0 user tasks on bare aarch64.
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
# Three independent EL0 tasks (T0/T1/T2 = slots 0/1/2) each run in their OWN
# ASID-tagged address space (separate ASID, TTBR0, L1/L2/L3, EL0 stack and saved
# register-context block). Each runs the SAME small EL0 routine at the SAME
# virtual address: increment a 64-bit counter at the SAME EL0 VA a few times,
# then issue a BLOCKING sleep syscall (x8 = 600, x0 = ticks). That VA maps, per
# ASID, to a DIFFERENT PHYSICAL page per task, so each advances its OWN counter.
#
# Unlike Phase 27 (pure timer round-robin, no syscall), Phase 28 adds a real
# RUNNABLE/SLEEPING task-state model. The sleep syscall DESCHEDULES the caller:
# saves its full resume context, records a wake deadline = current_tick + a0,
# marks it SLEEPING and parks its EL0 PC on a self-loop. On each timer IRQ the
# scheduler advances a logical tick, WAKES any SLEEPING task whose deadline has
# passed (back to RUNNABLE), then round-robins to the next RUNNABLE task SKIPPING
# any SLEEPING one. A sleeping task is therefore genuinely never dispatched until
# the timer wakes it: real block -> yield -> wake.
#
# After a fixed number of ticks the verdict asserts: ALL THREE counters advanced;
# enough tasks blocked AND were woken (sleeps>=3, wakes>=3, wakes==sleeps so no
# lost wakeups / nothing left stuck SLEEPING); the picker genuinely skipped a
# SLEEPING task (skips>0); and the three counters live at the same VA in DISTINCT
# physical pages.
#
# Phase 28 runs only AFTER Phase 27 prints its PASS marker (the hand-off point),
# so every prior phase (4..27) must still run to completion (no regression).
#
# Prints "[test_arm64_phase28] PASS" on success or "[test_arm64_phase28] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
BRK_OK="[arm64] EL0 page-table brk OK"
SCHED_OK="[arm64] SMP scheduling OK"
SIG_OK="[arm64] EL0 signal delivery OK"
FP_OK="[arm64] EL0 FP context switch OK"
DEMAND_OK="[arm64] EL0 demand paging OK"
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
P25_PASS="[arm64] Phase 25 PASS"
P26_PASS="[arm64] Phase 26 PASS"
P27_PASS="[arm64] Phase 27 PASS"

PHASE28="[arm64] Phase 28: blocking scheduler (RUNNABLE/SLEEPING) across three EL0 tasks"
LAUNCH="[arm64] launching three blocking EL0 tasks"
SLEEPMARK="[arm64] Phase 28: task"
WAKEMARK="[arm64] Phase 28: waking task"
ISOLATED="[arm64] Phase 28: a blocking scheduler with per-task RUNNABLE/SLEEPING state"
SUMMARY="[arm64] Phase 28 summary:"
P28_PASS="[arm64] Phase 28 PASS"

fail() {
    echo "[test_arm64_phase28] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase28] qemu-system-aarch64 not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y qemu-system-arm >/dev/null 2>&1 || true
    fi
    if command -v qemu-system-aarch64 >/dev/null 2>&1; then
        QEMU="qemu-system-aarch64"
    else
        fail "qemu-system-aarch64 not installed (apt install qemu-system-arm)"
    fi
fi

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase28_test"
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

# --- boot under qemu-system-aarch64 with TWO cores ---------------------
timeout 360 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase28] captured serial:"
    sed 's/^/[test_arm64_phase28]   | /' "$SERIAL"
}

# --- guard against any explicit failure markers ------------------------
if grep -q -F "Phase 28 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-28 scheduler reported FAIL"
fi
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort paniced the kernel"
fi
if grep -q -F "EL0 non-SVC sync exception" "$SERIAL"; then
    dump_serial
    fail "an unexpected EL0 non-SVC sync exception fired (a task faulted)"
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
grep -q -F "$P24_PASS"   "$SERIAL" || { dump_serial; fail "Phase-24 demand paging did not complete — regression"; }
grep -q -F "$P25_PASS"   "$SERIAL" || { dump_serial; fail "Phase-25 COW fork did not complete — regression"; }
grep -q -F "$P26_PASS"   "$SERIAL" || { dump_serial; fail "Phase-26 ELF loader did not complete — regression"; }
grep -q -F "$P27_PASS"   "$SERIAL" || { dump_serial; fail "Phase-27 timer round-robin did not complete (Phase 28 not reached) — regression"; }

# --- Phase 28 assertions ----------------------------------------------
grep -q -F "$PHASE28"  "$SERIAL" || { dump_serial; fail "Phase-28 demo did not start"; }
grep -q -F "$LAUNCH"   "$SERIAL" || { dump_serial; fail "Phase-28 did not launch the three EL0 tasks"; }

# At least three tasks must have BLOCKED (sleep syscall) and been WOKEN.
NSLEEP="$(grep -c -F "$SLEEPMARK" "$SERIAL")"
NWAKE="$(grep -c -F "$WAKEMARK" "$SERIAL")"
[ "$NSLEEP" -ge 3 ] || { dump_serial; fail "expected >= 3 sleep events, saw $NSLEEP"; }
[ "$NWAKE"  -ge 3 ] || { dump_serial; fail "expected >= 3 wake events, saw $NWAKE"; }

grep -q -F "$SUMMARY"  "$SERIAL" || { dump_serial; fail "Phase-28 summary line not emitted"; }
grep -q -F "$ISOLATED" "$SERIAL" || { dump_serial; fail "Phase-28 isolation/blocking invariant not proven"; }
grep -q -F "$P28_PASS" "$SERIAL" || { dump_serial; fail "'$P28_PASS' not found (Phase 28 did not complete cleanly)"; }

# --- parse the summary and assert the blocking-scheduler invariants ----
SUM_LINE="$(grep -F "$SUMMARY" "$SERIAL" | head -1)"
T0_HEX="$(echo "$SUM_LINE" | sed -n 's/.* t0=\(0x[0-9a-fA-F]*\) .*/\1/p')"
T1_HEX="$(echo "$SUM_LINE" | sed -n 's/.* t1=\(0x[0-9a-fA-F]*\) .*/\1/p')"
T2_HEX="$(echo "$SUM_LINE" | sed -n 's/.* t2=\(0x[0-9a-fA-F]*\) .*/\1/p')"
SLEEPS_HEX="$(echo "$SUM_LINE" | sed -n 's/.* sleeps=\(0x[0-9a-fA-F]*\) .*/\1/p')"
WAKES_HEX="$(echo "$SUM_LINE" | sed -n 's/.* wakes=\(0x[0-9a-fA-F]*\) .*/\1/p')"
SKIPS_HEX="$(echo "$SUM_LINE" | sed -n 's/.* skips=\(0x[0-9a-fA-F]*\) .*/\1/p')"

[ -n "$T0_HEX" ]     || { dump_serial; fail "could not parse t0 from summary"; }
[ -n "$T1_HEX" ]     || { dump_serial; fail "could not parse t1 from summary"; }
[ -n "$T2_HEX" ]     || { dump_serial; fail "could not parse t2 from summary"; }
[ -n "$SLEEPS_HEX" ] || { dump_serial; fail "could not parse sleeps from summary"; }
[ -n "$WAKES_HEX" ]  || { dump_serial; fail "could not parse wakes from summary"; }
[ -n "$SKIPS_HEX" ]  || { dump_serial; fail "could not parse skips from summary"; }

T0_VAL=$((T0_HEX)); T1_VAL=$((T1_HEX)); T2_VAL=$((T2_HEX))
SLEEPS_VAL=$((SLEEPS_HEX)); WAKES_VAL=$((WAKES_HEX)); SKIPS_VAL=$((SKIPS_HEX))

# All three tasks made forward progress (the 3-way scheduler dispatched each).
[ "$T0_VAL" -gt 0 ] || { dump_serial; fail "T0 counter did not advance (t0=$T0_HEX)"; }
[ "$T1_VAL" -gt 0 ] || { dump_serial; fail "T1 counter did not advance (t1=$T1_HEX)"; }
[ "$T2_VAL" -gt 0 ] || { dump_serial; fail "T2 counter did not advance (t2=$T2_HEX)"; }

# Real block/wake cycles: sleeps>=3, wakes>=3, every sleeper eventually woke.
[ "$SLEEPS_VAL" -ge 3 ]            || { dump_serial; fail "expected sleeps>=3, got $SLEEPS_VAL"; }
[ "$WAKES_VAL"  -ge 3 ]            || { dump_serial; fail "expected wakes>=3, got $WAKES_VAL"; }
[ "$WAKES_VAL"  -eq "$SLEEPS_VAL" ] || { dump_serial; fail "lost wakeup: wakes($WAKES_VAL) != sleeps($SLEEPS_VAL)"; }

# The picker genuinely passed over SLEEPING tasks at least once.
[ "$SKIPS_VAL" -gt 0 ] || { dump_serial; fail "picker never skipped a SLEEPING task (skips=$SKIPS_VAL)"; }

echo "[test_arm64_phase28] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase28] phase 27 OK (regr)    : $(grep -F "$P27_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase28] phase 28 start        : $(grep -F "$PHASE28" "$SERIAL" | head -1)"
echo "[test_arm64_phase28] sleep events          : $NSLEEP (>= 3)"
echo "[test_arm64_phase28] wake events           : $NWAKE (>= 3)"
echo "[test_arm64_phase28] summary line          : $SUM_LINE"
echo "[test_arm64_phase28] T0/T1/T2 counters     : $T0_HEX / $T1_HEX / $T2_HEX (all > 0)"
echo "[test_arm64_phase28] sleeps/wakes/skips    : $SLEEPS_VAL / $WAKES_VAL / $SKIPS_VAL"
echo "[test_arm64_phase28] isolation invariant   : $(grep -F "$ISOLATED" "$SERIAL" | head -1)"
echo "[test_arm64_phase28] phase 28 PASS line    : $(grep -F "$P28_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase28] PASS"
