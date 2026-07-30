#!/usr/bin/env bash
# scripts/test_arm64_phase29.sh — PHASE 29 multi-arch milestone: the Linux-style
# EL0 TASK EXIT + PARENT WAIT/REAP lifecycle, layered on the Phase-28 blocking
# scheduler and scaled to THREE concurrent EL0 user tasks on bare aarch64.
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
# ASID-tagged address space (separate ASID, TTBR0, L1/L2, EL0 stack and saved
# register-context block). Each increments a 64-bit counter at a SHARED EL0 VA
# (mapped per-ASID to a DIFFERENT physical page) a few times, then EXITS with a
# DISTINCT status (task i exits with status 0x10 + i). Task 0 first BLOCKS on a
# sleep syscall before exiting, proving exit composes with the blocking-state
# machine.
#
# Task-state model extends Phase 28's RUNNABLE/SLEEPING with two terminal states:
#   EXITED — the task called exit(status); a ZOMBIE (status recorded, not reaped).
#            The scheduler must NEVER dispatch it.
#   DEAD   — the reaper collected (reaped) its exit status; fully gone.
#
# The exit syscall (x8 = 601, x0 = status) records the status, marks the caller
# EXITED and parks its EL0 PC. On each timer IRQ the scheduler advances a logical
# tick, WAKES expired sleepers, REAPS any EXITED zombie (collecting its status,
# EXITED -> DEAD, bumping a reap counter), then round-robins the RUNNABLE tasks
# (skipping SLEEPING, never selecting EXITED/DEAD). Once all three are DEAD the
# verdict asserts: every task reached EXITED then DEAD; each exit_status matches
# the distinct value the task passed; each was reaped EXACTLY once (reaps == 3);
# each private counter advanced; the three data pages are at DISTINCT physical
# addresses.
#
# Phase 29 runs only AFTER Phase 28 prints its PASS marker (the hand-off point),
# so every prior phase (4..28) must still run to completion (no regression).
#
# Prints "[test_arm64_phase29] PASS" on success or "[test_arm64_phase29] FAIL ...".

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
P28_PASS="[arm64] Phase 28 PASS"

PHASE29="[arm64] Phase 29: EL0 task exit + wait/reap across three EL0 tasks"
LAUNCH="[arm64] launching three EL0 tasks that exit with distinct statuses"
EXITMARK="[arm64] Phase 29: task"
REAPMARK="[arm64] Phase 29: reaped task"
ISOLATED="[arm64] Phase 29: THREE EL0 tasks each ran in its OWN address space"
SUMMARY="[arm64] Phase 29 summary:"
P29_PASS="[arm64] Phase 29 PASS"

fail() {
    echo "[test_arm64_phase29] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase29] qemu-system-aarch64 not found; attempting apt install"
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
WORK="$PROJ_ROOT/build/arm64_phase29_test"
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
    echo "[test_arm64_phase29] captured serial:"
    sed 's/^/[test_arm64_phase29]   | /' "$SERIAL"
}

# --- guard against any explicit failure markers ------------------------
if grep -q -F "Phase 29 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-29 lifecycle reported FAIL"
fi
if grep -q -F "Phase 28 FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-28 scheduler reported FAIL (regression)"
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
grep -q -F "$P27_PASS"   "$SERIAL" || { dump_serial; fail "Phase-27 timer round-robin did not complete — regression"; }
grep -q -F "$P28_PASS"   "$SERIAL" || { dump_serial; fail "Phase-28 blocking scheduler did not complete (Phase 29 not reached) — regression"; }

# --- Phase 29 assertions ----------------------------------------------
grep -q -F "$PHASE29"  "$SERIAL" || { dump_serial; fail "Phase-29 demo did not start"; }
grep -q -F "$LAUNCH"   "$SERIAL" || { dump_serial; fail "Phase-29 did not launch the three EL0 tasks"; }

# All three tasks must have EXITED, and all three must have been REAPED.
NREAP="$(grep -c -F "$REAPMARK" "$SERIAL")"
[ "$NREAP" -eq 3 ] || { dump_serial; fail "expected exactly 3 reap events, saw $NREAP"; }

grep -q -F "$SUMMARY"  "$SERIAL" || { dump_serial; fail "Phase-29 summary line not emitted"; }
grep -q -F "$ISOLATED" "$SERIAL" || { dump_serial; fail "Phase-29 exit/reap invariant not proven"; }
grep -q -F "$P29_PASS" "$SERIAL" || { dump_serial; fail "'$P29_PASS' not found (Phase 29 did not complete cleanly)"; }

# --- parse the summary and assert the exit/reap invariants -------------
SUM_LINE="$(grep -F "$SUMMARY" "$SERIAL" | head -1)"
T0_HEX="$(echo "$SUM_LINE" | sed -n 's/.* t0=\(0x[0-9a-fA-F]*\) .*/\1/p')"
T1_HEX="$(echo "$SUM_LINE" | sed -n 's/.* t1=\(0x[0-9a-fA-F]*\) .*/\1/p')"
T2_HEX="$(echo "$SUM_LINE" | sed -n 's/.* t2=\(0x[0-9a-fA-F]*\) .*/\1/p')"
ST0_HEX="$(echo "$SUM_LINE" | sed -n 's/.* st0=\(0x[0-9a-fA-F]*\) .*/\1/p')"
ST1_HEX="$(echo "$SUM_LINE" | sed -n 's/.* st1=\(0x[0-9a-fA-F]*\) .*/\1/p')"
ST2_HEX="$(echo "$SUM_LINE" | sed -n 's/.* st2=\(0x[0-9a-fA-F]*\) .*/\1/p')"
EXITS_HEX="$(echo "$SUM_LINE" | sed -n 's/.* exits=\(0x[0-9a-fA-F]*\) .*/\1/p')"
REAPS_HEX="$(echo "$SUM_LINE" | sed -n 's/.* reaps=\(0x[0-9a-fA-F]*\) .*/\1/p')"
SLEEPS_HEX="$(echo "$SUM_LINE" | sed -n 's/.* sleeps=\(0x[0-9a-fA-F]*\) .*/\1/p')"
WAKES_HEX="$(echo "$SUM_LINE" | sed -n 's/.* wakes=\(0x[0-9a-fA-F]*\)$/\1/p')"

