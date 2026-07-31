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
for f in head.S vectors.S gic.S el0.S sched.S a10.S elprobe.S intrinsics.S stubs.c kernel.lds \
         user_rt.S user.lds user_blob.S; do
    [ -f "$ARM/$f" ] || { echo "[kllvm-arm64] ERROR: missing $ARM/$f" >&2; exit 1; }
done
A10_SRC="${A10_SRC:-user/arm64_a10_el0.ad}"
A11_ECHO_SRC="${A11_ECHO_SRC:-user/arm64_a11_echo.ad}"
A11_SUM_SRC="${A11_SUM_SRC:-user/arm64_a11_sum.ad}"
for f in "$A10_SRC" "$A11_ECHO_SRC" "$A11_SUM_SRC"; do
    [ -f "$f" ] || { echo "[kllvm-arm64] ERROR: missing $f" >&2; exit 1; }
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

# --------------------------------------------------------------------------
# 3a) A10/A11: build the EL0 USER PROGRAM ARCHIVE
#     (docs/arm64_llvm_scoping.md A10, A11).
#
# Each member is an ordinary Adder program compiled by the SAME backend as the
# kernel, linked flat at 0x4801_0000 (user.lds) with the user_rt.S crt0, and
# objcopy'd to a raw binary. A11 packs them into ONE archive with a name table
# (scripts/pack_arm64_user_archive.py) that user_blob.S .incbin's into the
# kernel image; init/main.ad's arm64_a11_load_named_arm64() copies the NAMED
# member into the EL0 window.
#
# Every member is rebuilt on EVERY kernel build, so no embedded image can go
# stale relative to its .ad source -- the property A10's gate leans on.
#
# All members link at the SAME VA and are loaded one at a time, which is the
# honest scope of A11: several programs, selected by name, not several
# concurrently resident address spaces (that needs the per-task TTBR0 work).
# --------------------------------------------------------------------------
build_el0_image() {   # build_el0_image <tag> <src.ad>
    local tag="$1" src="$2"
    [ -f "$src" ] || { echo "[kllvm-arm64] ERROR: missing $src" >&2; exit 1; }
    "$HOST_AC" --backend=llvm --target=aarch64 "$src" "$WORK/${tag}.ll" \
        || { echo "[kllvm-arm64] ERROR: $tag user IR emit failed" >&2; exit 1; }
    # The EL0 program must be FULLY emitted: an external `declare` would mean a
    # function bailed the SSA subset and there is no runtime to supply it.
    if grep -q '^declare' "$WORK/${tag}.ll"; then
        echo "[kllvm-arm64] ERROR: $tag user .ll has external declares (a function bailed):" >&2
        grep '^declare' "$WORK/${tag}.ll" >&2
        exit 1
    fi
    grep -q 'svc #0' "$WORK/${tag}.ll" \
        || { echo "[kllvm-arm64] ERROR: $tag user .ll has no 'svc #0' (not the aarch64 syscall ABI)" >&2; exit 1; }
    "$CLANG" -O0 -c -ffreestanding -fno-pic -fno-unwind-tables -fno-stack-protector \
        -fno-addrsig --target=aarch64-none-elf -mcmodel=small \
        "$WORK/${tag}.ll" -o "$WORK/${tag}.o" 2>&1 | grep -v 'overriding the module target triple' | grep -v '^1 warning generated' || true
    [ -f "$WORK/${tag}.o" ] || { echo "[kllvm-arm64] ERROR: clang $tag user compile failed" >&2; exit 1; }
    "$LD_CMD" -nostdlib -static -T "$ARM/user.lds" -o "$WORK/${tag}.elf" \
        "$WORK/a10_user_rt.o" "$WORK/${tag}.o" 2>&1 | grep -v 'LOAD segment with RWX' || true
    [ -f "$WORK/${tag}.elf" ] || { echo "[kllvm-arm64] ERROR: $tag user link failed" >&2; exit 1; }
    local undef entry sz
    undef="$("${CROSS}nm" -u "$WORK/${tag}.elf" 2>/dev/null | grep -c ' U ')"
    [ "$undef" = "0" ] || { echo "[kllvm-arm64] ERROR: $tag user image has $undef undefined symbols" >&2; exit 1; }
    # _start MUST sit at the load VA: the kernel erets straight to 0x48010000.
    entry="$("${CROSS}nm" "$WORK/${tag}.elf" | awk '$3=="_start"{print $1}')"
    [ "$entry" = "0000000048010000" ] \
        || { echo "[kllvm-arm64] ERROR: $tag _start at 0x$entry, expected 0x48010000 (user.lds drift)" >&2; exit 1; }
    "${CROSS}objcopy" -O binary "$WORK/${tag}.elf" "$WORK/${tag}.bin" \
        || { echo "[kllvm-arm64] ERROR: objcopy $tag user image" >&2; exit 1; }
    sz="$(stat -c %s "$WORK/${tag}.bin")"
    [ "$sz" -gt 0 ] || { echo "[kllvm-arm64] ERROR: $tag user image is empty" >&2; exit 1; }
    # Budget: image must fit 0x48010000..0x48100000 (below the EL0 stacks).
    [ "$sz" -lt 983040 ] \
        || { echo "[kllvm-arm64] ERROR: $tag user image $sz bytes exceeds the EL0 window budget" >&2; exit 1; }
    echo "[kllvm-arm64]    $tag user image: $sz bytes, entry 0x48010000, 0 undefined, 0 bails"
}

