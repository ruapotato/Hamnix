#!/usr/bin/env bash
# scripts/adder_cc_llvm_native64.sh — build a NATIVE Hamnix binary as a REAL
# ELF64 EXEC from the Adder LLVM backend (adder/compiler/ssa_llvm.ad,
# --backend=llvm).
#
# WHY (vs scripts/adder_cc_llvm_native.sh): the ELF32 lane re-interprets
# clang's `.code64` output through `as --32` into an elf32-i386 wrapper (the
# format codegen.ad's native emitter produces). That wrapper CANNOT hold the
# 64-bit relocations (R_X86_64_64 / movabs / `.quad symbol`) clang emits for
# REAL programs — `as --32` fails with "cannot represent relocation type
# BFD_RELOC_64". `echo` was small enough to dodge it; the panel is not.
#
# This lane sidesteps the whole elf32 wrapper: clang emits a genuine ELF64
# object (all R_X86_64_* relocs are representable), the native runtime is
# assembled as ELF64, and `ld -m elf_x86_64` links a real ELF64 EXEC with
# OSABI=SYSV(0), entry=_start, NO PT_INTERP, and the Hamnix native syscall
# ABI (rax=num; SYS_WRITE=8, SYS_EXIT=1, ...). The loader (fs/elf.ad) already
# runs it: EI_CLASS==2 -> _load_elf64, and OSABI==0 + no PT_INTERP makes
# elf_is_linux_binary() return 0, so the task keeps NATIVE syscall routing +
# the native argc/argv register handoff (arch/x86/kernel/syscall.ad
# do_execve, is_linux==0 branch).
#
# HOW:
#   1) host_ac.elf --backend=llvm in.ad -> in.ll        (textual LLVM IR)
#   2) clang -c -ffreestanding -fpie -mno-red-zone ... in.ll -> main.o
#      (ELF64 object, small code model, no unwind/stack-protector so it
#       references no libc/runtime symbol the native link can't resolve).
#   3) as (64-bit) assembles user/runtime.S (native _start + sys_* stubs),
#      a synthesized progname.s (per-binary _start marker), and
#      scripts/adder_llvm_runtime_native.s (native print_u64) into ELF64
#      objects. The `.code64` directive in those .S/.s files is a no-op for
#      64-bit `as` — no `--32`, so their 64-bit relocs are representable too.
#   4) ld -m elf_x86_64 -nostdlib -static -pie -T user/init64_pie.lds -> ELF64
#      ET_DYN (PIE) at base 0, OSABI=SYSV, no PT_INTERP.
#
# PIE, NOT ET_EXEC (2026-07-30) — the low-BSS / direct-map lift.
# --------------------------------------------------------------
# This lane used to link ET_EXEC at a fixed low 0x400000 (user/init64.lds).
# That makes every app's user vaddrs numerically alias low physical RAM — the
# kernel's own identity direct map — so a kernel access through a direct-map VA
# inside the image's span lands on the APP's memory instead. hambrowse (~174
# MiB static BSS, span [0x400000, 0xB35E000)) aliased most of MEMBLOCK's
# [0x200000, 0x0F000000) pool and either wedged the box (demand-BSS punched
# 44,501 leaves not-present, so the demand resolver faulted recursively with
# interrupts off) or corrupted (eager full-span: `[pf] kernel write to RO user
# page va=0x0a890d98` at page_set_rmap, 5/5). It is only luck that it faulted
# rather than silently scribbling on a WRITABLE user page.
#
# ET_DYN removes the aliasing BY CONSTRUCTION: fs/elf.ad's ET_DYN arm rebases
# the image to a base of the KERNEL's choosing — the high ASLR vbase, or
# identity at the image's own memblock `region` on a deterministic boot — so an
# image's user vaddrs only ever cover its OWN pages. That is exactly the
# property the native ELF32 lane always had, and why the native lane never hit
# this class. It fixes all ~276 LLVM-lane apps at once, not just the one that
# grew big enough to notice.
#
# The kernel applies the resulting R_X86_64_RELATIVE relocations at load time
# (fs/elf.ad::_elf64_apply_relative_relocs). The link is -static -nostdlib with
# every symbol defined in-image, so no PLT and no symbolic relocation survives —
# hambrowse needs exactly 64 RELATIVE entries, all in .data.rel.ro. Step 5
# below ASSERTS that, so a toolchain change cannot silently introduce a
# relocation kind the loader would refuse (and it refuses loudly rather than
# skipping: an unrelocated pointer is a wild store).
#
# ADDER_NATIVE64_ETEXEC=1 restores the old ET_EXEC link for A/B bisection. It
# reintroduces the aliasing hazard — debug only.
#
# Usage:
#   scripts/adder_cc_llvm_native64.sh <in.ad> <out-elf>
#
# Env:
#   ADDER_HOST_AC  LLVM-capable host_ac.elf (default build/cutover/host_ac.elf).
#   BENCH_CLANG    clang binary (default clang-19, then clang).
#   ADDER_LLVM_CLANG_OPT  clang -O level (default -O2).
#
# Exit: 0 on a built native ELF64; nonzero on emit/compile/assemble/link fail.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