[ -n "$T0_HEX" ]    || { dump_serial; fail "could not parse t0 from summary"; }
[ -n "$T1_HEX" ]    || { dump_serial; fail "could not parse t1 from summary"; }
[ -n "$T2_HEX" ]    || { dump_serial; fail "could not parse t2 from summary"; }
[ -n "$ST0_HEX" ]   || { dump_serial; fail "could not parse st0 from summary"; }
[ -n "$ST1_HEX" ]   || { dump_serial; fail "could not parse st1 from summary"; }
[ -n "$ST2_HEX" ]   || { dump_serial; fail "could not parse st2 from summary"; }
[ -n "$EXITS_HEX" ] || { dump_serial; fail "could not parse exits from summary"; }
[ -n "$REAPS_HEX" ] || { dump_serial; fail "could not parse reaps from summary"; }
[ -n "$SLEEPS_HEX" ] || { dump_serial; fail "could not parse sleeps from summary"; }
[ -n "$WAKES_HEX" ] || { dump_serial; fail "could not parse wakes from summary"; }

T0_VAL=$((T0_HEX)); T1_VAL=$((T1_HEX)); T2_VAL=$((T2_HEX))
ST0_VAL=$((ST0_HEX)); ST1_VAL=$((ST1_HEX)); ST2_VAL=$((ST2_HEX))
EXITS_VAL=$((EXITS_HEX)); REAPS_VAL=$((REAPS_HEX))
SLEEPS_VAL=$((SLEEPS_HEX)); WAKES_VAL=$((WAKES_HEX))

# All three tasks made forward progress (each ran in its OWN private page).
[ "$T0_VAL" -gt 0 ] || { dump_serial; fail "T0 counter did not advance (t0=$T0_HEX)"; }
[ "$T1_VAL" -gt 0 ] || { dump_serial; fail "T1 counter did not advance (t1=$T1_HEX)"; }
[ "$T2_VAL" -gt 0 ] || { dump_serial; fail "T2 counter did not advance (t2=$T2_HEX)"; }

# Each recorded exit status matches the DISTINCT value the task passed (0x10+i).
[ "$ST0_VAL" -eq 16 ] || { dump_serial; fail "T0 exit status wrong: st0=$ST0_HEX (want 0x10)"; }
[ "$ST1_VAL" -eq 17 ] || { dump_serial; fail "T1 exit status wrong: st1=$ST1_HEX (want 0x11)"; }
[ "$ST2_VAL" -eq 18 ] || { dump_serial; fail "T2 exit status wrong: st2=$ST2_HEX (want 0x12)"; }

# The statuses are distinct (zombie status collection collected the right values).
[ "$ST0_VAL" -ne "$ST1_VAL" ] || { dump_serial; fail "st0 == st1 (statuses not distinct)"; }
[ "$ST0_VAL" -ne "$ST2_VAL" ] || { dump_serial; fail "st0 == st2 (statuses not distinct)"; }
[ "$ST1_VAL" -ne "$ST2_VAL" ] || { dump_serial; fail "st1 == st2 (statuses not distinct)"; }

# Exactly three exits and three reaps (each task exited and was reaped once).
[ "$EXITS_VAL" -eq 3 ] || { dump_serial; fail "expected exits==3, got $EXITS_VAL"; }
[ "$REAPS_VAL" -eq 3 ] || { dump_serial; fail "expected reaps==3, got $REAPS_VAL"; }

# Exit composed with blocking: at least one sleep, and every sleeper woke.
[ "$SLEEPS_VAL" -ge 1 ]            || { dump_serial; fail "expected sleeps>=1, got $SLEEPS_VAL"; }
[ "$WAKES_VAL" -eq "$SLEEPS_VAL" ] || { dump_serial; fail "lost wakeup: wakes($WAKES_VAL) != sleeps($SLEEPS_VAL)"; }

echo "[test_arm64_phase29] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase29] phase 28 OK (regr)    : $(grep -F "$P28_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase29] phase 29 start        : $(grep -F "$PHASE29" "$SERIAL" | head -1)"
echo "[test_arm64_phase29] reap events           : $NREAP (== 3)"
echo "[test_arm64_phase29] summary line          : $SUM_LINE"
echo "[test_arm64_phase29] T0/T1/T2 counters     : $T0_HEX / $T1_HEX / $T2_HEX (all > 0)"
echo "[test_arm64_phase29] exit statuses         : $ST0_HEX / $ST1_HEX / $ST2_HEX (distinct 0x10/0x11/0x12)"
echo "[test_arm64_phase29] exits/reaps           : $EXITS_VAL / $REAPS_VAL (each == 3)"
echo "[test_arm64_phase29] sleeps/wakes          : $SLEEPS_VAL / $WAKES_VAL"
echo "[test_arm64_phase29] exit/reap invariant   : $(grep -F "$ISOLATED" "$SERIAL" | head -1)"
echo "[test_arm64_phase29] phase 29 PASS line    : $(grep -F "$P29_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase29] PASS"
