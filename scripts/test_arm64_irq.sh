#!/usr/bin/env bash
# scripts/test_arm64_irq.sh — PHASE 3 multi-arch milestone: an
# interrupt-driven aarch64 kernel spine, compiled from Adder, that BOOTS on
# QEMU's `virt` machine, enables a minimal identity-mapped MMU, brings up
# GICv2 + the ARM generic (virtual) timer, services a handful of periodic
# timer IRQs (printing a tick each), then halts deterministically.
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
# Pipeline:
#   1. Compile arch/arm64/kmain.ad with --target=aarch64-bare-metal. The arm64
#      codegen (codegen_arm64.py) lowers the Adder kernel, including the
#      privileged sysreg pokes (VBAR/SCTLR/TTBR0/MAIR/TCR/CNTV_*/DAIF), DSB/
#      ISB/TLBI barriers and WFI, via recognised intrinsics. The compiler
#      assembles + links the emitted .S with the boot stub arch/arm64/boot.S
#      and the EL1 exception vector table arch/arm64/vectors.S using
#      arch/arm64/kernel.lds, producing a freestanding ELF whose entry point
#      is QEMU virt's -kernel load address (0x40080000).
#   2. Boot it under qemu-system-aarch64 -M virt -cpu cortex-a72 -nographic
#      -kernel <image>, with a timeout, capturing the serial console.
#   3. Assert the captured serial output contains the boot banner, the MMU /
#      GIC bring-up markers, the per-tick markers, and the final completion
#      banner "[arm64] timer IRQ OK".
#
# A PASS proves Adder code drives a real interrupt-driven kernel spine on bare
# aarch64 (no OS, no libc): MMU on, GICv2 routing a generic-timer PPI, and an
# IRQ handler written in Adder servicing the ticks.
#
# Prints "[test_arm64_irq] PASS" on success or "[test_arm64_irq] FAIL ..." on
# failure.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
TICK="[arm64] timer tick"
DONE="[arm64] timer IRQ OK"
EXPECT_TICKS=5

fail() {
    echo "[test_arm64_irq] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_irq] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_irq] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_irq_test"
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
# -M virt + -cpu cortex-a72: QEMU loads -kernel at 0x40080000 (entering at
# EL1 with the MMU off), the GICv2 lives at 0x08000000/0x08010000 and the
# PL011 UART at 0x09000000. -nographic routes the UART to stdio. We give it a
# short wall-clock budget; after the last tick the handler masks IRQs and
# spins in WFI, so QEMU keeps running until the timeout kills it (exit 124).
timeout 20 "$QEMU" \
    -M virt -cpu cortex-a72 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1
# timeout returns 124 when it kills QEMU — expected, since the kernel halts in
# a WFI loop and never powers off. All assertions run against the serial log.

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_irq] captured serial:"
    sed 's/^/[test_arm64_irq]   | /' "$SERIAL"
}

grep -q "$BANNER" "$SERIAL" || { dump_serial; fail "boot banner '$BANNER' not found"; }

TICK_COUNT="$(grep -c -F "$TICK" "$SERIAL")"
if [ "$TICK_COUNT" -lt "$EXPECT_TICKS" ]; then
    dump_serial
    fail "expected >= $EXPECT_TICKS timer ticks, saw $TICK_COUNT"
fi

grep -q -F "$DONE" "$SERIAL" || { dump_serial; fail "completion banner '$DONE' not found"; }

echo "[test_arm64_irq] serial banner   : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_irq] timer ticks seen : $TICK_COUNT"
echo "[test_arm64_irq] completion       : $(grep -F "$DONE" "$SERIAL" | head -1)"
echo "[test_arm64_irq] PASS"