echo "[kllvm-arm64] 3a) build the EL0 user programs via the SAME backend"
"$AS_CMD" -o "$WORK/a10_user_rt.o" "$ARM/user_rt.S" \
    || { echo "[kllvm-arm64] ERROR: as user_rt.S" >&2; exit 1; }
build_el0_image a10_user  "$A10_SRC"
build_el0_image a11_echo  "$A11_ECHO_SRC"
build_el0_image a11_sum   "$A11_SUM_SRC"
# The A10 line the A10 gate greps for, kept verbatim.
A10_SZ="$(stat -c %s "$WORK/a10_user.bin")"
echo "[kllvm-arm64]    A10 user image: $A10_SZ bytes, entry 0x48010000, 0 undefined, 0 bails"

echo "[kllvm-arm64] 3a2) pack the EL0 images into the named archive (A11)"
python3 scripts/pack_arm64_user_archive.py "$WORK/user_archive.bin" \
    "a10=$WORK/a10_user.bin" "echo=$WORK/a11_echo.bin" "sum=$WORK/a11_sum.bin" \
    | sed 's/^/[kllvm-arm64]    /' \
    || { echo "[kllvm-arm64] ERROR: packing the EL0 user archive failed" >&2; exit 1; }

echo "[kllvm-arm64] 3) assemble boot layer (head/vectors/intrinsics) + compile stubs.c"
"$AS_CMD" -o "$WORK/head.o"       "$ARM/head.S"       || { echo "[kllvm-arm64] ERROR: as head.S" >&2; exit 1; }
"$AS_CMD" -o "$WORK/vectors.o"    "$ARM/vectors.S"    || { echo "[kllvm-arm64] ERROR: as vectors.S" >&2; exit 1; }
"$AS_CMD" -o "$WORK/gic.o"        "$ARM/gic.S"        || { echo "[kllvm-arm64] ERROR: as gic.S" >&2; exit 1; }
"$AS_CMD" -o "$WORK/el0.o"        "$ARM/el0.S"        || { echo "[kllvm-arm64] ERROR: as el0.S" >&2; exit 1; }
"$AS_CMD" -o "$WORK/sched.o"      "$ARM/sched.S"      || { echo "[kllvm-arm64] ERROR: as sched.S" >&2; exit 1; }
"$AS_CMD" -o "$WORK/a10.o"        "$ARM/a10.S"        || { echo "[kllvm-arm64] ERROR: as a10.S" >&2; exit 1; }
"$AS_CMD" -o "$WORK/elprobe.o"    "$ARM/elprobe.S"    || { echo "[kllvm-arm64] ERROR: as elprobe.S" >&2; exit 1; }
# -I "$WORK" so user_blob.S's `.incbin "a10_user.bin"` picks up the image just
# built in 3a — never a checked-in or stale copy.
"$AS_CMD" -I "$WORK" -o "$WORK/user_blob.o" "$ARM/user_blob.S" || { echo "[kllvm-arm64] ERROR: as user_blob.S" >&2; exit 1; }
"$AS_CMD" -o "$WORK/intrinsics.o" "$ARM/intrinsics.S" || { echo "[kllvm-arm64] ERROR: as intrinsics.S" >&2; exit 1; }
"$CLANG" -O0 -c -ffreestanding -fno-pic --target=aarch64-none-elf -mcmodel=small \
    "$ARM/stubs.c" -o "$WORK/stubs.o" || { echo "[kllvm-arm64] ERROR: clang stubs.c" >&2; exit 1; }

