#!/usr/bin/env bash
# scripts/test_arm64_phase11.sh — PHASE 11 multi-arch milestone: EL0 SIGNAL
# DELIVERY on bare-metal aarch64, driven from Adder.
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
# Builds on Phases 4-10 (EL0 + svc, preemptive scheduling, page-fault reaping,
# per-task TTBR0 isolation, broader syscall surface, page-table-backed brk, SMP
# secondary-core bring-up). Phase 11 adds the missing signal-delivery path,
# mirroring the x86 signal machinery on aarch64.
#
# After Phase 10 prints its PASS marker ("[arm64] SMP bring-up OK"), the PRIMARY
# hands off to Phase 11:
#   1. A single EL0 task issues a kernel-private raise() syscall (x8 = 520).
#   2. The kernel saves the interrupted EL0 context (resume PC = ELR_EL1, stack =
#      SP_EL0, plus a sentinel x0) into a SIGNAL FRAME it pushes onto the task's
#      OWN EL0 stack, redirects ELR_EL1 to a user signal HANDLER, places the
#      signal token in x0, lowers SP_EL0 past the frame, and ERETs into EL0.
#   3. The EL0 handler runs (it reports in via sighandler_ran(), x8 = 521, passing
#      the signal token back so the kernel can confirm it arrived intact), then
#      branches to a sigreturn TRAMPOLINE.
#   4. The trampoline issues sigreturn() (x8 = 522). The kernel reads the saved
#      frame back off the EL0 stack, confirms it matches what raise() saved,
#      restores ELR_EL1 + SP_EL0 + x0, and ERETs back to EXACTLY where raise()
#      left off — the instruction after the original raise svc.
#   5. The resumed mainline write()s a "resumed" marker and exit(0)s. On a clean
#      round trip (frame delivered, handler ran with the right token, sigreturn
#      restored + resumed) the kernel prints "[arm64] EL0 signal delivery OK".
#
# A PASS proves: (a) the kernel builds a signal frame on a live EL0 stack and
# redirects the EL0 task into a user handler; (b) the handler executes purely in
# EL0 and the kernel observes its report with the correct signal token; (c)
# sigreturn restores the interrupted context and resumes the mainline at the
# exact resume PC; (d) Phases 4-10 still run to completion first (no regression).
#
# Prints "[test_arm64_phase11] PASS" on success or "[test_arm64_phase11] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
SMP_OK="[arm64] SMP bring-up OK"
PHASE11="[arm64] Phase 11: EL0 signal delivery"
RAISE="[arm64] EL0 raise() -> delivering signal"
FRAME_PUSHED="[arm64] signal frame pushed; resume PC="
REDIRECTED="[arm64] redirected EL0 to signal handler"
HANDLER_RAN="[arm64] EL0 signal handler ran; token=0x0000000000000011"
SIGRETURN="[arm64] EL0 sigreturn() -> restoring context"
FRAME_MATCH="[arm64] sigreturn frame matched saved context OK"
RESUME="[arm64] resuming interrupted EL0 mainline; PC="
RESUMED_MSG="Resumed EL0 mainline after signal handler"
SIG_OK="[arm64] EL0 signal delivery OK"

fail() {
    echo "[test_arm64_phase11] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase11] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase11] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase11_test"
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
# -smp 2 starts a second CPU powered off; the kernel releases it via PSCI in
# Phase 10 before handing off to the Phase 11 signal demo. After Phase 11 the
# primary masks IRQs and spins in WFI, so QEMU keeps running until the timeout
# kills it. All assertions run on the serial log; this test uses no virtio-blk
# and is load-independent (boot is slow under load, hence the long timeout).
timeout 120 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase11] captured serial:"
    sed 's/^/[test_arm64_phase11]   | /' "$SERIAL"
}

grep -q "$BANNER"            "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$SMP_OK"         "$SERIAL" || { dump_serial; fail "Phase-10 SMP did not complete (Phase 11 not reached) — regression"; }
grep -q -F "$PHASE11"        "$SERIAL" || { dump_serial; fail "Phase-11 signal delivery did not start"; }
grep -q -F "$RAISE"          "$SERIAL" || { dump_serial; fail "EL0 raise() was not serviced"; }
grep -q -F "$FRAME_PUSHED"   "$SERIAL" || { dump_serial; fail "kernel did not push a signal frame"; }
grep -q -F "$REDIRECTED"     "$SERIAL" || { dump_serial; fail "kernel did not redirect EL0 to the handler"; }
grep -q -F "$HANDLER_RAN"    "$SERIAL" || { dump_serial; fail "EL0 signal handler did not run (or wrong token)"; }
grep -q -F "$SIGRETURN"      "$SERIAL" || { dump_serial; fail "EL0 sigreturn() was not serviced"; }
grep -q -F "$FRAME_MATCH"    "$SERIAL" || { dump_serial; fail "sigreturn frame did not match the saved context"; }
grep -q -F "$RESUME"         "$SERIAL" || { dump_serial; fail "kernel did not resume the interrupted mainline"; }
grep -q -F "$RESUMED_MSG"    "$SERIAL" || { dump_serial; fail "resumed mainline did not run its write()"; }
grep -q -F "$SIG_OK"         "$SERIAL" || { dump_serial; fail "'$SIG_OK' not found (signal round trip did not complete cleanly)"; }

echo "[test_arm64_phase11] boot banner      : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase11] phase 10 OK        : $(grep -F "$SMP_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase11] phase 11 start     : $(grep -F "$PHASE11" "$SERIAL" | head -1)"
echo "[test_arm64_phase11] raise serviced     : $(grep -F "$RAISE" "$SERIAL" | head -1)"
echo "[test_arm64_phase11] frame pushed       : $(grep -F "$FRAME_PUSHED" "$SERIAL" | head -1)"
echo "[test_arm64_phase11] handler ran        : $(grep -F "$HANDLER_RAN" "$SERIAL" | head -1)"
echo "[test_arm64_phase11] sigreturn serviced : $(grep -F "$SIGRETURN" "$SERIAL" | head -1)"
echo "[test_arm64_phase11] frame matched      : $(grep -F "$FRAME_MATCH" "$SERIAL" | head -1)"
echo "[test_arm64_phase11] mainline resumed   : $(grep -F "$RESUME" "$SERIAL" | head -1)"
echo "[test_arm64_phase11] PASS"
