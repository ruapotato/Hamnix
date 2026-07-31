#!/usr/bin/env bash
# scripts/test_llvm_container_of_2d_exec.sh — EXECUTION differential for the two
# SSA-subset lowerings that cleared the last whole-kernel LLVM bails (2026-07-30):
# `container_of(ptr, Type, field)` and 2-D LOCAL arrays `Array[N, Array[M, T]]`.
#
# WHY THIS GATE EXISTS AT ALL
# ---------------------------
# On x86 a function that bails the SSA subset falls back to the native
# codegen.ad lane and nothing is visibly wrong. On aarch64 there is NO fallback,
# and since the bail auto-stubber landed a bailed callee gets a generated
# `u64 f(void){return 0;}` — so the image LINKS and the function silently
# returns 0. That is strictly worse than the link error it replaced. Both
# functions these lowerings unblock had LIVE callers in the emitted kernel IR:
#   tests/core_smoke.ad::_list_walk_and_sum        6 call sites
#   init/main.ad::_try_parse_hamnix_roots          2 call sites
# so the aarch64 kernel was calling stubs for the .hamnix-roots sentinel parser.
#
# An emitted-code diff cannot see any of that. Only running the code can, and
# only against an oracle that does not share the implementation under test. So:
#
#   leg 1  NATIVE codegen.ad x86_64        <- the ORACLE. A separate backend
#                                             that has lowered both constructs
#                                             for years (gen_container_of; the
#                                             local-array slot path). Recomputed
#                                             from source on EVERY run — a baked
#                                             expected constant is a gate that
#                                             goes stale and then gets "fixed".
#   leg 2  LLVM lane, x86_64, run natively
#   leg 3  LLVM lane, aarch64, RUN under qemu-aarch64
#
# All three must agree on stdout AND exit status, and legs 2/3 must emit with
# ZERO bails (a bail would make the comparison vacuous — nothing ran through the
# new code).
#
# Fixture: tests/fuzz/regress_container_of_2d_local.ad. Its container_of arm is
# the verbatim body of _list_walk_and_sum and its 16x32 uint8 grid is the
# verbatim shape of _try_parse_hamnix_roots's `done_words`.
#
# Usage:  bash scripts/test_llvm_container_of_2d_exec.sh
# Exit:   0 PASS · 1 FAIL · 125 INCONCLUSIVE (missing toolchain — never a soft
#         green; a gate that could not execute anything must not read as green).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="tests/fuzz/regress_container_of_2d_local.ad"
W="build/llvm_cof2d"
mkdir -p "$W"

fail()   { echo "RESULT: FAIL — $*"; exit 1; }
inconc() { echo "RESULT: INCONCLUSIVE — $*"; exit 125; }

CLANG="${CLANG:-}"
if [ -z "$CLANG" ]; then
    if command -v clang-19 >/dev/null 2>&1; then CLANG=clang-19; else CLANG=clang; fi
fi
[ "$(uname -m)" = "x86_64" ]            || inconc "host $(uname -m); the oracle leg runs x86_64 ELFs natively"
command -v "$CLANG" >/dev/null 2>&1     || inconc "$CLANG missing (the LLVM lane needs clang)"
command -v qemu-aarch64 >/dev/null 2>&1 || inconc "qemu-aarch64 missing (apt install qemu-user)"
command -v aarch64-linux-gnu-ld >/dev/null 2>&1 \
    || inconc "aarch64 binutils missing (apt install binutils-aarch64-linux-gnu)"
command -v python3 >/dev/null 2>&1      || inconc "python3 missing (drives the native oracle)"
[ -f "$SRC" ] || fail "missing fixture $SRC"

echo "== 0) bootstrap host_ac.elf (ssa*.ad is CONCATENATED in; a stale one measures the old compiler) =="
# shellcheck source=_adder_cc.sh
source "$ROOT/scripts/_adder_cc.sh"
adder_cc_bootstrap >"$W/bootstrap.log" 2>&1 \
    || { sed 's/^/   | /' "$W/bootstrap.log"; fail "host_ac bootstrap"; }
HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}"
[ -x "$HOST_AC" ] || fail "no host_ac.elf at $HOST_AC"

# ---------------------------------------------------------------------------
echo "== 1) ORACLE: the NATIVE codegen.ad backend, recomputed from source =="
ORACLE="$(python3 - "$SRC" <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
from pathlib import Path
import ad_codegen_host as h
r = h.run_through_codegen_ad("cof2d", open(sys.argv[1]).read(),
                             Path("build/fuzz_ad_codegen"))
print("%s %s %s" % (r.kind, r.stdout, r.exit))
PY
)" || fail "native oracle driver crashed"
echo "   native codegen.ad: $ORACLE"
case "$ORACLE" in
    ok\ *) : ;;
    *) fail "the ORACLE lane could not compile/run the fixture ($ORACLE) — with no oracle this gate proves nothing" ;;
esac
ORACLE_OUT="$(echo "$ORACLE" | awk '{print $2}')"
ORACLE_RC="$(echo "$ORACLE" | awk '{print $3}')"
[ -n "$ORACLE_OUT" ] || fail "oracle produced no stdout"

# ---------------------------------------------------------------------------
echo "== 2) LLVM lane, x86_64, run natively =="
bash scripts/adder_cc_llvm.sh "$SRC" "$W/x86.elf" >"$W/x86.log" 2>&1 \
    || { sed 's/^/   | /' "$W/x86.log"; fail "x86 LLVM lane build"; }
grep -q '^; BAILED @' "$W/x86.ll" \
    && fail "x86 .ll has bails — the fixture must stay fully in-subset or the comparison is vacuous: $(grep '^; BAILED @' "$W/x86.ll" | tr '\n' ' ')"