if [ $# -lt 2 ]; then
    echo "usage: adder_cc_llvm_native64.sh <in.ad> <out-elf>" >&2
    exit 2
fi
IN_AD="$1"; OUT_ELF="$2"; shift 2

HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac_llvm.elf}"
[ -x "$HOST_AC" ] || HOST_AC="build/cutover/host_ac.elf"
[ -x "$HOST_AC" ] || { echo "[cc_llvm_native64] ERROR: no host_ac.elf ($HOST_AC); build it (scripts/_adder_cc.sh adder_cc_bootstrap)" >&2; exit 1; }

CLANG="${BENCH_CLANG:-}"
if [ -z "$CLANG" ]; then
    if command -v clang-19 >/dev/null 2>&1; then CLANG=clang-19; else CLANG=clang; fi
fi
command -v "$CLANG" >/dev/null 2>&1 || { echo "[cc_llvm_native64] ERROR: $CLANG not found" >&2; exit 1; }
for t in as ld; do command -v "$t" >/dev/null 2>&1 || { echo "[cc_llvm_native64] ERROR: $t not found (binutils)" >&2; exit 1; }; done

RUNTIME_S="$PROJ_ROOT/user/runtime.S"
NATIVE_RT="$PROJ_ROOT/scripts/adder_llvm_runtime_native.s"

# PIE (ET_DYN) by default; ADDER_NATIVE64_ETEXEC=1 restores the legacy
# low-ET_EXEC link for A/B bisection (reintroduces the direct-map alias
# hazard — debug only).
if [ "${ADDER_NATIVE64_ETEXEC:-0}" = "1" ]; then
    LDS="$PROJ_ROOT/user/init64.lds"
    PIC_CFLAG="-fno-pic"; LD_PIE_FLAG="-no-pie"; LANE_KIND="ET_EXEC"
else
    LDS="$PROJ_ROOT/user/init64_pie.lds"
    PIC_CFLAG="-fpie";    LD_PIE_FLAG="-pie";    LANE_KIND="PIE"
fi

for f in "$RUNTIME_S" "$LDS" "$NATIVE_RT"; do
    [ -f "$f" ] || { echo "[cc_llvm_native64] ERROR: missing $f" >&2; exit 1; }
done
OPTLVL="${ADDER_LLVM_CLANG_OPT:--O2}"

# progname basename for the runtime marker string (matches the ELF32 lane's
# per-binary override).
PROG="$(basename "$IN_AD")"; PROG="${PROG%.ad}"
PROG_SAFE="$(printf '%s' "$PROG" | tr -c 'A-Za-z0-9._-' '_')"

LL="${OUT_ELF%.elf}.ll"; [ "$LL" = "$OUT_ELF" ] && LL="$OUT_ELF.ll"

# 1) host_ac emits the whole module as textual LLVM IR.
if ! "$HOST_AC" --backend=llvm "$IN_AD" "$LL"; then
    echo "[cc_llvm_native64] ERROR: host_ac --backend=llvm failed on $IN_AD" >&2
    exit 1
fi
grep -E "^; ADDER_STAT" "$LL" >&2 || true
if ! grep -q "^define i64 @main(" "$LL"; then
    echo "[cc_llvm_native64] ERROR: no @main emitted (its body bailed the SSA subset); .ll=$LL" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MAIN_O="$TMP/main.o"; RUNTIME_O="$TMP/runtime.o"
PROG_O="$TMP/progname.o"; NATRT_O="$TMP/native_rt.o"

