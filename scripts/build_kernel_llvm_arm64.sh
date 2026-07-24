#!/usr/bin/env bash
# scripts/build_kernel_llvm_arm64.sh — OPT-IN aarch64 lane: build the Hamnix
# whole-kernel (init/main.ad closure) through the Adder LLVM backend targeting
# AArch64 (--target=aarch64-bare-metal), compile to an ELF64 aarch64 relocatable
# with clang, and LINK it against the arch/arm64/llvm/ boot layer (head.S entry +
# MMU + PL011 console, vectors.S, intrinsics.S, stubs.c) under
# arch/arm64/llvm/kernel.lds into a bootable aarch64 kernel ELF for
# `qemu-system-aarch64 -M virt`.
#
# This is Phase A3 of docs/arm64_llvm_scoping.md. It does NOT touch the x86 lane
# (scripts/build_kernel_llvm.sh) nor the default native kernel build; it is a new
# arch layer + build lane only (no compiler-source change).
#
# Usage:  scripts/build_kernel_llvm_arm64.sh [out-kernel-elf]
#   default out: build/kllvm_arm64/hamnix_kernel_llvm_arm64.elf
#
# Env:
#   ADDER_HOST_AC  host_ac.elf with the LLVM backend (default build/cutover/host_ac.elf)
#   CLANG          clang binary (default clang-19)
#   CROSS          aarch64 binutils prefix (default aarch64-linux-gnu-)
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT_ELF="${1:-build/kllvm_arm64/hamnix_kernel_llvm_arm64.elf}"
HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}"
CLANG="${CLANG:-clang-19}"
CROSS="${CROSS:-aarch64-linux-gnu-}"
AS_CMD="${CROSS}as"
LD_CMD="${CROSS}ld"
WORK="build/kllvm_arm64"
ARM="arch/arm64/llvm"
mkdir -p "$WORK"

command -v "$CLANG"   >/dev/null || { echo "[kllvm-arm64] ERROR: $CLANG not found" >&2; exit 1; }
command -v "$AS_CMD"  >/dev/null || { echo "[kllvm-arm64] ERROR: $AS_CMD not found (apt install binutils-aarch64-linux-gnu)" >&2; exit 1; }
command -v "$LD_CMD"  >/dev/null || { echo "[kllvm-arm64] ERROR: $LD_CMD not found" >&2; exit 1; }
[ -x "$HOST_AC" ] || { echo "[kllvm-arm64] ERROR: no host_ac.elf at $HOST_AC (source scripts/_adder_cc.sh; adder_cc_bootstrap)" >&2; exit 1; }
for f in head.S vectors.S gic.S el0.S sched.S intrinsics.S stubs.c kernel.lds; do
    [ -f "$ARM/$f" ] || { echo "[kllvm-arm64] ERROR: missing $ARM/$f" >&2; exit 1; }
done

echo "[kllvm-arm64] 1) emit whole-kernel aarch64 LLVM IR (init/main.ad closure)"
"$HOST_AC" --backend=llvm --target=aarch64-bare-metal init/main.ad "$WORK/kernel_arm64.ll" \
    || { echo "[kllvm-arm64] ERROR: LLVM IR emit failed" >&2; exit 1; }
grep -q 'target triple = "aarch64' "$WORK/kernel_arm64.ll" \
    || { echo "[kllvm-arm64] ERROR: emitted .ll is not aarch64" >&2; exit 1; }
echo "[kllvm-arm64]    $(grep '; ADDER_STAT' "$WORK/kernel_arm64.ll")"

