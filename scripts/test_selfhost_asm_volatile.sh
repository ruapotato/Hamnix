#!/usr/bin/env bash
# scripts/test_selfhost_asm_volatile.sh — Track-3 self-hosting CUTOVER
# cap#4b INLINE-ASM + TRIPLE-QUOTE + `ref`-identifier regression gate
# (host-only, NO QEMU).
#
# The self-hosted `.ad` host compiler (build/cutover/host_ac.elf) must lower
# inline `asm_volatile("...")` to the EXACT machine bytes GNU `as` produces
# from the frozen Python seed's emitted assembly text. This gate compiles a
# self-contained `.ad` unit exercising the kernel's full asm-body vocabulary
# (zero-operand insns, retpoline `popq %rbp; jmpq *%reg` thunks, a CPUID
# RIP-global block, and an RDRAND block with local `.L` labels + rel8 jumps),
# then disassembles the emitted .text and asserts the opcode bytes match the
# `as` ground truth.
#
# It ALSO guards two lexer/driver fixes the whole-kernel parse depended on:
#   * triple-quoted `"""..."""` string lexing (the multi-line asm bodies), and
#   * lexing lowercase `ref` as an ordinary IDENT (the seed's only REF keyword
#     is the capitalised `Ref`); the kernel uses `ref` as a parameter name.
#
# Usage:  bash scripts/test_selfhost_asm_volatile.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[asmvol] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v objdump >/dev/null 2>&1 || fail "objdump not found (binutils)"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64"

WT="build/cutover/asmvol"
mkdir -p "$WT" build/cutover

# --- (1) Build the .ad host compiler via the Python seed (trust root).
echo "[asmvol] (1/3) build host_ac.elf via the Python seed"
python3 - <<'PY' || fail "concat host compiler source failed"
import importlib.util
spec = importlib.util.spec_from_file_location("ccs", "scripts/concat_compiler_source.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.DRIVER_MAIN = "fused_driver_host_main.ad"
raise SystemExit(m.main(["concat", "-o", "build/cutover/host_compiler.ad", "--with-driver"]))
PY
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-linux build/cutover/host_compiler.ad build/cutover/host_ac.elf >/dev/null 2>build/cutover/host_ac.cerr || { cat build/cutover/host_ac.cerr; fail "host_ac.elf failed to build"; }
[ -x build/cutover/host_ac.elf ] || fail "no host_ac.elf produced"

# --- (2) Compile a self-contained unit exercising every asm form + the
#         triple-quote + `ref`-identifier paths.
echo "[asmvol] (2/3) compile asm_volatile / triple-quote / ref unit"
cat > "$WT/asm_unit.ad" <<'AD'
# `ref` must lex as an ordinary identifier (NOT the REF keyword) — the kernel
# uses it as a parameter name. A failure here is a parse error.
def rcuref_get_slowpath(ref: uint64) -> int32:
    return 1

cpuid_eax: uint64 = 0
cpuid_ebx: uint64 = 0
cpuid_ecx: uint64 = 0
cpuid_edx: uint64 = 0
hwrng_scratch: uint64 = 0
hwrng_cf: uint64 = 0

def asm_zero_ops():
    asm_volatile("cli")
    asm_volatile("sti")
    asm_volatile("hlt")
    asm_volatile("pause")
    asm_volatile("mfence")

# Multi-line triple-quoted body: retpoline thunk `popq %rbp ; jmpq *%reg`.
def thunk_rax():
    asm_volatile("""
        popq %rbp
        jmpq *%rax
    """)

def thunk_r15():
    asm_volatile("""
        popq %rbp
        jmpq *%r15
    """)

# CPUID block with RIP-relative loads/stores to globals.
def do_cpuid():
    asm_volatile("""
        pushq %rbx
        movq cpuid_eax(%rip), %rax
        movq cpuid_ecx(%rip), %rcx
        cpuid
        movq %rax, cpuid_eax(%rip)
        movq %rbx, cpuid_ebx(%rip)
        movq %rcx, cpuid_ecx(%rip)
        movq %rdx, cpuid_edx(%rip)
        popq %rbx
    """)

# RDRAND block with local .L labels + rel8 jc/loop/jmp.
def do_rdrand():
    asm_volatile("""
        movq $10, %rcx
        .Lrdrand_retry:
        rdrand %rax
        jc .Lrdrand_ok
        loop .Lrdrand_retry
        jmp .Lrdrand_done
        .Lrdrand_ok:
        movq %rax, hwrng_scratch(%rip)
        movq $1, hwrng_cf(%rip)
        .Lrdrand_done:
    """)

def main() -> int32:
    return 0
AD

build/cutover/host_ac.elf "$WT/asm_unit.ad" "$WT/asm_unit.elf" \
    >"$WT/asm_unit.err" 2>&1 \
    || { cat "$WT/asm_unit.err"; fail "host_ac rejected the asm unit (parse/codegen)"; }

# --- (3) Disassemble and assert the exact `as` ground-truth opcode bytes.
echo "[asmvol] (3/3) verify emitted bytes vs GNU as ground truth"
DIS="$WT/asm_unit.dis"
# The self-contained host_ac user-ELF emitter writes a minimal header objdump
# reads as elf32-i386, but the code is x86-64. Disassemble the raw image as
# binary with the x86-64 decoder so the byte runs are decoded correctly.
objdump -D -b binary -m i386:x86-64 "$WT/asm_unit.elf" > "$DIS" 2>/dev/null \
    || fail "objdump failed on emitted ELF"

# Each pattern is a hex byte-run that MUST appear in the disassembly. Bytes are
# exactly what `as --64` emits for the corresponding instruction.
check() {
    local what="$1" bytes="$2"
    # Normalise: objdump prints lowercase hex pairs separated by spaces.
    if ! grep -qiE "[[:space:]]$bytes[[:space:]]" "$DIS" \
       && ! grep -qiE "[[:space:]]$bytes\$" "$DIS"; then
        echo "[asmvol] missing expected bytes for: $what  ($bytes)"
        fail "byte mismatch: $what"
    fi
    echo "[asmvol]   ok: $what"
}

check "cli"                "fa"
check "sti"                "fb"
check "hlt"                "f4"
check "pause"              "f3 90"
check "mfence"             "0f ae f0"
check "popq %rbp"          "5d"
check "jmpq *%rax"         "ff e0"
check "jmpq *%r15"         "41 ff e7"
check "pushq %rbx"         "53"
check "popq %rbx"          "5b"
check "cpuid"              "0f a2"
check "rdrand %rax"        "48 0f c7 f0"
check "movq \$10,%rcx"      "48 c7 c1 0a 00 00 00"
check "jc rel8"            "72 04"
check "loop rel8"          "e2 f8"
# movq %reg,sym(%rip) store opcode+modrm (disp32 reloc value is image-specific):
check "movq %rax,(%rip)"   "48 89 05"
check "movq %rbx,(%rip)"   "48 89 1d"
# movq sym(%rip),%reg load opcode+modrm:
check "movq (%rip),%rax"   "48 8b 05"

echo "[asmvol] PASS — asm_volatile lowers to exact \`as\` bytes; triple-quote + \`ref\`-identifier parse."