# 2) clang: .ll -> ELF64 object directly. -fpie + the small code model make
#    every global reference RIP-relative, so the only dynamic relocations the
#    link can produce are R_X86_64_RELATIVE against in-image addresses that had
#    to be materialised as data (function-pointer tables in .data.rel.ro).
#    -ffreestanding/-nostdlib-ish flags keep it free of libc references.
if ! "$CLANG" "$OPTLVL" -c -ffreestanding "$PIC_CFLAG" -fno-asynchronous-unwind-tables \
        -fno-unwind-tables -fno-stack-protector -fcf-protection=none -mno-red-zone \
        -fno-addrsig -mcmodel=small "$LL" -o "$MAIN_O" 2>"$TMP/clang.err"; then
    echo "[cc_llvm_native64] ERROR: clang -c failed for $LL" >&2; cat "$TMP/clang.err" >&2
    exit 1
fi

# 3) progname.s — strong per-binary _start marker (overrides runtime.S's weak
#    fallback). No `.code64` needed for 64-bit `as`, but harmless if present.
PROG_S="$TMP/progname.s"
{
    printf '    .section .rodata\n    .align 8\n'
    printf '    .globl __runtime_start_mark_len\n__runtime_start_mark_len:\n'
    printf '    .quad __runtime_start_mark_end - __runtime_start_mark\n'
    printf '    .globl __runtime_start_mark\n    .globl __runtime_start_mark_end\n'
    printf '__runtime_start_mark:\n    .ascii "[runtime:%s] _start\\n"\n' "$PROG_SAFE"
    printf '__runtime_start_mark_end:\n'
} > "$PROG_S"

# Assemble the native runtime + progname as ELF64 (default `as`, no --32).
for pair in "$RUNTIME_S:$RUNTIME_O" "$PROG_S:$PROG_O" "$NATIVE_RT:$NATRT_O"; do
    src="${pair%%:*}"; obj="${pair##*:}"
    if ! as -o "$obj" "$src" 2>"$TMP/as.err"; then
        echo "[cc_llvm_native64] ERROR assembling $src:" >&2; cat "$TMP/as.err" >&2; exit 1
    fi
done

# 4) Link the native ELF64 image. progname.o first (strong marker overrides
#    runtime.S's weak fallback), then runtime.o (_start + sys_*), the clang
#    main, and the native print_u64 supplement.
if ! ld -m elf_x86_64 -nostdlib -static "$LD_PIE_FLAG" -T "$LDS" -o "$OUT_ELF" \
        "$PROG_O" "$RUNTIME_O" "$MAIN_O" "$NATRT_O" 2>"$TMP/ld.err"; then
    echo "[cc_llvm_native64] ERROR linking:" >&2; cat "$TMP/ld.err" >&2; exit 1
fi

# 5) PIE CONTRACT CHECK. The kernel's loader (fs/elf.ad) applies ONLY
#    R_X86_64_RELATIVE and REFUSES the load on any other kind, because skipping
#    one would leave a wild pointer in .data — the same silent-corruption class
#    the PIE move exists to eliminate. Assert the contract here so a toolchain
#    or codegen change fails at BUILD time, where it is cheap to attribute,
#    rather than as an unexplained refusal on device.
if [ "$LANE_KIND" = "PIE" ]; then
    if ! command -v readelf >/dev/null 2>&1; then
        echo "[cc_llvm_native64] WARNING: readelf missing; skipped the PIE reloc-kind check" >&2
    else
        bad="$(readelf -rW "$OUT_ELF" 2>/dev/null \
               | awk '/^[0-9a-f]+ /{print $3}' \
               | grep -v '^R_X86_64_RELATIVE$' | grep -v '^R_X86_64_NONE$' \
               | sort -u)"
        if [ -n "$bad" ]; then
            echo "[cc_llvm_native64] ERROR: $OUT_ELF carries dynamic relocations the" >&2
            echo "  native ELF64 loader cannot apply (it handles R_X86_64_RELATIVE only):" >&2
            echo "$bad" | sed 's/^/    /' >&2
            echo "  The load would be REFUSED on device. Either the link stopped being" >&2
            echo "  fully static/in-image, or codegen started emitting GOT/PLT references." >&2
            exit 1
        fi
        if [ "$(readelf -hW "$OUT_ELF" 2>/dev/null | awk '/^ *Type:/{print $2}')" != "DYN" ]; then
            echo "[cc_llvm_native64] ERROR: $OUT_ELF is not ET_DYN despite the PIE link" >&2
            exit 1
        fi
    fi
fi

echo "[cc_llvm_native64] built NATIVE ELF64 $LANE_KIND $OUT_ELF (via $HOST_AC + $CLANG $OPTLVL + native runtime)" >&2
exit 0
