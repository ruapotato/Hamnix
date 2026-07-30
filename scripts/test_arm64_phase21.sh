#!/usr/bin/env bash
# scripts/test_arm64_phase21.sh — PHASE 21 multi-arch milestone: a BLOCKING
# PRIMITIVE (sys_nanosleep that DESCHEDULES a task) on bare aarch64, built on
# Phase 20's dynamic-spawn / exit-reaping per-ASID scheduler.
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
# Every prior phase's live tasks were ALWAYS RUNNABLE: the scheduler only ever
# skipped DEAD (reaped) slots. None proves the OTHER half of a real process
# model — a LIVE task can voluntarily DESCHEDULE itself (block) for a span of
# time, the scheduler keeps running the OTHER tasks while it sleeps, and when the
# task's deadline passes the scheduler WAKES it and it RESUMES exactly where it
# blocked (past the nanosleep, with the right return value).
#
# Phase 21 starts TWO preemptively-scheduled EL0 tasks in private ASID-tagged
# spaces: slot A (ASID 7) and slot B (ASID 8). Each loops: read its OWN private
# sentinel byte at a SHARED VA (through its own TTBR0+ASID), report it, then call
# sys_nanosleep(N) — A sleeps LONG (4 ticks), B sleeps SHORT (1 tick). nanosleep
# saves the caller's full resume context, sets a CNTVCT_EL0 deadline, marks the
# slot BLOCKED, and parks its EL0 PC on a self-loop so the svc eret harmlessly
# spins until the next timer tick preempts it. The timer-IRQ scheduler WAKES any
# BLOCKED slot whose deadline passed (back to RUNNABLE) and round-robins ONLY the
# RUNNABLE slots. Because A sleeps longer than B, the scheduler repeatedly runs B
# while A is still blocked (and vice-versa around the wakes).
#
# CRUX: a PASS requires that BOTH tasks ran AND BLOCKED at least once AND were
# WOKEN + resumed past their nanosleep (the deschedule -> deadline -> resume
# cycle, proven for BOTH); at least one tick ran a RUNNABLE task while the OTHER
# was BLOCKED (proving the blocked task genuinely yielded the CPU to a peer); and
# ZERO cross-task sentinel leaks occurred across every preemptive TTBR0+ASID swap.
#
# Phase 21 runs only AFTER Phase 20 prints its PASS marker (the hand-off point),
# so every prior phase (4..20) must still run to completion (no regression).
#
# Prints "[test_arm64_phase21] PASS" on success or "[test_arm64_phase21] FAIL ...".

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

PHASE21="[arm64] Phase 21: blocking nanosleep (deschedule + timer-deadline wake)"
LAUNCH="[arm64] launching sleep-demo EL0 tasks (slot A ASID 7, slot B ASID 8)"
SWAP="[arm64] sleep-demo TTBR0+ASID swap"
REPORT="[arm64] sleep-demo report: slot "
BLOCK="[arm64] sleep-demo: slot "
WAKE="[arm64] sleep-demo: waking slot "
SURVIVED="[arm64] sleep-demo: both tasks blocked + were woken; scheduler ran peers while one slept"
P21_OK="[arm64] EL0 nanosleep block/wake scheduling OK"

fail() {
    echo "[test_arm64_phase21] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase21] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase21] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase21_test"
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
    echo "[test_arm64_phase21] captured serial:"
    sed 's/^/[test_arm64_phase21]   | /' "$SERIAL"
}

# --- guard against any explicit failure markers ------------------------
if grep -q -F "nanosleep block/wake scheduling FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-21 nanosleep block/wake scheduling reported FAIL"
fi
if grep -q -F "sleep-demo LEAK" "$SERIAL"; then
    dump_serial
    fail "a slot read ANOTHER slot's sentinel — ASID-tagged isolation leaked across a swap"
fi
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort paniced the kernel"
fi
if grep -q -F "unknown syscall (phase 21)" "$SERIAL"; then
    dump_serial
    fail "Phase-21 slot issued an unexpected syscall"
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
grep -q -F "$P20_OK"     "$SERIAL" || { dump_serial; fail "Phase-20 dynamic spawn + reaping did not complete (Phase 21 not reached) — regression"; }

