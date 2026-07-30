#!/usr/bin/env bash
# scripts/test_arm64_phase12.sh — PHASE 12 multi-arch milestone: SECONDARY-CORE
# SCHEDULING under a real cache-coherent SPINLOCK on bare-metal aarch64.
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
# Builds on Phases 4-11 (EL0 + svc, preemptive scheduling, page-fault reaping,
# per-task TTBR0 isolation, broader syscall surface, page-table brk, SMP
# secondary bring-up, EL0 signal delivery). Phase 10 proved a SECOND CPU comes
# alive via PSCI but then PARKED it in WFE. Phase 12 puts CPU1 to WORK.
#
# After Phase 10 prints "[arm64] SMP bring-up OK", kmain hands off to Phase 12:
#   1. The secondary — instead of parking — turns on ITS OWN MMU using the
#      primary's already-built page tables (so RAM is Cacheable Inner-Shareable
#      Normal memory on BOTH cores, which the global exclusive monitor requires),
#      then spins on a shared "go" flag.
#   2. The primary seeds the shared cells (lock free, counter 0), publishes the
#      "go" flag, and BOTH cores run SMP_ITERS (100000) increments of ONE shared
#      counter, each increment guarded by a single spinlock taken with ldaxr/stlxr
#      (acquire) and freed with stlr (release).
#   3. The primary waits for CPU1 to finish, then verifies the final counter is
#      EXACTLY 2*SMP_ITERS (0x30D40 == 200000). That total is only correct if
#      BOTH cores ran AND the lock prevented every lost update; a missing core or
#      a dropped lock would leave the counter below 200000.
#   4. The primary also checks CPU1 stamped its MPIDR id (1) inside a critical
#      section, proving the second core genuinely executed under the shared lock.
#
# A PASS proves: (a) the secondary runs scheduler work, not just a liveness poke;
# (b) ldaxr/stlxr exclusives are cache-coherent across two real cores with proper
# acquire/release barriers; (c) the contended shared counter reaches its exact
# deterministic total with no lost updates; (d) Phases 4-11 still run to
# completion (no regression — the Phase-9 brk, Phase-10 SMP and Phase-11 signal
# markers all appear).
#
# Prints "[test_arm64_phase12] PASS" on success or "[test_arm64_phase12] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
SMP_OK="[arm64] SMP bring-up OK"
PHASE12="[arm64] Phase 12: secondary-core scheduling under a spinlock"
BOTH_DONE="[arm64] both cores finished"
COUNTER="[arm64] shared counter -> 0x0000000000030D40"
EXPECTED="[arm64] expected         -> 0x0000000000030D40"
CPU1_TOUCH="[arm64] CPU1 touched lock -> 0x0000000000000001"
CPU1_RAN="[arm64] CPU1 ran in scheduler"
LOCK_HELD="[arm64] spinlock held under contention"
SCHED_OK="[arm64] SMP scheduling OK"
SIG_OK="[arm64] EL0 signal delivery OK"

fail() {
    echo "[test_arm64_phase12] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase12] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase12] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase12_test"
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
# CPU_ON and then runs it in the Phase-12 contended-increment loop. After the
# demos the primary masks IRQs and spins in WFI, so QEMU keeps running until the
# timeout kills it. All assertions run on the serial log. aarch64 qemu tests are
# load-independent in CORRECTNESS but boot is slow under host load, so use a
# generous timeout.
timeout 180 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase12] captured serial:"
    sed 's/^/[test_arm64_phase12]   | /' "$SERIAL"
}

grep -q "$BANNER"            "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$SMP_OK"         "$SERIAL" || { dump_serial; fail "Phase-10 SMP bring-up did not complete (Phase 12 not reached) — regression"; }
grep -q -F "$PHASE12"        "$SERIAL" || { dump_serial; fail "Phase-12 secondary-core scheduling did not start"; }
grep -q -F "$BOTH_DONE"      "$SERIAL" || { dump_serial; fail "both cores did not finish (secondary wedged in the work loop?)"; }
grep -q -F "$COUNTER"        "$SERIAL" || { dump_serial; fail "shared counter is not 0x30D40 (200000) — a lost update means the lock dropped or a core did not run"; }
grep -q -F "$EXPECTED"       "$SERIAL" || { dump_serial; fail "expected-total marker missing"; }
grep -q -F "$CPU1_TOUCH"     "$SERIAL" || { dump_serial; fail "CPU1 did not stamp the lock — secondary never entered the critical section"; }
grep -q -F "$CPU1_RAN"       "$SERIAL" || { dump_serial; fail "'$CPU1_RAN' missing"; }
grep -q -F "$LOCK_HELD"      "$SERIAL" || { dump_serial; fail "'$LOCK_HELD' missing"; }
grep -q -F "$SCHED_OK"       "$SERIAL" || { dump_serial; fail "'$SCHED_OK' not found (SMP scheduling did not complete cleanly)"; }
grep -q -F "$SIG_OK"         "$SERIAL" || { dump_serial; fail "Phase-11 signal demo did not complete after Phase 12 — regression"; }

echo "[test_arm64_phase12] boot banner       : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase12] phase 10 OK        : $(grep -F "$SMP_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase12] phase 12 start     : $(grep -F "$PHASE12" "$SERIAL" | head -1)"
echo "[test_arm64_phase12] both cores done    : $(grep -F "$BOTH_DONE" "$SERIAL" | head -1)"
echo "[test_arm64_phase12] shared counter     : $(grep -F "$COUNTER" "$SERIAL" | head -1)"
echo "[test_arm64_phase12] CPU1 touched lock  : $(grep -F "$CPU1_TOUCH" "$SERIAL" | head -1)"
echo "[test_arm64_phase12] CPU1 ran           : $(grep -F "$CPU1_RAN" "$SERIAL" | head -1)"
echo "[test_arm64_phase12] spinlock held      : $(grep -F "$LOCK_HELD" "$SERIAL" | head -1)"
echo "[test_arm64_phase12] scheduling OK      : $(grep -F "$SCHED_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase12] phase 11 OK (regr) : $(grep -F "$SIG_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase12] PASS"