# stubs.c is a hand-maintained snapshot of the symbols the whole-kernel .ll left
# undefined. As main evolves (notably api_autostubs regeneration), the kernel
# closure can START defining a symbol that stubs.c also defines -> `multiple
# definition` at link. The kernel's REAL definition must always win, so localize
# any stub symbol that kernel_arm64.o already defines globally. Self-healing:
# no hand-editing of stubs.c is needed when the closure grows a definition.
"${CROSS}nm" --defined-only -g "$WORK/kernel_arm64.o" 2>/dev/null \
    | awk '{print $NF}' | sort -u >"$WORK/kernel_defined.txt"
"${CROSS}nm" --defined-only -g "$WORK/stubs.o" 2>/dev/null \
    | awk '{print $NF}' | sort -u >"$WORK/stubs_defined.txt"
comm -12 "$WORK/kernel_defined.txt" "$WORK/stubs_defined.txt" >"$WORK/stubs_shadowed.txt"
SHADOWED=$(wc -l <"$WORK/stubs_shadowed.txt")
if [ "$SHADOWED" -gt 0 ]; then
    echo "[kllvm-arm64]    $SHADOWED stub(s) now defined by the kernel closure; localizing in stubs.o:"
    sed 's/^/[kllvm-arm64]      - /' "$WORK/stubs_shadowed.txt"
    LOCALIZE_ARGS=()
    while read -r s; do [ -n "$s" ] && LOCALIZE_ARGS+=(-L "$s"); done <"$WORK/stubs_shadowed.txt"
    "${CROSS}objcopy" "${LOCALIZE_ARGS[@]}" "$WORK/stubs.o" \
        || { echo "[kllvm-arm64] ERROR: objcopy localize stubs" >&2; exit 1; }
fi