# --- Phase 21 assertions ----------------------------------------------
grep -q -F "$PHASE21" "$SERIAL" || { dump_serial; fail "Phase-21 demo did not start"; }
grep -q -F "$LAUNCH"  "$SERIAL" || { dump_serial; fail "Phase-21 did not launch the two sleep-demo EL0 tasks"; }

# Both slots must have run and reported through their private TTBR0+ASID.
grep -q -F "${REPORT}0x0000000000000000" "$SERIAL" || { dump_serial; fail "slot A never reported a read through its private TTBR0+ASID"; }
grep -q -F "${REPORT}0x0000000000000001" "$SERIAL" || { dump_serial; fail "slot B never reported a read through its private TTBR0+ASID"; }

# Both slots must have BLOCKED on nanosleep (the deschedule pillar)...
grep -q -F "${BLOCK}0x0000000000000000 nanosleep -> BLOCKED" "$SERIAL" || { dump_serial; fail "slot A never blocked on nanosleep"; }
grep -q -F "${BLOCK}0x0000000000000001 nanosleep -> BLOCKED" "$SERIAL" || { dump_serial; fail "slot B never blocked on nanosleep"; }

# ...and both slots must have been WOKEN when their deadline passed (the wake pillar).
grep -q -F "${WAKE}0x0000000000000000" "$SERIAL" || { dump_serial; fail "slot A was never woken after its deadline passed"; }
grep -q -F "${WAKE}0x0000000000000001" "$SERIAL" || { dump_serial; fail "slot B was never woken after its deadline passed"; }

# MANY preemptive TTBR0+ASID swaps (survivors keep being preempted).
NSWAPS="$(grep -c -F "$SWAP" "$SERIAL")"
[ "$NSWAPS" -ge 8 ] || { dump_serial; fail "expected at least 8 TTBR0+ASID swaps, saw $NSWAPS"; }

# A task must have resumed AFTER being woken (a slot reports AGAIN after its wake).
# Proven indirectly by the verdict's ran_while_peer_blocked + b_wakes invariants,
# asserted via the SURVIVED summary line which only prints when all hold.
grep -q -F "$SURVIVED" "$SERIAL" || { dump_serial; fail "'$SURVIVED' missing (block+wake-both + ran-while-peer-blocked + zero-leak invariant not proven)"; }
grep -q -F "$P21_OK"   "$SERIAL" || { dump_serial; fail "'$P21_OK' not found (Phase 21 did not complete cleanly)"; }

echo "[test_arm64_phase21] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase21] phase 20 OK (regr)    : $(grep -F "$P20_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase21] phase 21 start        : $(grep -F "$PHASE21" "$SERIAL" | head -1)"
echo "[test_arm64_phase21] launch                : $(grep -F "$LAUNCH" "$SERIAL" | head -1)"
echo "[test_arm64_phase21] slot A report         : $(grep -F "${REPORT}0x0000000000000000" "$SERIAL" | head -1)"
echo "[test_arm64_phase21] slot B report         : $(grep -F "${REPORT}0x0000000000000001" "$SERIAL" | head -1)"
echo "[test_arm64_phase21] slot A blocked        : $(grep -F "${BLOCK}0x0000000000000000 nanosleep" "$SERIAL" | head -1)"
echo "[test_arm64_phase21] slot B blocked        : $(grep -F "${BLOCK}0x0000000000000001 nanosleep" "$SERIAL" | head -1)"
echo "[test_arm64_phase21] slot A woken          : $(grep -F "${WAKE}0x0000000000000000" "$SERIAL" | head -1)"
echo "[test_arm64_phase21] slot B woken          : $(grep -F "${WAKE}0x0000000000000001" "$SERIAL" | head -1)"
echo "[test_arm64_phase21] TTBR0+ASID swaps      : $NSWAPS (>= 8)"
echo "[test_arm64_phase21] tallies               : $(grep -F "sleep-demo swaps=" "$SERIAL" | head -1)"
echo "[test_arm64_phase21] invariant held        : $(grep -F "$SURVIVED" "$SERIAL" | head -1)"
echo "[test_arm64_phase21] sleep sched OK        : $(grep -F "$P21_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase21] PASS"
