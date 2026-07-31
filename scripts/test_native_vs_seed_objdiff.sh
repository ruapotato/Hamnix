#!/usr/bin/env bash
# scripts/test_native_vs_seed_objdiff.sh — SYSTEMATIC native-vs-seed machine-code
# differential over EVERY userland .ad unit the native compiler accepts.
#
# THE METHOD (host-only, NO QEMU, seconds per unit):
#   For each userland unit, compile it with BOTH backends:
#     - SEED   = Python oracle (codegen_x86.py -> as/ld), the frozen-correct ref
#     - NATIVE = build/cutover/host_ac.elf (the self-hosted .ad compiler)
#   Both emit a Hamnix-format ELF32 image (elf_emit.ad's deliberate ELFCLASS32).
#   We disassemble each as RAW x86-64 (the bytes ARE x86-64; the ELFCLASS32 is
#   only for the Hamnix loader) and align function-by-function in SOURCE ORDER
#   (both backends emit functions in declaration order). The seed carries a
#   symtab giving exact function boundaries; we map the SAME boundary sequence
#   onto the native image (native has no symtab) by matching prologue signatures
#   and the call/structure shape.
#
#   We NORMALIZE away differences that are benign BY CONSTRUCTION:
#     - absolute instruction addresses (the leading "  NNN:" column)
#     - RIP-relative displacement targets (different .text/.data base + layout)
#     - call/jmp ABSOLUTE target addresses in the objdump comment
#     - the call/jmp displacement immediate (relocation/layout difference)
#   and FLAG real semantic divergences:
#     - different mnemonic / opcode
#     - wrong operand WIDTH (movq vs movl/movw/movb/movzbl — the recurring bug)
#     - wrong register
#     - different immediate (non-address)
#     - missing / extra instruction in a function body
#
# Usage:  bash scripts/test_native_vs_seed_objdiff.sh [unit.ad ...]
#         (no args = every accepted userland unit)
#         OBJDIFF_VERBOSE=1 to dump every per-instruction divergence.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
source scripts/_adder_cc.sh

OUT=build/objdiff
mkdir -p "$OUT"
VERBOSE="${OBJDIFF_VERBOSE:-0}"

fail() { echo "[objdiff] FATAL $*"; exit 1; }
command -v objdump >/dev/null || fail "objdump missing"
command -v as >/dev/null || fail "as missing"
command -v ld >/dev/null || fail "ld missing"

# Build the native host compiler once.
ADDER_CC=adder adder_cc_bootstrap || fail "host_ac.elf bootstrap failed"

# Discover units: every user/*.ad + the lib units exercised. Default = all
# user/*.ad whose native compile the .ad backend accepts.
if [ "$#" -gt 0 ]; then
    UNITS=("$@")
else
    mapfile -t UNITS < <(ls user/*.ad 2>/dev/null | sort)
fi

TOTAL=0; NATIVE_OK=0; CLEAN=0; DIVERGED=0; FELLBACK=0
DIVLIST=()
FBLIST=()

for unit in "${UNITS[@]}"; do
    [ -f "$unit" ] || continue
    base="$(basename "$unit" .ad)"
    TOTAL=$((TOTAL+1))
    seed_elf="$OUT/$base.seed.elf"
    nat_elf="$OUT/$base.native.elf"

    # Seed (oracle) — must always succeed; if not, skip (seed is ground truth,
    # a seed failure is not a native divergence).
    if ! ADDER_CC=python adder_cc_compile compile --target=x86_64-adder-user \
            "$unit" -o "$seed_elf" >/dev/null 2>"$OUT/$base.seed.err"; then
        [ "$VERBOSE" = 1 ] && echo "[objdiff] SKIP $base (seed reject)"
        continue
    fi
    # Native — the unit under test. A native REJECT is reported separately (not
    # a code divergence; it's an acceptance gap tracked by the wholetree gate).
    if ! ADDER_CC=adder adder_cc_compile compile --target=x86_64-adder-user \
            "$unit" -o "$nat_elf" >/dev/null 2>"$OUT/$base.native.err"; then
        echo "[objdiff] $base: native REJECT (acceptance gap, not a divergence)"
        continue
    fi
    # SILENT SEED FALLBACK — the differential's blind spot. adder_cc_compile
    # (scripts/_adder_cc.sh) does NOT propagate a host_ac.elf failure: it prints
    # "native compile failed -> Python seed fallback" and re-runs the PYTHON
    # SEED into the same output, then exits 0. The gate then compared the seed
    # image against ITSELF and counted the unit as native-accepted.
    #
    # That is worse than a plain miss: a self-comparison is not automatically
    # clean, because the two sides are read by different code paths (symtab
    # function boundaries vs endbr64 block splitting). A seed image carries its
    # runtime wrapper run at the FRONT and its .data inside the single PT_LOAD,
    # so the block splitter produced one extra leading block and fused `main`
    # with the data section — hambrowse reported 6 PHANTOM diverged functions
    # from a file compared with itself, while its REAL status (host_ac rejects
    # it: "ELF emit error (overflow)", its .text has outgrown the 2 MiB
    # DATA_BASE budget) went unreported.
    #
    # Detect it two ways: the wrapper's own stderr marker, and byte-identity
    # with the seed output (which no genuine native compile can produce — the
    # native emitter writes no section headers and splits code/data into two
    # PT_LOADs).
    if grep -q "seed fallback" "$OUT/$base.native.err" 2>/dev/null \
            || cmp -s "$seed_elf" "$nat_elf"; then
        echo "[objdiff] $base: native REJECT via SEED FALLBACK (acceptance gap, not a divergence)"
        sed -n 's/^\[host_ac\] /[objdiff]     host_ac: /p' "$OUT/$base.native.err" | head -3
        FELLBACK=$((FELLBACK+1))
        FBLIST+=("$base")
        continue
    fi
    NATIVE_OK=$((NATIVE_OK+1))

    # The differential normalizer does the heavy lifting.
    if OBJDIFF_VERBOSE="$VERBOSE" python3 scripts/objdiff_normalize.py \
            "$seed_elf" "$nat_elf" "$base"; then
        CLEAN=$((CLEAN+1))
    else
        DIVERGED=$((DIVERGED+1))
        DIVLIST+=("$base")
    fi
done

echo "============================================================"
echo "[objdiff] units total=$TOTAL  native-accepted=$NATIVE_OK"
if [ "$FELLBACK" -gt 0 ]; then
    echo "[objdiff]   native REJECT via seed fallback=$FELLBACK: ${FBLIST[*]}"
fi
echo "[objdiff]   semantically CLEAN=$CLEAN  DIVERGED=$DIVERGED"
if [ "$DIVERGED" -gt 0 ]; then
    echo "[objdiff] DIVERGED units: ${DIVLIST[*]}"
    exit 1
fi
echo "[objdiff] PASS — zero semantic divergences across $NATIVE_OK accepted units"
