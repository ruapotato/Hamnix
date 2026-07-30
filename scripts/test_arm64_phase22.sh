#!/usr/bin/env bash
# scripts/test_arm64_phase22.sh — PHASE 22 multi-arch milestone: an EL0 FUTEX
# (FUTEX_WAIT on a memory word / FUTEX_WAKE by a peer) on bare aarch64, built on
# Phase 21's BLOCKED-state + resume-context-save + park-ctx blocking machinery.
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
# Phase 21 proved one kind of blocking: a task deschedules itself for a span of
# time and a TIMER deadline wakes it. Phase 22 proves the OTHER kind: a task
# blocks on a memory WORD and is woken by a PEER task signalling that word —
# i.e. a futex. The only difference from nanosleep is the wake condition.
#
# Phase 22 starts TWO preemptively-scheduled EL0 tasks in private ASID-tagged
# spaces: a WAITER (slot A, ASID 9) and a WAKER (slot B, ASID 10). BOTH map ONE
# shared physical futex word at a well-known shared VA; the PHYSICAL address
# backing that word is the cross-ASID match key. Each task also has its OWN
# private sentinel byte (a different shared VA -> a per-slot private block) for
# the observable tick-report / leak-detection pattern.
#
# The WAITER loops: report its private sentinel, then FUTEX_WAIT(F, 0) — if *F==0
# it records the futex key on its slot, marks itself BLOCKED-on-futex, saves its
# resume context and parks its EL0 PC (the timer tick switches away). The WAKER
# loops: report its private sentinel, nanosleep(short) to yield so the waiter
# blocks first, then write *F=1, FUTEX_WAKE(F, 1) to flip the matching BLOCKED-
# on-futex waiter back to RUNNABLE, then write *F=0 so the waiter's next wait
# blocks again. The waiter resumes past its FUTEX_WAIT and the cycle repeats.
#
# CRUX: a PASS requires the WAITER to have BLOCKED on the futex word at least
# once AND to have been WOKEN by a peer FUTEX_WAKE at least once (the block-on-
# word / wake-by-peer cycle), that at least one FUTEX_WAKE actually woke a
# waiter, that at least one tick ran a task while its peer was BLOCKED (the
# deschedule-others pillar), that BOTH tasks ran (read their private sentinel),
# and that ZERO cross-task sentinel leaks occurred across the TTBR0+ASID swaps.
#
# Phase 22 runs only AFTER Phase 21 prints its PASS marker (the hand-off point),
# so every prior phase (4..21) must still run to completion (no regression).
#
# Prints "[test_arm64_phase22] PASS" on success or "[test_arm64_phase22] FAIL ...".

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

PHASE22="[arm64] Phase 22: EL0 futex (FUTEX_WAIT on a word + peer FUTEX_WAKE)"
LAUNCH="[arm64] launching futex-demo EL0 tasks (waiter ASID 9, waker ASID 10)"
SWAP="[arm64] futex-demo TTBR0+ASID swap"
REPORT="[arm64] futex-demo report: slot "
BLOCK="[arm64] futex-demo: slot "
WAKE="[arm64] futex-demo: FUTEX_WAKE woke slot "
SURVIVED="[arm64] futex-demo: waiter blocked on a word + was woken by a peer FUTEX_WAKE; scheduler ran the peer while it blocked"
P22_OK="[arm64] EL0 futex wait/wake scheduling OK"

fail() {
    echo "[test_arm64_phase22] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase22] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase22] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase22_test"
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
    echo "[test_arm64_phase22] captured serial:"
    sed 's/^/[test_arm64_phase22]   | /' "$SERIAL"
}

# --- guard against any explicit failure markers ------------------------
if grep -q -F "futex wait/wake scheduling FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-22 futex wait/wake scheduling reported FAIL"
fi
if grep -q -F "futex-demo LEAK" "$SERIAL"; then
    dump_serial
    fail "a slot read ANOTHER slot's sentinel — ASID-tagged isolation leaked across a swap"
fi
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort paniced the kernel"
fi
if grep -q -F "unknown syscall (phase 22)" "$SERIAL"; then
    dump_serial
    fail "Phase-22 slot issued an unexpected syscall"
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
grep -q -F "$P21_OK"     "$SERIAL" || { dump_serial; fail "Phase-21 nanosleep block/wake did not complete (Phase 22 not reached) — regression"; }

