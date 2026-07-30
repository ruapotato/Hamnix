#!/usr/bin/env bash
# scripts/test_arm64_sched.sh — PHASE 5 multi-arch milestone: the aarch64 kernel
# spine PREEMPTIVELY round-robins TWO EL0 (userspace) tasks, driven by the EL1
# generic-timer IRQ — a real EL0<->EL0 context switch on bare aarch64, all
# orchestrated from Adder.
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
# Builds on Phase 3 (timer IRQ) + Phase 4 (EL0 + svc). After MMU + GICv2 +
# virtual-timer bring-up, kmain:
#   1. Hand-emits two self-looping EL0 tasks into the EL0 RWX window. Each task
#      runs forever: write(1, "[taskN] running on EL0", ...) then a busy-loop.
#      Neither task ever yields or exits.
#   2. Builds a per-task saved-context block (x0..x30 + SP_EL0 + ELR_EL1 +
#      SPSR_EL1) in EL1-only RAM, publishes task 0 as current, and ERETs into
#      it at EL0t WITH IRQs UNMASKED so the timer can preempt it.
#   3. Each timer IRQ traps to the "Lower EL using AArch64" IRQ vector
#      (arm64_lower_irq_entry in vectors.S): it saves the running task's full
#      context into its block, calls the Adder scheduler arm64_sched_pick()
#      (which acks/re-arms the timer and swaps the current-task pointer to the
#      OTHER task), then restores+erets into that task.
#   4. After SWITCH_LIMIT preemptive switches the scheduler prints the PASS
#      marker and halts.
#
# A PASS proves: (a) BOTH EL0 tasks actually executed (both task markers appear
# on the UART), and (b) the EL1 timer IRQ preempted a running EL0 task and
# round-robin context-switched to the other one, repeatedly — a genuine
# preemptive scheduler on bare aarch64 with the policy written in pure Adder.
#
# Prints "[test_arm64_sched] PASS" on success or "[test_arm64_sched] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
LAUNCH="[arm64] launching preemptive EL0 tasks"
TASK0MSG="[task0] running on EL0"
TASK1MSG="[task1] running on EL0"
SWITCHMSG="[arm64] preempt switch"
PASS_MARK="[arm64] EL0 preempt sched OK"

fail() {
    echo "[test_arm64_sched] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_sched] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_sched] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_sched_test"
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

# --- boot under qemu-system-aarch64 ------------------------------------
# The scheduler masks IRQs and spins in WFI after the PASS, so QEMU keeps
# running until the timeout kills it (exit 124). Assertions run on the serial
# log. This test is load-independent (no virtio-blk), safe under concurrency.
timeout 30 "$QEMU" \
    -M virt -cpu cortex-a72 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_sched] captured serial:"
    sed 's/^/[test_arm64_sched]   | /' "$SERIAL"
}

grep -q "$BANNER"        "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$LAUNCH"     "$SERIAL" || { dump_serial; fail "task-launch marker not found"; }
grep -q -F "$TASK0MSG"   "$SERIAL" || { dump_serial; fail "task0 never ran on EL0"; }
grep -q -F "$TASK1MSG"   "$SERIAL" || { dump_serial; fail "task1 never ran on EL0"; }
grep -q -F "$PASS_MARK"  "$SERIAL" || { dump_serial; fail "'$PASS_MARK' not found"; }

# Require MULTIPLE preemptive switches: a single switch could be a fluke; the
# spine must round-robin both tasks repeatedly.
SWITCHES="$(grep -c -F "$SWITCHMSG" "$SERIAL")"
[ "$SWITCHES" -ge 2 ] || { dump_serial; fail "expected >=2 preempt switches, saw $SWITCHES"; }

echo "[test_arm64_sched] boot banner    : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_sched] task0 ran       : $(grep -F "$TASK0MSG" "$SERIAL" | head -1)"
echo "[test_arm64_sched] task1 ran       : $(grep -F "$TASK1MSG" "$SERIAL" | head -1)"
echo "[test_arm64_sched] preempt switches: $SWITCHES"
echo "[test_arm64_sched] sched marker    : $(grep -F "$PASS_MARK" "$SERIAL" | head -1)"
echo "[test_arm64_sched] PASS"
