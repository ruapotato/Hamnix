#!/usr/bin/env bash
#
# ON-DEMAND: not in ci_battery_manifest.txt because it HARD-FAILS (does not
# skip) without binutils-aarch64-linux-gnu and qemu-user-static, and the
# bare-metal battery runner apt-installs neither. Registering it therefore
# requires a .github/workflows/ci.yml change to add those two packages —
# which is worth doing: the ARM64 lane has silently stopped building on main
# before, precisely because no CI job ran an ARM64 gate. Measured 0.2 s on
# 55c842b9 with the toolchain present, so the cost is not the obstacle.
# scripts/test_arm64_codegen.sh — PHASE 1 multi-arch milestone: the Adder
# compiler's aarch64 (ARM64) Linux user-mode code-generation backend.
#
# Pipeline:
#   1. Compile a small Adder program with --target=aarch64-linux. The
#      hand-written aarch64 encoder (compiler/codegen_arm64.py) emits GNU
#      aarch64 assembly which is assembled + statically linked (no libc)
#      into a Linux user-mode ELF by aarch64-linux-gnu binutils.
#   2. Assert the ELF is well-formed and reports Machine: AArch64.
#   3. Run it under qemu-aarch64 (user-mode emulation) and assert on both
#      its stdout AND its process exit code.
#
# The test program exercises arithmetic, a recursive function call, a
# while-loop, a for-in-range loop, array indexing, and string output via
# the raw Linux `write` syscall — so a PASS genuinely proves the backend
# lowers a non-trivial program correctly, not just a trivial `exit(0)`.
#
# PASS criteria (all must hold):
#   - stdout contains "hello from aarch64"
#   - process exit code == 42 (the program returns 42 iff every computed
#     value — for-loop sum, fib(10), sum_to(10), array writes — matches)
#
# Prints "[ARM64] PASS" on success or "[ARM64] FAIL ..." on any failure.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() {
    echo "[ARM64] FAIL $*"
    exit 1
}

# --- locate qemu-aarch64 (user-mode) -----------------------------------
QEMU=""
if command -v qemu-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-aarch64"
elif command -v qemu-aarch64-static >/dev/null 2>&1; then
    QEMU="qemu-aarch64-static"
else
    echo "[ARM64] qemu-aarch64 not found; attempting apt install qemu-user-static"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y qemu-user-static >/dev/null 2>&1 || true
    fi
    if command -v qemu-aarch64-static >/dev/null 2>&1; then
        QEMU="qemu-aarch64-static"
    elif command -v qemu-aarch64 >/dev/null 2>&1; then
        QEMU="qemu-aarch64"
    else
        fail "qemu-aarch64 / qemu-aarch64-static not installed (apt install qemu-user-static)"
    fi
fi

# --- check the aarch64 assembler/linker --------------------------------
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || \
    fail "aarch64-linux-gnu-as not found (apt install binutils-aarch64-linux-gnu)"

# --- workspace (must live under the project root: the compiler's import
#     resolver rejects sources outside the tree) --------------------------
WORK="$PROJ_ROOT/build/arm64_codegen_test"
mkdir -p "$WORK"
SRC="$WORK/prog.ad"
ELF="$WORK/prog.elf"
trap 'rm -rf "$WORK"' EXIT

cat > "$SRC" <<'ADDER'
# aarch64 backend test program.
# Exercises: function defs + calls, recursion, arithmetic, while-loop,
# for-in-range loop, pointer/array indexing, and string output via the
# raw Linux write syscall.

def puts(s: Ptr[char], n: int64) -> int64:
    # write(fd=1, buf=s, count=n)
    return __syscall3(64, 1, cast[uint64](s), cast[uint64](n))

def fib(n: int64) -> int64:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

def sum_to(n: int64) -> int64:
    total: int64 = 0
    i: int64 = 0
    while i <= n:
        total = total + i
        i = i + 1
    return total

def main() -> int64:
    msg: Ptr[char] = "hello from aarch64\n"
    puts(msg, 19)

    # for-loop + arithmetic: acc = 1*1 + 2*2 + 3*3 + 4*4 + 5*5 = 55
    acc: int64 = 0
    for k in range(1, 6):
        acc = acc + k * k

    f: int64 = fib(10)          # 55
    s: int64 = sum_to(10)       # 55

    # array indexing (load + store)
    buf: Array[4, int64] = 0
    buf[0] = 10
    buf[1] = 20
    buf[2] = buf[0] + buf[1]    # 30

    if acc == 55 and f == 55 and s == 55 and buf[2] == 30:
        return 42
    return 1
ADDER

# --- compile -----------------------------------------------------------
COMPILE_OUT="$(python3 -m compiler.adder compile --target=aarch64-linux \
    "$SRC" -o "$ELF" 2>&1)" || fail "compile errored:
$COMPILE_OUT"
echo "$COMPILE_OUT" | grep -q "Compiled to" || fail "compiler did not report success:
$COMPILE_OUT"
[ -f "$ELF" ] || fail "no ELF produced at $ELF"

# --- verify ELF is a well-formed AArch64 executable --------------------
HDR="$(readelf -h "$ELF" 2>&1)" || fail "readelf failed on $ELF"
echo "$HDR" | grep -q "Machine: *AArch64" || fail "ELF Machine is not AArch64:
$HDR"

# --- run under qemu-aarch64 (user-mode) --------------------------------
RUN_OUT="$("$QEMU" "$ELF")"
RC=$?

echo "$RUN_OUT" | grep -q "hello from aarch64" || \
    fail "expected stdout 'hello from aarch64', got: '$RUN_OUT'"
[ "$RC" -eq 42 ] || fail "expected exit code 42, got $RC (stdout: '$RUN_OUT')"

echo "[ARM64] qemu stdout : $RUN_OUT"
echo "[ARM64] qemu exit   : $RC"
echo "[ARM64] PASS"
