#!/usr/bin/env bash
# scripts/test_arm64_phase23.sh — PHASE 23 multi-arch milestone: EL0 THREAD-LOCAL
# STORAGE via TPIDR_EL0 (the AArch64 TLS ABI thread pointer) + a SETTLS syscall,
# saved+restored PER-THREAD across every preemptive context switch, on bare
# aarch64. This is the register+scheduler wiring that makes pthread-style TLS real
# on arm64.
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
# Every prior phase shared one address space's translation per task but none gave
# a task a PER-THREAD register identity. Phase 23 proves it: two preemptively-
# scheduled EL0 threads in private ASID-tagged spaces (slot A ASID 11, slot B ASID
# 12) run the IDENTICAL EL0 code. Each thread installs its OWN thread pointer once
# with SETTLS (the kernel writes TPIDR_EL0 and records it on the slot), then loops
# reading its thread-local sentinel with a BARE `mrs tpidr_el0; ldrb` — NO syscall
# — and reports it. The mapping is the same TLS VA in both spaces but it resolves,
# through each slot's own TTBR0+ASID, to a DIFFERENT private physical TLS block
# seeded with a DIFFERENT sentinel (A=0xA1, B=0xB2).
#
# CRUX: the scheduler SAVES the outgoing thread's TPIDR_EL0 and RESTORES the
# incoming thread's on every timer tick. A PASS requires BOTH threads installed a
# TLS pointer (settls), BOTH read their OWN thread-local sentinel through
# TPIDR_EL0 (no syscall), the scheduler preserved each thread's DISTINCT TPIDR_EL0
# across MANY switches (tls_split_switches > 0), and ZERO cross-thread TLS leaks
# occurred (no thread ever read the other thread's sentinel).
#
# Phase 23 runs only AFTER Phase 22 prints its PASS marker (the hand-off point),
# so every prior phase (4..22) must still run to completion (no regression).
#
# Prints "[test_arm64_phase23] PASS" on success or "[test_arm64_phase23] FAIL ...".

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
P22_OK="[arm64] EL0 futex wait/wake scheduling OK"

PHASE23="[arm64] Phase 23: EL0 thread-local storage (TPIDR_EL0 / SETTLS, per-thread, scheduler-preserved)"
LAUNCH="[arm64] launching tls-demo EL0 threads (slot A ASID 11, slot B ASID 12)"
SWAP="[arm64] tls-demo TPIDR_EL0-preserving swap"
REPORT="[arm64] tls-demo report: slot "
SETTLS="[arm64] tls-demo: slot "
SURVIVED="[arm64] tls-demo: both threads installed a TPIDR_EL0 + read their OWN thread-local sentinel; scheduler preserved each thread pointer across switches"
P23_OK="[arm64] EL0 thread-local storage (TPIDR_EL0) scheduling OK"

fail() {
    echo "[test_arm64_phase23] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase23] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase23] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase23_test"
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
    echo "[test_arm64_phase23] captured serial:"
    sed 's/^/[test_arm64_phase23]   | /' "$SERIAL"
}

# --- guard against any explicit failure markers ------------------------
if grep -q -F "thread-local storage scheduling FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-23 thread-local storage scheduling reported FAIL"
fi
if grep -q -F "tls-demo LEAK" "$SERIAL"; then
    dump_serial
    fail "a thread read ANOTHER thread's TLS sentinel — TPIDR_EL0 was not preserved across a switch"
fi
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort paniced the kernel"
fi
if grep -q -F "unknown syscall (phase 23)" "$SERIAL"; then
    dump_serial
    fail "Phase-23 thread issued an unexpected syscall"
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
grep -q -F "$P21_OK"     "$SERIAL" || { dump_serial; fail "Phase-21 nanosleep block/wake did not complete — regression"; }
grep -q -F "$P22_OK"     "$SERIAL" || { dump_serial; fail "Phase-22 futex wait/wake did not complete (Phase 23 not reached) — regression"; }

# --- Phase 23 assertions ----------------------------------------------
grep -q -F "$PHASE23" "$SERIAL" || { dump_serial; fail "Phase-23 demo did not start"; }
grep -q -F "$LAUNCH"  "$SERIAL" || { dump_serial; fail "Phase-23 did not launch the two tls-demo EL0 threads"; }

# Both threads must have INSTALLED a thread pointer via SETTLS (the TLS-install pillar).
grep -q -F "${SETTLS}0x0000000000000000 SETTLS -> TPIDR_EL0=" "$SERIAL" || { dump_serial; fail "slot A never installed a TPIDR_EL0 via SETTLS"; }
grep -q -F "${SETTLS}0x0000000000000001 SETTLS -> TPIDR_EL0=" "$SERIAL" || { dump_serial; fail "slot B never installed a TPIDR_EL0 via SETTLS"; }

# Both threads must have read their OWN thread-local sentinel through TPIDR_EL0.
grep -q -F "${REPORT}0x0000000000000000 read TLS sentinel value=0x00000000000000A1" "$SERIAL" || { dump_serial; fail "slot A never read its OWN thread-local sentinel (0xA1) through TPIDR_EL0"; }
grep -q -F "${REPORT}0x0000000000000001 read TLS sentinel value=0x00000000000000B2" "$SERIAL" || { dump_serial; fail "slot B never read its OWN thread-local sentinel (0xB2) through TPIDR_EL0"; }

# MANY preemptive TPIDR_EL0-preserving swaps (the scheduler keeps round-robining).
NSWAPS="$(grep -c -F "$SWAP" "$SERIAL")"
[ "$NSWAPS" -ge 8 ] || { dump_serial; fail "expected at least 8 TPIDR_EL0-preserving swaps, saw $NSWAPS"; }

# The full invariant (both-installed + both-read-own + split-TLS-preserved +
# zero-leak) is asserted by the SURVIVED summary line, which only prints when all
# hold, and the final OK marker.
grep -q -F "$SURVIVED" "$SERIAL" || { dump_serial; fail "'$SURVIVED' missing (both-installed + both-read-own + split-TLS-preserved + zero-leak invariant not proven)"; }
grep -q -F "$P23_OK"   "$SERIAL" || { dump_serial; fail "'$P23_OK' not found (Phase 23 did not complete cleanly)"; }

echo "[test_arm64_phase23] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase23] phase 22 OK (regr)    : $(grep -F "$P22_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase23] phase 23 start        : $(grep -F "$PHASE23" "$SERIAL" | head -1)"
echo "[test_arm64_phase23] launch                : $(grep -F "$LAUNCH" "$SERIAL" | head -1)"
echo "[test_arm64_phase23] slot A settls         : $(grep -F "${SETTLS}0x0000000000000000 SETTLS" "$SERIAL" | head -1)"
echo "[test_arm64_phase23] slot B settls         : $(grep -F "${SETTLS}0x0000000000000001 SETTLS" "$SERIAL" | head -1)"
echo "[test_arm64_phase23] slot A TLS read       : $(grep -F "${REPORT}0x0000000000000000 read TLS" "$SERIAL" | head -1)"
echo "[test_arm64_phase23] slot B TLS read       : $(grep -F "${REPORT}0x0000000000000001 read TLS" "$SERIAL" | head -1)"
echo "[test_arm64_phase23] TPIDR-preserving swaps: $NSWAPS (>= 8)"
echo "[test_arm64_phase23] tallies               : $(grep -F "tls-demo swaps=" "$SERIAL" | head -1)"
echo "[test_arm64_phase23] invariant held        : $(grep -F "$SURVIVED" "$SERIAL" | head -1)"
echo "[test_arm64_phase23] tls sched OK          : $(grep -F "$P23_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase23] PASS"
