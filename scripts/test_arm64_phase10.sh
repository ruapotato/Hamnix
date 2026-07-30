#!/usr/bin/env bash
# scripts/test_arm64_phase10.sh — PHASE 10 multi-arch milestone: SMP
# SECONDARY-CORE BRING-UP via PSCI on bare-metal aarch64, driven from Adder.
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
# Builds on Phases 4-9 (EL0 + svc, preemptive scheduling, page-fault reaping,
# per-task TTBR0 isolation, broader syscall surface, page-table-backed brk). The
# aarch64 port was single-core; Phase 10 brings up a SECOND CPU.
#
# qemu-virt with `-smp 2` starts the secondary CPU POWERED OFF; it is released
# only by a PSCI CPU_ON call (HVC conduit on the default `-M virt` machine, which
# enters the OS at EL1 with no EL3 firmware). After Phase 9 prints its PASS
# marker ("[arm64] EL0 page-table brk OK"), kmain hands off to Phase 10:
#   1. The primary hand-emits a secondary entry trampoline (set SP, branch to the
#      Adder body) into a RAM page and seeds shared cells (online-CPU counter = 1,
#      cross-core sentinel = 0).
#   2. The primary issues PSCI CPU_ON (func id 0xC4000003) targeting CPU1, with
#      the trampoline's physical address as the entry point.
#   3. The secondary runs arm64_secondary_main() MMU-off at EL1 on CPU1: it
#      enables its own GIC CPU interface, publishes a sentinel (0x5A5A5A5A) to the
#      shared cell with a dmb ish, increments the online-CPU counter (ordered by
#      dmb ish), then parks.
#   4. The primary spins (dmb ish + reload) until the counter reaches 2 and reads
#      back the sentinel, then prints "[arm64] CPU1 online" + "[arm64] SMP bring-up
#      OK". The sentinel handshake proves REAL cross-core progress at a shared VA.
#
# A PASS proves: (a) PSCI CPU_ON via HVC actually powers on a second core on
# qemu-virt; (b) the secondary executes Adder code on its own stack; (c) the two
# cores share coherent memory with proper barriers (the primary observes the
# secondary's sentinel and counter increment); (d) Phases 4-9 still run to
# completion first (no regression).
#
# Prints "[test_arm64_phase10] PASS" on success or "[test_arm64_phase10] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
BRK_OK="[arm64] EL0 page-table brk OK"
PHASE10="[arm64] Phase 10: SMP secondary-core bring-up via PSCI"
CPU_ON_ISSUED="[arm64] PSCI CPU_ON issued"
SECONDARY_ENTERED="[arm64] secondary core entered"
CPU1_ONLINE="[arm64] CPU1 online"
CPU1_SENTINEL="[arm64] CPU1 sentinel -> 0x000000005A5A5A5A"
SMP_OK="[arm64] SMP bring-up OK"

fail() {
    echo "[test_arm64_phase10] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase10] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase10] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase10_test"
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
# -smp 2 starts a second CPU powered off; the kernel releases it via PSCI
# CPU_ON. After the SMP demo the primary masks IRQs and spins in WFI, so QEMU
# keeps running until the timeout kills it. All assertions run on the serial
# log. This test uses no virtio-blk and is load-independent, safe under
# concurrency.
timeout 90 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase10] captured serial:"
    sed 's/^/[test_arm64_phase10]   | /' "$SERIAL"
}

grep -q "$BANNER"             "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$BRK_OK"          "$SERIAL" || { dump_serial; fail "Phase-9 brk did not complete (Phase 10 not reached) — regression"; }
grep -q -F "$PHASE10"         "$SERIAL" || { dump_serial; fail "Phase-10 SMP bring-up did not start"; }
grep -q -F "$CPU_ON_ISSUED"   "$SERIAL" || { dump_serial; fail "PSCI CPU_ON did not return SUCCESS"; }
grep -q -F "$SECONDARY_ENTERED" "$SERIAL" || { dump_serial; fail "secondary core never entered its Adder body"; }
grep -q -F "$CPU1_ONLINE"     "$SERIAL" || { dump_serial; fail "secondary never reported online (counter did not reach 2)"; }
grep -q -F "$CPU1_SENTINEL"   "$SERIAL" || { dump_serial; fail "primary did not observe the cross-core sentinel"; }
grep -q -F "$SMP_OK"          "$SERIAL" || { dump_serial; fail "'$SMP_OK' not found (SMP bring-up did not complete cleanly)"; }

echo "[test_arm64_phase10] boot banner     : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase10] phase 9 OK       : $(grep -F "$BRK_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase10] phase 10 start   : $(grep -F "$PHASE10" "$SERIAL" | head -1)"
echo "[test_arm64_phase10] CPU_ON issued    : $(grep -F "$CPU_ON_ISSUED" "$SERIAL" | head -1)"
echo "[test_arm64_phase10] secondary entered: $(grep -F "$SECONDARY_ENTERED" "$SERIAL" | head -1)"
echo "[test_arm64_phase10] CPU1 online      : $(grep -F "$CPU1_ONLINE" "$SERIAL" | head -1)"
echo "[test_arm64_phase10] CPU1 sentinel    : $(grep -F "$CPU1_SENTINEL" "$SERIAL" | head -1)"
echo "[test_arm64_phase10] PASS"
