#!/usr/bin/env bash
# scripts/test_arm64_phase24.sh — PHASE 24 multi-arch milestone: EL0 DEMAND PAGING
# across a fresh, wholly-unmapped VA window on bare aarch64.
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
# Phase 14 proved the demand-paging MECHANISM on two hard-coded VAs. Phase 24
# generalises it to a real multi-page window: a 2 MiB EL0 window (VA 0x4220_0000,
# L2 index 17, above Phase 23's TLS VA) is left ENTIRELY unmapped — its L2 slot is
# zero, no L3 table — so the FIRST touch of EACH of N=4 distinct pages raises an
# independent translation Data Abort from EL0. The SAME EL1 synchronous handler
# decodes ESR_EL1 (EC == 0x24 Data Abort from a lower EL; DFSC == 0b0001xx
# translation fault), allocates a fresh physical page from a small per-phase pool,
# installs its L3 PTE with EL0 RW permissions, invalidates ONLY that page's stale
# translation (tlbi vaae1is + dsb/isb), and returns WITHOUT advancing ELR so the
# faulting store/load RETRIES and completes transparently.
#
# The EL0 demo walks 4 distinct pages across the window, writes a per-page
# sentinel to each, reads them all back, and hands the read-backs to the kernel,
# which verifies every value AND that exactly 4 faults were serviced AND that no
# fault fired OUTSIDE the window (real bugs stay fatal).
#
# Phase 24 runs only AFTER Phase 23 prints its PASS marker (the hand-off point),
# so every prior phase (4..23) must still run to completion (no regression).
#
# Prints "[test_arm64_phase24] PASS" on success or "[test_arm64_phase24] FAIL ...".

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
P23_OK="[arm64] EL0 thread-local storage (TPIDR_EL0) scheduling OK"

PHASE24="[arm64] Phase 24: EL0 demand paging across an unmapped VA window"
LAUNCH="[arm64] launching EL0 demand-paging window task (4 pages)"
FAULT="[arm64] Phase 24 demand fault: paged in VA "
SERVICED="[arm64] Phase 24 demand-paging: 0x0000000000000004 faults serviced"
FAULTED_IN="[arm64] Phase 24 first-touch pages faulted in on demand across the window"
P24_PASS="[arm64] Phase 24 PASS"

fail() {
    echo "[test_arm64_phase24] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase24] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase24] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase24_test"
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
    echo "[test_arm64_phase24] captured serial:"
    sed 's/^/[test_arm64_phase24]   | /' "$SERIAL"
}

# --- guard against any explicit failure markers ------------------------
if grep -q -F "Phase 24 demand-paging FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-24 demand-paging reported FAIL"
fi
if grep -q -F "unknown syscall (phase 24)" "$SERIAL"; then
    dump_serial
    fail "Phase-24 task issued an unexpected syscall"
fi
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort paniced the kernel"
fi
if grep -q -F "EL0 non-SVC sync exception" "$SERIAL"; then
    dump_serial
    fail "an unexpected EL0 non-SVC sync exception fired (a demand fault was not serviced)"
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
grep -q -F "$P22_OK"     "$SERIAL" || { dump_serial; fail "Phase-22 futex wait/wake did not complete — regression"; }
grep -q -F "$P23_OK"     "$SERIAL" || { dump_serial; fail "Phase-23 thread-local storage did not complete (Phase 24 not reached) — regression"; }

# --- Phase 24 assertions ----------------------------------------------
grep -q -F "$PHASE24" "$SERIAL" || { dump_serial; fail "Phase-24 demo did not start"; }
grep -q -F "$LAUNCH"  "$SERIAL" || { dump_serial; fail "Phase-24 did not launch the demand-paging window task"; }

# Exactly 4 distinct demand faults must have been serviced (one per page).
NFAULTS="$(grep -c -F "$FAULT" "$SERIAL")"
[ "$NFAULTS" -eq 4 ] || { dump_serial; fail "expected exactly 4 demand faults, saw $NFAULTS"; }

# All 4 page VAs must have been paged in on first touch.
for OFF in 0 1 2 3; do
    VA="$(printf '0x%016x' $((0x42200000 + OFF * 0x1000)))"
    grep -q -F "${FAULT}${VA}" "$SERIAL" || { dump_serial; fail "page at $VA was not demand-paged"; }
done

# The kernel's fault-count + PASS summary lines.
grep -q -F "$SERVICED"   "$SERIAL" || { dump_serial; fail "'$SERVICED' not found (wrong serviced-fault count)"; }
grep -q -F "$FAULTED_IN"  "$SERIAL" || { dump_serial; fail "'$FAULTED_IN' missing (demand-window invariant not proven)"; }
grep -q -F "$P24_PASS"   "$SERIAL" || { dump_serial; fail "'$P24_PASS' not found (Phase 24 did not complete cleanly)"; }

echo "[test_arm64_phase24] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase24] phase 23 OK (regr)    : $(grep -F "$P23_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase24] phase 24 start        : $(grep -F "$PHASE24" "$SERIAL" | head -1)"
echo "[test_arm64_phase24] launch                : $(grep -F "$LAUNCH" "$SERIAL" | head -1)"
echo "[test_arm64_phase24] demand faults         : $NFAULTS (== 4)"
echo "[test_arm64_phase24] faults serviced       : $(grep -F "$SERVICED" "$SERIAL" | head -1)"
echo "[test_arm64_phase24] window invariant held : $(grep -F "$FAULTED_IN" "$SERIAL" | head -1)"
echo "[test_arm64_phase24] phase 24 PASS line    : $(grep -F "$P24_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase24] PASS"