# --- Phase 22 assertions ----------------------------------------------
grep -q -F "$PHASE22" "$SERIAL" || { dump_serial; fail "Phase-22 demo did not start"; }
grep -q -F "$LAUNCH"  "$SERIAL" || { dump_serial; fail "Phase-22 did not launch the two futex-demo EL0 tasks"; }

# Both slots must have run and reported through their private TTBR0+ASID.
grep -q -F "${REPORT}0x0000000000000000" "$SERIAL" || { dump_serial; fail "waiter (slot A) never reported a read through its private TTBR0+ASID"; }
grep -q -F "${REPORT}0x0000000000000001" "$SERIAL" || { dump_serial; fail "waker (slot B) never reported a read through its private TTBR0+ASID"; }

# The waiter must have BLOCKED on the futex word (the block-on-word pillar)...
grep -q -F "${BLOCK}0x0000000000000000 FUTEX_WAIT -> BLOCKED on key" "$SERIAL" || { dump_serial; fail "waiter never blocked on the futex word"; }

# ...and must have been WOKEN by a peer FUTEX_WAKE (the wake-by-peer pillar).
grep -q -F "${WAKE}0x0000000000000000" "$SERIAL" || { dump_serial; fail "waiter was never woken by a peer FUTEX_WAKE"; }

# MANY preemptive TTBR0+ASID swaps (the scheduler keeps round-robining).
NSWAPS="$(grep -c -F "$SWAP" "$SERIAL")"
[ "$NSWAPS" -ge 8 ] || { dump_serial; fail "expected at least 8 TTBR0+ASID swaps, saw $NSWAPS"; }

# The waiter must have blocked + been woken MORE THAN ONCE (a real cycle, not a
# one-shot) — assert at least two distinct FUTEX_WAKE-woke-waiter lines.
NWAKES="$(grep -c -F "$WAKE" "$SERIAL")"
[ "$NWAKES" -ge 2 ] || { dump_serial; fail "expected at least 2 FUTEX_WAKE wakeups (a repeated block/wake cycle), saw $NWAKES"; }

# The full invariant (block-on-word + wake-by-peer + ran-while-peer-blocked +
# zero-leak) is asserted by the SURVIVED summary line, which only prints when all
# hold, and the final OK marker.
grep -q -F "$SURVIVED" "$SERIAL" || { dump_serial; fail "'$SURVIVED' missing (block-on-word + wake-by-peer + ran-while-peer-blocked + zero-leak invariant not proven)"; }
grep -q -F "$P22_OK"   "$SERIAL" || { dump_serial; fail "'$P22_OK' not found (Phase 22 did not complete cleanly)"; }

echo "[test_arm64_phase22] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase22] phase 21 OK (regr)    : $(grep -F "$P21_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase22] phase 22 start        : $(grep -F "$PHASE22" "$SERIAL" | head -1)"
echo "[test_arm64_phase22] launch                : $(grep -F "$LAUNCH" "$SERIAL" | head -1)"
echo "[test_arm64_phase22] waiter report         : $(grep -F "${REPORT}0x0000000000000000" "$SERIAL" | head -1)"
echo "[test_arm64_phase22] waker  report         : $(grep -F "${REPORT}0x0000000000000001" "$SERIAL" | head -1)"
echo "[test_arm64_phase22] waiter blocked        : $(grep -F "${BLOCK}0x0000000000000000 FUTEX_WAIT" "$SERIAL" | head -1)"
echo "[test_arm64_phase22] waiter woken (1st)    : $(grep -F "${WAKE}0x0000000000000000" "$SERIAL" | head -1)"
echo "[test_arm64_phase22] FUTEX_WAKE wakeups    : $NWAKES (>= 2)"
echo "[test_arm64_phase22] TTBR0+ASID swaps      : $NSWAPS (>= 8)"
echo "[test_arm64_phase22] tallies               : $(grep -F "futex-demo swaps=" "$SERIAL" | head -1)"
echo "[test_arm64_phase22] invariant held        : $(grep -F "$SURVIVED" "$SERIAL" | head -1)"
echo "[test_arm64_phase22] futex sched OK        : $(grep -F "$P22_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase22] PASS"