# --------------------------------------------------------------------------
# 3c) AUTO-STUB THE BAILS (self-healing; closes the 2026-07-30 link regression).
#
# stubs.c is a hand-maintained snapshot, and its header says it covers "the 5
# LLVM bails (start_kernel, do_syscall, ...)". That coupling is exactly what
# rotted: as the SSA/LLVM subset BROADENS on the x86 track, a function that used
# to bail starts EMITTING — and its emitted body then calls a callee that is
# STILL bailed and that nothing defines. Concretely, `do_syscall` began emitting
# and called `arch_x86_kernel_syscall__do_syscall_dispatch` (bail reason=1),
# which stubs.c never listed because do_syscall itself used to be the stub. The
# link died with R_AARCH64_CALL26 against an undefined symbol. Nothing in the
# hand-maintained list can anticipate this: every subset improvement on x86 can
# expose a NEW bailed callee here.
#
# The emitter already tells us the closed set: it writes `; BAILED @<sym>` for
# every function it declined to emit. Those are, by construction, functions with
# NO body in this image, so a return-0 stub is the only possible definition — it
# is precisely what a human would have hand-added to stubs.c, derived
# mechanically instead.
#
# SCOPE IS DELIBERATELY NARROW, so this cannot become a soft green: ONLY symbols
# the emitter itself marked BAILED are auto-stubbed. Any OTHER undefined symbol
# (a genuinely missing arch mechanism, a typo, a dropped .S file) still reaches
# ld and still hard-fails the link. Auto-stubbing everything undefined would
# silently paper over real gaps; auto-stubbing the bail set only removes a
# bookkeeping chore the compiler can do for us.
echo "[kllvm-arm64] 3c) auto-stub LLVM bails not defined by any object"
grep -oP '^; BAILED @\K[A-Za-z0-9_.$]+' "$WORK/kernel_arm64.ll" | sort -u >"$WORK/bailed.txt"
: >"$WORK/all_defined.txt"
for o in head vectors gic el0 sched a10 user_blob kernel_arm64 intrinsics stubs; do
    "${CROSS}nm" --defined-only -g "$WORK/$o.o" 2>/dev/null | awk '{print $NF}'
done | sort -u >"$WORK/all_defined.txt"
comm -23 "$WORK/bailed.txt" "$WORK/all_defined.txt" >"$WORK/bailed_undefined.txt"
NBAIL=$(grep -c . "$WORK/bailed_undefined.txt" || true)
{
    echo "/* GENERATED by scripts/build_kernel_llvm_arm64.sh step 3c — do not edit."
    echo "   One return-0 definition per '; BAILED @sym' the emitter left with no"
    echo "   body and that no object defines. Regenerated on every build. */"
    echo "typedef unsigned long u64;"
    while read -r s; do
        [ -n "$s" ] && echo "u64 $s(void) { return 0; }"
    done <"$WORK/bailed_undefined.txt"
} >"$WORK/autostub_bails.c"
if [ "$NBAIL" -gt 0 ]; then
    echo "[kllvm-arm64]    $NBAIL bailed symbol(s) had no definition; stubbing:"
    sed 's/^/[kllvm-arm64]      - /' "$WORK/bailed_undefined.txt"
else
    echo "[kllvm-arm64]    no undefined bails (every bailed symbol already has a definition)"
fi
"$CLANG" -O0 -c -ffreestanding -fno-pic --target=aarch64-none-elf -mcmodel=small \
    "$WORK/autostub_bails.c" -o "$WORK/autostub_bails.o" \
    || { echo "[kllvm-arm64] ERROR: clang autostub_bails.c" >&2; exit 1; }

echo "[kllvm-arm64] 4) link bootable aarch64 kernel ELF (kernel.lds, -nostdlib -static)"
"$LD_CMD" -nostdlib -static -z noexecstack -z max-page-size=4096 \
    -T "$ARM/kernel.lds" -o "$OUT_ELF" \
    "$WORK/head.o" "$WORK/vectors.o" "$WORK/gic.o" "$WORK/el0.o" "$WORK/sched.o" \
    "$WORK/a10.o" "$WORK/elprobe.o" "$WORK/user_blob.o" "$WORK/kernel_arm64.o" \
    "$WORK/intrinsics.o" "$WORK/stubs.o" "$WORK/autostub_bails.o" \
    || { echo "[kllvm-arm64] ERROR: ld link failed" >&2; exit 1; }

echo "[kllvm-arm64] DONE -> $OUT_ELF"
file "$OUT_ELF" | sed 's/^/[kllvm-arm64]    /'
"${CROSS}size" "$OUT_ELF" 2>/dev/null | sed 's/^/[kllvm-arm64]    /'
echo "[kllvm-arm64] undefined symbols remaining: $("${CROSS}nm" -u "$OUT_ELF" 2>/dev/null | grep -c ' U ')"
