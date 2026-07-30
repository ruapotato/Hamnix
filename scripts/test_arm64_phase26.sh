#!/usr/bin/env bash
# scripts/test_arm64_phase26.sh — PHASE 26 multi-arch milestone: a real AArch64
# ELF64 LOADER + execute on bare aarch64.
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
# Every EL0 program in Phases 4..25 was hand-emitted machine code dropped straight
# into a code page. Phase 26 instead PARSES a genuine ELF64 image: the kernel
# assembles a real Elf64_Ehdr (ET_EXEC, EM_AARCH64, ELFCLASS64/LSB) + two
# Elf64_Phdr's (an R+X text segment carrying the EL0 program + an embedded message,
# and an R+W data segment with a BSS tail where p_memsz > p_filesz) into a
# module-scope byte array. The loader then VALIDATES e_ident/class/data/machine,
# reads e_entry / e_phoff / e_phnum / e_phentsize OUT of the header, walks the
# program-header table, and for each PT_LOAD allocates page-aligned backing, copies
# p_filesz file bytes, zeroes the (p_memsz - p_filesz) BSS tail, and maps
# [p_vaddr, p_vaddr+p_memsz) into a FRESH EL0 address space (its own ASID + L1/L2/L3
# tables) with W^X protections derived from p_flags (PF_X -> RO+exec text, PF_W ->
# RW+non-exec data). It sets up an EL0 stack, sets ELR_EL1 = e_entry + SPSR for
# EL0t, and ERETs into the loaded program — which runs write(1,msg,len), reads a
# byte from the zeroed BSS tail, then exit(42) via svc #0.
#
# The kernel proves the program ran from a GENUINELY-loaded ELF: the loaded text
# emitted its message, the BSS-tail byte read back ZERO (BSS zeroing worked), and
# the program exited with the expected status (42).
#
# Phase 26 runs only AFTER Phase 25 prints its PASS marker (the hand-off point),
# so every prior phase (4..25) must still run to completion (no regression).
#
# Prints "[test_arm64_phase26] PASS" on success or "[test_arm64_phase26] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BANNER="HAMNIX aarch64 boot OK"
BRK_OK="[arm64] EL0 page-table brk OK"
SCHED_OK="[arm64] SMP scheduling OK"
SIG_OK="[arm64] EL0 signal delivery OK"
FP_OK="[arm64] EL0 FP context switch OK"
DEMAND_OK="[arm64] EL0 demand paging OK"
UACCESS_OK="[arm64] EL1 safe user access OK"
MMAP_OK="[arm64] EL0 mmap/munmap OK"
MPROT_OK="[arm64] EL0 mprotect OK"
MP_OK="[arm64] EL0 multipage mmap split OK"
P19_OK="[arm64] EL0 dual-address-space ASID sched OK"
P20_OK="[arm64] EL0 dynamic spawn + exit/reaping OK"
P21_OK="[arm64] EL0 nanosleep block/wake scheduling OK"
P22_OK="[arm64] EL0 futex wait/wake scheduling OK"
P23_OK="[arm64] EL0 thread-local storage (TPIDR_EL0) scheduling OK"
P24_PASS="[arm64] Phase 24 PASS"
P25_PASS="[arm64] Phase 25 PASS"

PHASE26="[arm64] Phase 26: AArch64 ELF64 loader + execute"
ASM="[arm64] Phase 26: assembled ELF64 image ("
ELFHDR="[arm64] Phase 26 ELF: class64 LSB, machine=AArch64, type=EXEC, entry="
PTLOAD="[arm64] Phase 26 PT_LOAD: vaddr="
BSS="[arm64] Phase 26 program read BSS-tail byte -> "
LAUNCH="[arm64] launching loaded ELF program at EL0 (ASID 15), entry "
ISOLATED="[arm64] Phase 26: loaded a genuine AArch64 ELF64"
P26_PASS="[arm64] Phase 26 PASS"
PROG_MSG="Hello from a real ELF64 loaded on aarch64"

fail() {
    echo "[test_arm64_phase26] FAIL $*"
    exit 1
}

# --- locate / install qemu-system-aarch64 ------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_phase26] qemu-system-aarch64 not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y qemu-system-arm >/dev/null 2>&1 || true
    fi
    if command -v qemu-system-aarch64 >/dev/null 2>&1; then
        QEMU="qemu-system-aarch64"
    else
        fail "qemu-system-aarch64 not installed (apt install qemu-system-arm)"
    fi