# 1b) Build-lane fix (rewrites the GENERATED .ll only; no compiler-source
# change => x86 lane byte-identical). The A2 aarch64 inline-asm for rdrand/
# rdseed/mul128 addresses scratch globals (hwrng_scratch, hwrng_cf,
# tls_mul128_*) with `adrp`+`str x,[.., :lo12:sym]` — a 64-bit access that the
# R_AARCH64_LDST64_ABS_LO12_NC relocation can only encode when the symbol is
# 8-byte aligned, but the emitter declares those [8 x i8] byte arrays `align 1`,
# so the link fails "relocation truncated to fit". Over-align every global to at
# least 8 (always safe) so the :lo12: 64-bit forms encode. The real fix is an
# `align 8` on these emitter globals in ssa_llvm.ad (an A4 compiler item, gated).
sed -i -E 's/^(@[A-Za-z0-9_.$]+ = .*global .*), align 1$/\1, align 8/' "$WORK/kernel_arm64.ll"
echo "[kllvm-arm64]    over-aligned $(grep -c ', align 8' "$WORK/kernel_arm64.ll") globals to >=8 for :lo12: 64-bit asm"

echo "[kllvm-arm64] 2) clang -c (-O0, aarch64-none-elf, -mcmodel=small) -> ELF64 reloc"
"$CLANG" -O0 -c -ffreestanding -fno-pic -fno-unwind-tables \
    -fno-stack-protector -fcf-protection=none -mno-red-zone -fno-addrsig \
    --target=aarch64-none-elf -mcmodel=small \
    "$WORK/kernel_arm64.ll" -o "$WORK/kernel_arm64.o" \
    || { echo "[kllvm-arm64] ERROR: clang compile failed" >&2; exit 1; }
file "$WORK/kernel_arm64.o" | sed 's/^/[kllvm-arm64]    /'

echo "[kllvm-arm64] 3) assemble boot layer (head/vectors/intrinsics) + compile stubs.c"
"$AS_CMD" -o "$WORK/head.o"       "$ARM/head.S"       || { echo "[kllvm-arm64] ERROR: as head.S" >&2; exit 1; }
"$AS_CMD" -o "$WORK/vectors.o"    "$ARM/vectors.S"    || { echo "[kllvm-arm64] ERROR: as vectors.S" >&2; exit 1; }
"$AS_CMD" -o "$WORK/gic.o"        "$ARM/gic.S"        || { echo "[kllvm-arm64] ERROR: as gic.S" >&2; exit 1; }
"$AS_CMD" -o "$WORK/el0.o"        "$ARM/el0.S"        || { echo "[kllvm-arm64] ERROR: as el0.S" >&2; exit 1; }
"$AS_CMD" -o "$WORK/sched.o"      "$ARM/sched.S"      || { echo "[kllvm-arm64] ERROR: as sched.S" >&2; exit 1; }
"$AS_CMD" -o "$WORK/intrinsics.o" "$ARM/intrinsics.S" || { echo "[kllvm-arm64] ERROR: as intrinsics.S" >&2; exit 1; }
"$CLANG" -O0 -c -ffreestanding -fno-pic --target=aarch64-none-elf -mcmodel=small \
    "$ARM/stubs.c" -o "$WORK/stubs.o" || { echo "[kllvm-arm64] ERROR: clang stubs.c" >&2; exit 1; }

echo "[kllvm-arm64] 4) link bootable aarch64 kernel ELF (kernel.lds, -nostdlib -static)"
"$LD_CMD" -nostdlib -static -z noexecstack -z max-page-size=4096 \
    -T "$ARM/kernel.lds" -o "$OUT_ELF" \
    "$WORK/head.o" "$WORK/vectors.o" "$WORK/gic.o" "$WORK/el0.o" "$WORK/sched.o" "$WORK/kernel_arm64.o" \
    "$WORK/intrinsics.o" "$WORK/stubs.o" \
    || { echo "[kllvm-arm64] ERROR: ld link failed" >&2; exit 1; }

echo "[kllvm-arm64] DONE -> $OUT_ELF"
file "$OUT_ELF" | sed 's/^/[kllvm-arm64]    /'
"${CROSS}size" "$OUT_ELF" 2>/dev/null | sed 's/^/[kllvm-arm64]    /'
echo "[kllvm-arm64] undefined symbols remaining: $("${CROSS}nm" -u "$OUT_ELF" 2>/dev/null | grep -c ' U ')"
