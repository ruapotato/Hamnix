#!/usr/bin/env bash
# scripts/test_arm64_baremetal.sh — PHASE 2 multi-arch milestone: a
# standalone aarch64 kernel image, compiled from Adder, that BOOTS on
# QEMU's `virt` machine and prints a banner over the PL011 UART.
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
#   1. Compile arch/arm64/kmain.ad with --target=aarch64-bare-metal. The
#      arm64 codegen runs in bare_metal mode (no Linux _start/exit wrapper);
#      the compiler links the emitted .S with the hand-written boot stub
#      arch/arm64/boot.S using arch/arm64/kernel.lds, producing a freestanding
#      ELF whose entry point is QEMU virt's -kernel load address (0x40080000).
#   2. Boot it under qemu-system-aarch64 -M virt -cpu cortex-a72 -nographic
#      -kernel <image>, with a timeout, capturing the serial console.
#   3. Assert the captured serial output contains the boot banner.
#
# A PASS proves Adder code RUNS on bare aarch64 (no OS, no libc) and drives
# real MMIO — the foundational Phase 2 milestone. The MMU/GDT/scheduler port
# is a later phase and deliberately NOT exercised here.
#
# Prints "[ARM64-BM] PASS" on success or "[ARM64-BM] FAIL ..." on failure.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"

fail() {
    echo "[ARM64-BM] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[ARM64-BM] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[ARM64-BM] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_baremetal_test"
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
# -M virt + -cpu cortex-a72: QEMU loads -kernel at 0x40080000 and the PL011
# UART lives at 0x09000000 (where kmain writes). -nographic routes the UART
# to stdio. We give it a short wall-clock budget; the stub prints and halts
# in a wfi loop, so QEMU keeps running until the timeout kills it. Output is
# redirected to a file we read AFTER the run rather than piped through grep.
timeout 15 "$QEMU" \
    -M virt -cpu cortex-a72 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1
# timeout returns 124 when it kills QEMU — expected, since the stub never
# exits. Any other inspection happens via the captured serial log below.

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

if ! grep -q "$BANNER" "$SERIAL"; then
    echo "[ARM64-BM] captured serial:"
    sed 's/^/[ARM64-BM]   | /' "$SERIAL"
    fail "expected banner '$BANNER' not found in serial output"
fi

echo "[ARM64-BM] serial banner : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[ARM64-BM] PASS"
