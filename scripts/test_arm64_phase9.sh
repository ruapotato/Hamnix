#!/usr/bin/env bash
# scripts/test_arm64_phase9.sh — PHASE 9 multi-arch milestone: PAGE-TABLE-BACKED
# brk GROWTH for EL0 on bare-metal aarch64, driven from Adder.
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
# Builds on Phase 4 (EL0 + svc write/exit), Phase 5 (preemptive scheduling),
# Phase 6 (EL0 page-fault reaping), Phase 7 (per-task TTBR0 isolation) and
# Phase 8 (broader EL0 syscall surface). After Phase 8 prints its PASS marker
# ("[arm64] EL0 syscall surface OK"), kmain hands off to Phase 9.
#
# Phase 8's brk() merely bumped a pointer inside an ALREADY-mapped 2 MiB EL0
# window, so a store to the "grown" address would have worked even without the
# brk. Phase 9 makes brk() do REAL memory management: the heap lives at a virtual
# address (0x40C0_0000) whose L2 slot is UNMAPPED at boot. A single EL0 task:
#   brk(0)             -> queries the initial (unmapped) break
#   brk(BASE + 4 KiB)  -> the kernel allocates a fresh physical page and INSTALLS
#                         a new L3 page descriptor (+ L2->L3 table descriptor)
#                         into the live TTBR0_EL1 tables, with break-before-make
#                         TLB maintenance, then returns the new break
#   str/ldr sentinel   -> stores 0xC9C9C9C9 through the NEW mapping and reads it
#                         back (this store succeeds ONLY because the page is now
#                         mapped EL0-RW)
#   brk_report(value)  -> hands the read-back value to the kernel, which verifies
#                         both the reported value AND the BACKING PHYSICAL page
#                         hold the sentinel (proving the translation reached the
#                         page the kernel mapped)
#   write(1, msg, len) -> echoes a buffer to the UART
#   exit(0)            -> records the code and halts after the Phase-9 PASS marker
#
# A PASS proves: (a) the kernel grows the program break by MAPPING a fresh page
# into the faulting task's TTBR0 page tables on demand; (b) the new translation
# is live to EL0 (the store/load succeed); (c) the data actually landed in the
# physical page the kernel allocated; (d) the kernel stays alive and halts
# cleanly on exit(0).
#
# Prints "[test_arm64_phase9] PASS" on success or "[test_arm64_phase9] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
SURFACE_OK="[arm64] EL0 syscall surface OK"
PHASE9="[arm64] Phase 9: page-table-backed brk growth"
BRK_QUERY="[arm64] EL0 brk(9) query -> 0x0000000040C00000"
BRK_GROW="[arm64] EL0 brk(9) grow mapped page at 0x0000000040C00000"
READBACK="[arm64] EL0 brk page read-back -> 0x00000000C9C9C9C9"
PHYS_HOLDS="[arm64] brk backing phys page holds -> 0x00000000C9C9C9C9"
STORELOAD_OK="[arm64] EL0 brk-mapped page store/load OK"
USERMSG="Hello from the brk-mapped EL0 page"
WRITE_OK="[arm64] EL0 write(9) syscall serviced"
EXIT_OK="[arm64] EL0 exit(9) syscall serviced"
BRK_OK="[arm64] EL0 page-table brk OK"

fail() {
    echo "[test_arm64_phase9] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase9] qemu-system-aarch64 not found; attempting apt install"
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
    echo "[test_arm64_phase9] aarch64-linux-gnu-as not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y binutils-aarch64-linux-gnu >/dev/null 2>&1 || true
    fi
fi
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase9_test"
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
# After Phase 9's exit(0) the kernel masks IRQs and spins in WFI, so QEMU keeps
# running until the timeout kills it. All assertions run on the serial log. This
# test uses no virtio-blk and is load-independent, safe under concurrency.
timeout 60 "$QEMU" \
    -M virt -cpu cortex-a72 -nographic -no-reboot \
    -kernel "$ELF" \
    >"$SERIAL" 2>&1

if [ ! -s "$SERIAL" ]; then
    fail "no serial output captured from QEMU"
fi

dump_serial() {
    echo "[test_arm64_phase9] captured serial:"
    sed 's/^/[test_arm64_phase9]   | /' "$SERIAL"
}

grep -q "$BANNER"          "$SERIAL" || { dump_serial; fail "boot banner not found"; }
grep -q -F "$SURFACE_OK"   "$SERIAL" || { dump_serial; fail "Phase-8 syscall surface did not complete (Phase 9 not reached)"; }
grep -q -F "$PHASE9"       "$SERIAL" || { dump_serial; fail "Phase-9 brk stage did not start"; }
grep -q -F "$BRK_QUERY"    "$SERIAL" || { dump_serial; fail "brk(0) did not return the unmapped heap base"; }
grep -q -F "$BRK_GROW"     "$SERIAL" || { dump_serial; fail "brk(grow) did not map a fresh page into TTBR0"; }
grep -q -F "$READBACK"     "$SERIAL" || { dump_serial; fail "EL0 did not read back the sentinel through the new mapping"; }
grep -q -F "$PHYS_HOLDS"   "$SERIAL" || { dump_serial; fail "the backing physical page did not hold the sentinel"; }
grep -q -F "$STORELOAD_OK" "$SERIAL" || { dump_serial; fail "brk-mapped page store/load verification did not pass"; }
grep -q -F "$USERMSG"      "$SERIAL" || { dump_serial; fail "EL0 write() buffer was not echoed to the UART"; }
grep -q -F "$WRITE_OK"     "$SERIAL" || { dump_serial; fail "write syscall was not serviced"; }
grep -q -F "$EXIT_OK"      "$SERIAL" || { dump_serial; fail "exit syscall was not serviced"; }
grep -q -F "$BRK_OK"       "$SERIAL" || { dump_serial; fail "'$BRK_OK' not found (page-table brk did not complete cleanly)"; }

echo "[test_arm64_phase9] boot banner    : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase9] phase 9 start   : $(grep -F "$PHASE9" "$SERIAL" | head -1)"
echo "[test_arm64_phase9] brk query       : $(grep -F "$BRK_QUERY" "$SERIAL" | head -1)"
echo "[test_arm64_phase9] brk grow+map    : $(grep -F "$BRK_GROW" "$SERIAL" | head -1)"
echo "[test_arm64_phase9] page read-back   : $(grep -F "$READBACK" "$SERIAL" | head -1)"
echo "[test_arm64_phase9] backing phys     : $(grep -F "$PHYS_HOLDS" "$SERIAL" | head -1)"
echo "[test_arm64_phase9] store/load OK    : $(grep -F "$STORELOAD_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase9] write echoed     : $(grep -F "$USERMSG" "$SERIAL" | head -1)"
echo "[test_arm64_phase9] brk marker       : $(grep -F "$BRK_OK" "$SERIAL" | head -1)"
echo "[test_arm64_phase9] PASS"
