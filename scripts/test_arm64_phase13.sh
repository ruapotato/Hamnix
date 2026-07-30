#!/usr/bin/env bash
# scripts/test_arm64_phase13.sh — PHASE 13 multi-arch milestone: EL0 FP/SIMD
# CONTEXT SAVE/RESTORE ACROSS A CONTEXT SWITCH on bare-metal aarch64.
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
# Builds on Phases 4-12 (EL0 + svc, preemptive scheduling, page-fault reaping,
# per-task TTBR0 isolation, broader syscall surface, page-table brk, SMP
# secondary bring-up, EL0 signal delivery, SMP scheduling under a spinlock). The
# earlier scheduler only saved the GPRs across a context switch, NOT the FP/SIMD
# register file — so FP state did NOT survive a switch. Phase 13 closes that gap.
#
# After Phase 11 prints "[arm64] EL0 signal delivery OK", kmain hands off to
# Phase 13:
#   1. CPACR_EL1.FPEN is enabled so EL0 (and the kernel) may run FP/SIMD ops.
#   2. Two EL0 tasks each seed the callee-saved scalar FP register d8 with a
#      DISTINCTIVE signature (FP_SIG0 / FP_SIG1), then loop: read d8 back, hand it
#      to the kernel via a private `fpcheck` syscall, and cooperatively `yield`.
#   3. The kernel runs a cooperative round-robin scheduler keyed off yield. On
#      every yield it SAVES the outgoing task's d8..d15 to its FP save area and
#      RESTORES the incoming task's d8..d15 from its save area — the FP half of a
#      context switch. Between a task's two yields the OTHER task overwrites the
#      LIVE d8 with its own signature, so WITHOUT the save/restore a task would
#      read back the wrong value; fpcheck FAILs loudly if a task ever observes a
#      value other than its own signature.
#   4. After each task has been scheduled FP_YIELD_LIMIT (6) times with every
#      fpcheck matching, the kernel prints the Phase-13 PASS marker and halts.
#
# A PASS proves: (a) FP/SIMD state is per-task and survives an EL0<->EL0 context
# switch; (b) CPACR_EL1.FPEN ungating + d8..d15 STP/LDP save/restore work on bare
# metal; (c) Phases 4-12 still run to completion (no regression — the Phase-9 brk,
# Phase-10 SMP, Phase-12 spinlock-scheduling and Phase-11 signal markers appear).
#
# Prints "[test_arm64_phase13] PASS" on success or "[test_arm64_phase13] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
SCHED_OK="[arm64] SMP scheduling OK"
SIG_OK="[arm64] EL0 signal delivery OK"
PHASE13="[arm64] Phase 13: EL0 FP/SIMD context save/restore"
FPEN="[arm64] CPACR_EL1.FPEN enabled"
LAUNCH="[arm64] launching EL0 FP tasks"
CHECK0="[arm64] fpcheck OK task=0x0000000000000000 d8=0x1234567811112222"
CHECK1="[arm64] fpcheck OK task=0x0000000000000001 d8=0xCAFEF00D33334444"
TASK0_PASSES="[arm64] task0 fpchecks passed -> 0x0000000000000006"
TASK1_PASSES="[arm64] task1 fpchecks passed -> 0x0000000000000006"
SURVIVED="[arm64] FP state survived context switch"
FP_OK="[arm64] EL0 FP context switch OK"

fail() {
    echo "[test_arm64_phase13] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase13] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase13] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase13_test"
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
# -smp 2 lets the Phase-10/12 SMP demos run before the FP demo. After the demos
# the kernel masks IRQs and spins in WFI, so QEMU keeps running until the timeout
# kills it. All assertions run on the serial log. aarch64 qemu tests are
# load-independent in CORRECTNESS but boot is slow under host load, so use a
# generous timeout.
timeout 240 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase13] captured serial:"
    sed 's/^/[test_arm64_phase13]   | /' "$SERIAL"
}

# Guard against any FP corruption being reported.
if grep -q -F "fpcheck CORRUPT" "$SERIAL"; then
    dump_serial
    fail "an EL0 task read the WRONG FP value after a switch — FP state was NOT preserved"
fi

grep -q "$BANNER"            "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$SCHED_OK"       "$SERIAL" || { dump_serial; fail "Phase-12 SMP scheduling did not complete (Phase 13 not reached) — regression"; }
grep -q -F "$SIG_OK"         "$SERIAL" || { dump_serial; fail "Phase-11 signal demo did not complete (Phase 13 not reached) — regression"; }
grep -q -F "$PHASE13"        "$SERIAL" || { dump_serial; fail "Phase-13 FP demo did not start"; }
grep -q -F "$FPEN"           "$SERIAL" || { dump_serial; fail "CPACR_EL1.FPEN was not enabled"; }
grep -q -F "$LAUNCH"         "$SERIAL" || { dump_serial; fail "EL0 FP tasks were not launched"; }
grep -q -F "$CHECK0"         "$SERIAL" || { dump_serial; fail "task0 never read back its own FP signature"; }
grep -q -F "$CHECK1"         "$SERIAL" || { dump_serial; fail "task1 never read back its own FP signature"; }
grep -q -F "$TASK0_PASSES"   "$SERIAL" || { dump_serial; fail "task0 did not pass FP_YIELD_LIMIT (6) fpchecks"; }
grep -q -F "$TASK1_PASSES"   "$SERIAL" || { dump_serial; fail "task1 did not pass FP_YIELD_LIMIT (6) fpchecks"; }
grep -q -F "$SURVIVED"       "$SERIAL" || { dump_serial; fail "'$SURVIVED' missing"; }
grep -q -F "$FP_OK"          "$SERIAL" || { dump_serial; fail "'$FP_OK' not found (FP context switch did not complete cleanly)"; }

echo "[test_arm64_phase13] boot banner       : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase13] phase 12 OK (regr) : $(grep -F "$SCHED_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase13] phase 11 OK (regr) : $(grep -F "$SIG_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase13] phase 13 start     : $(grep -F "$PHASE13" "$SERIAL" | head -1)"
echo "[test_arm64_phase13] FPEN enabled       : $(grep -F "$FPEN" "$SERIAL" | head -1)"
echo "[test_arm64_phase13] task0 fpchecks     : $(grep -F "$TASK0_PASSES" "$SERIAL" | head -1)"
echo "[test_arm64_phase13] task1 fpchecks     : $(grep -F "$TASK1_PASSES" "$SERIAL" | head -1)"
echo "[test_arm64_phase13] FP survived switch : $(grep -F "$SURVIVED" "$SERIAL" | head -1)"
echo "[test_arm64_phase13] FP switch OK       : $(grep -F "$FP_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase13] PASS"
