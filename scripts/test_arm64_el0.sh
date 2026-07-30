#!/usr/bin/env bash
# scripts/test_arm64_el0.sh — PHASE 4 multi-arch milestone: the aarch64 kernel
# spine drops from EL1 to EL0 (userspace) and services a real `svc #0` syscall
# path, all driven from Adder.
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
# Builds on Phase 3 (test_arm64_irq.sh): after the MMU + GICv2 + virtual-timer
# bring-up runs to completion ("[arm64] timer IRQ OK"), kmain proceeds to:
#   1. Materialise a tiny hand-emitted AArch64 routine into an identity-mapped
#      RAM page (write(1,msg,len) then exit(0), Linux aarch64 ABI: x8=nr,
#      x0..x5=args, return in x0).
#   2. Program SPSR_EL1 (EL0t + DAIF), ELR_EL1 (user entry), SP_EL0 (user
#      stack) and `eret` to EL0.
#   3. The EL0 `svc #0` traps to the "Lower EL using AArch64" Synchronous
#      vector (offset 0x400 in vectors.S), which saves the x0..x30 frame and
#      calls the Adder dispatcher arm64_sync_handler(frame_ptr). It reads
#      ESR_EL1.EC to confirm SVC, services nr 64 (write -> UART) and nr 93
#      (exit), writes the return value back into the frame's x0 slot, and erets.
#
# A PASS proves the full EL1->EL0->svc->EL1->eret round trip works on bare
# aarch64 (no OS, no libc), with the syscall dispatcher written in pure Adder.
#
# Prints "[test_arm64_el0] PASS" on success or "[test_arm64_el0] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
DROP="[arm64] dropping to EL0"
USERMSG="Hello from EL0 via svc write"
WRITE_OK="[arm64] EL0 write syscall serviced"
EXIT_OK="[arm64] EL0 exit syscall serviced"
PASS_MARK="[arm64] EL0 syscall OK"

fail() {
    echo "[test_arm64_el0] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_el0] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_el0] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_el0_test"
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
# The EL0 exit syscall masks IRQs and spins in WFI, so QEMU keeps running until
# the timeout kills it (exit 124). All assertions run against the serial log.
timeout 25 "$QEMU" \
    -M virt -cpu cortex-a72 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_el0] captured serial:"
    sed 's/^/[test_arm64_el0]   | /' "$SERIAL"
}

grep -q "$BANNER"   "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$DROP"  "$SERIAL" || { dump_serial; fail "EL0 drop marker not found"; }
grep -q -F "$USERMSG" "$SERIAL" || { dump_serial; fail "EL0 write-syscall payload '$USERMSG' not found"; }
grep -q -F "$WRITE_OK" "$SERIAL" || { dump_serial; fail "write syscall service marker not found"; }
grep -q -F "$EXIT_OK"  "$SERIAL" || { dump_serial; fail "exit syscall service marker not found"; }
grep -q -F "$PASS_MARK" "$SERIAL" || { dump_serial; fail "'$PASS_MARK' not found"; }

echo "[test_arm64_el0] boot banner   : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_el0] EL0 payload    : $(grep -F "$USERMSG" "$SERIAL" | head -1)"
echo "[test_arm64_el0] write serviced : $(grep -F "$WRITE_OK" "$SERIAL" | head -1)"
echo "[test_arm64_el0] exit serviced  : $(grep -F "$EXIT_OK" "$SERIAL" | head -1)"
echo "[test_arm64_el0] el0 marker     : $(grep -F "$PASS_MARK" "$SERIAL" | head -1)"
echo "[test_arm64_el0] PASS"