fi

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_phase26_test"
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
    echo "[test_arm64_phase26] captured serial:"
    sed 's/^/[test_arm64_phase26]   | /' "$SERIAL"
}

# --- guard against any explicit failure markers ------------------------
if grep -q -F "Phase 26 ELF-loader FAIL" "$SERIAL"; then
    dump_serial
    fail "Phase-26 ELF loader reported FAIL"
fi
if grep -q -F "unknown syscall (phase 26)" "$SERIAL"; then
    dump_serial
    fail "Phase-26 program issued an unexpected syscall"
fi
if grep -q -F "EL1 SYNC EXCEPTION (kernel fault)" "$SERIAL"; then
    dump_serial
    fail "an EL1 abort paniced the kernel"
fi
if grep -q -F "EL0 non-SVC sync exception" "$SERIAL"; then
    dump_serial
    fail "an unexpected EL0 non-SVC sync exception fired (a segment fault was not serviced)"
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
grep -q -F "$P23_OK"     "$SERIAL" || { dump_serial; fail "Phase-23 thread-local storage did not complete — regression"; }
grep -q -F "$P24_PASS"   "$SERIAL" || { dump_serial; fail "Phase-24 demand paging did not complete — regression"; }
grep -q -F "$P25_PASS"   "$SERIAL" || { dump_serial; fail "Phase-25 COW fork did not complete (Phase 26 not reached) — regression"; }

# --- Phase 26 assertions ----------------------------------------------
grep -q -F "$PHASE26"  "$SERIAL" || { dump_serial; fail "Phase-26 demo did not start"; }
grep -q -F "$ASM"      "$SERIAL" || { dump_serial; fail "Phase-26 did not assemble the ELF64 image"; }
grep -q -F "$ELFHDR"   "$SERIAL" || { dump_serial; fail "Phase-26 loader did not validate the ELF header"; }

# EXACTLY 2 PT_LOAD segments must have been parsed + mapped.
NPT="$(grep -c -F "$PTLOAD" "$SERIAL")"
[ "$NPT" -eq 2 ] || { dump_serial; fail "expected exactly 2 PT_LOAD segments, saw $NPT"; }

grep -q -F "$LAUNCH"   "$SERIAL" || { dump_serial; fail "the loaded ELF program was never launched at EL0"; }

# The program's own message must reach the UART (it ran from the loaded text).
grep -q -F "$PROG_MSG" "$SERIAL" || { dump_serial; fail "the loaded program's message was not emitted (it did not run)"; }

# The BSS-tail read-back must be ZERO (BSS zeroing proven from EL0).
grep -q -F "${BSS}0x0000000000000000" "$SERIAL" || { dump_serial; fail "BSS-tail byte did not read back as zero"; }

grep -q -F "$ISOLATED"  "$SERIAL" || { dump_serial; fail "loader invariant not proven"; }
grep -q -F "$P26_PASS"  "$SERIAL" || { dump_serial; fail "'$P26_PASS' not found (Phase 26 did not complete cleanly)"; }

echo "[test_arm64_phase26] boot banner          : $(grep "$BANNER" "$SERIAL" | head -1)"
echo "[test_arm64_phase26] phase 25 OK (regr)    : $(grep -F "$P25_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase26] phase 26 start        : $(grep -F "$PHASE26" "$SERIAL" | head -1)"
echo "[test_arm64_phase26] ELF header validated  : $(grep -F "$ELFHDR" "$SERIAL" | head -1)"
echo "[test_arm64_phase26] PT_LOAD segments      : $NPT (== 2)"
echo "[test_arm64_phase26] program message       : $(grep -F "$PROG_MSG" "$SERIAL" | head -1)"
echo "[test_arm64_phase26] BSS-tail read-back    : $(grep -F "$BSS" "$SERIAL" | head -1)"
echo "[test_arm64_phase26] loader invariant      : $(grep -F "$ISOLATED" "$SERIAL" | head -1)"
echo "[test_arm64_phase26] phase 26 PASS line    : $(grep -F "$P26_PASS" "$SERIAL" | head -1)"
echo "[test_arm64_phase26] PASS"