grep -E '^; ADDER_STAT' "$W/x86.ll" | sed 's/^/   /'
X86_OUT="$(timeout 60 "$W/x86.elf")"; X86_RC=$?
echo "   x86 LLVM: stdout=[$X86_OUT] rc=$X86_RC"

# ---------------------------------------------------------------------------
echo "== 3) LLVM lane, aarch64, EXECUTED under qemu-aarch64 =="
"$HOST_AC" --backend=llvm --target=aarch64 "$SRC" "$W/arm.ll" || fail "aarch64 emit"
grep -q 'target triple = "aarch64' "$W/arm.ll" || fail "emitted .ll is not aarch64"
grep -q '^; BAILED @' "$W/arm.ll" \
    && fail "aarch64 .ll has bails: $(grep '^; BAILED @' "$W/arm.ll" | tr '\n' ' ')"
grep -E '^; ADDER_STAT' "$W/arm.ll" | sed 's/^/   /'

# Freestanding aarch64 runtime: _start + the one extern the fixture declares.
# (scripts/adder_llvm_runtime.c is x86-host C; the aarch64 leg needs its own.)
cat > "$W/rt_arm64.s" <<'EOF'
.text
.globl _start
_start:
    mov x0, #0
    mov x1, #0
    bl main
    mov x8, #93                 // aarch64 exit
    svc #0
.globl sys_write
sys_write:
    mov x8, #64                 // aarch64 write
    svc #0
    ret
EOF
"$CLANG" --target=aarch64-linux-gnu -O2 -c -ffreestanding "$W/arm.ll" -o "$W/arm.o" \
    || fail "aarch64 clang codegen"
"$CLANG" --target=aarch64-linux-gnu -c "$W/rt_arm64.s" -o "$W/rt_arm64.o" \
    || fail "aarch64 runtime assemble"
aarch64-linux-gnu-ld -static -nostdlib "$W/rt_arm64.o" "$W/arm.o" -o "$W/arm.elf" \
    || fail "aarch64 link"
ARM_OUT="$(timeout 120 qemu-aarch64 "$W/arm.elf")"; ARM_RC=$?

# ---------------------------------------------------------------------------
# 3b) SLOT SIZE — the one property execution cannot see, checked by INSPECTION.
#
# Stated plainly because the distinction matters: everything else in this gate is
# an EXECUTED result compared against an independent oracle. This step is not. A
# 2-D slot sized as if 1-D (N*esz instead of N*M*esz) does not change any value
# the program computes — the writes and the reads use the SAME address
# arithmetic, so every element still round-trips; the size only decides whose
# frame memory gets stomped. Both a scalar guard (promoted to a register, never
# in the frame) and a neighbouring array local (LLVM lays allocas out as it
# pleases) failed to catch a deliberately under-sized slot when mutation-tested.
# So the alloca byte count is asserted directly, per function, against the
# hand-computed N*M*esz.
echo "== 3b) 2-D alloca sizes (INSPECTION, not execution — see the comment in this gate) =="
ALLOCAS="$(awk '
    /^define /            { fn = $0; sub(/^.*@/, "", fn); sub(/\(.*/, "", fn) }
    /= alloca \[[0-9]+ x i8\]/ { sz = $0; sub(/.*alloca \[/, "", sz); sub(/ x i8\].*/, "", sz);
                                print fn "=" sz }
' "$W/arm.ll")"
echo "$ALLOCAS" | sed 's/^/   /'
# grid_u8         Array[16, Array[32, uint8]]  = 16*32*1 = 512
# grid_u64        Array[64, uint64] neighbour  = 64*8    = 512
#                 Array[8,  Array[4, uint64]]  = 8*4*8   = 256
# grid_u32_chained Array[8, Array[8, uint32]]  = 8*8*4   = 256
# mixed_1d_2d     Array[8, uint32] (1-D)       = 8*4     = 32
#                 Array[4, Array[4, uint32]]   = 4*4*4   = 64
for want in "grid_u8=512" "grid_u64=512" "grid_u64=256" \
            "grid_u32_chained=256" "mixed_1d_2d=32" "mixed_1d_2d=64"; do
    echo "$ALLOCAS" | grep -qx "$want" \
        || fail "expected alloca $want in the emitted aarch64 IR (a 2-D slot sized as if 1-D is invisible to execution — it only stomps neighbouring frame memory)"
done
echo "   all six alloca sizes match N*M*elem_size"
echo "   aarch64 LLVM (qemu-aarch64): stdout=[$ARM_OUT] rc=$ARM_RC"

# ---------------------------------------------------------------------------
echo "== 4) compare all three legs =="
echo "   oracle (native codegen.ad x86) : [$ORACLE_OUT] rc=$ORACLE_RC"
echo "   LLVM x86_64                    : [$X86_OUT] rc=$X86_RC"
echo "   LLVM aarch64 (executed)        : [$ARM_OUT] rc=$ARM_RC"
[ "$X86_OUT" = "$ORACLE_OUT" ] && [ "$X86_RC" = "$ORACLE_RC" ] \
    || fail "x86 LLVM lane diverges from the native oracle"
[ "$ARM_OUT" = "$ORACLE_OUT" ] && [ "$ARM_RC" = "$ORACLE_RC" ] \
    || fail "aarch64 LLVM lane diverges from the native oracle"

echo "RESULT: PASS — container_of + 2-D local arrays EXECUTED on x86_64 and aarch64 match the native codegen.ad oracle exactly ([$ORACLE_OUT] rc=$ORACLE_RC)"
exit 0
