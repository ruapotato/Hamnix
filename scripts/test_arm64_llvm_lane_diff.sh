#!/usr/bin/env bash
# scripts/test_arm64_llvm_lane_diff.sh — EXECUTION differential for the
# **AArch64** LLVM lane (host_ac --backend=llvm --target=aarch64 -> clang ->
# aarch64 ELF -> qemu-aarch64). HOST-ONLY: no qemu-system, no image build.
#
# WHY THIS EXISTS
# ---------------
# scripts/test_llvm_lane_diff.sh closed a real hole on x86: the LLVM lane that
# builds all of userland had NO randomized execution-differential coverage, and
# a signedness miscompile (`lshr` where `ashr` was meant) reached 684 sites in
# 123 of 266 binaries. It was invisible to kobjdiff (different lane) and to
# fuzz_adder_diff.sh (native backend only); it was noticed ONLY because it
# landed in lib/ed25519.ad, where a wrong bit rejects a signature.
#
# That gate emits for x86-64. The AArch64 lane goes through a DIFFERENT code
# path in adder/compiler/ssa_llvm.ad — a different data layout string, a
# different syscall lowering (`svc #0`, x8, ll_aarch64_syscall_nr remapping the
# x86 numbers), and then a completely different LLVM backend. None of that was
# covered by anything: before this gate, the only aarch64 execution evidence in
# the tree was scripts/test_arm64_a10_userland.sh — ONE hand-written program,
# run once. One program is a smoke test, not an instrument.
#
# So the standing assumption ("assume AArch64 has the same hole until you prove
# otherwise") had nothing to answer it. This gate answers it: the SAME
# generator, the SAME by-construction Python oracle, executed on AArch64.
#
# WHAT IT DOES
# ------------
#   1) Runs tests/fuzz/regress_ptr_signedness.ad through the AArch64 lane and
#      pins its exact output against the SAME literal the x86 gate pins. The
#      two arches must agree with the oracle, byte for byte.
#   2) Runs N randomized tests/fuzz/llvm_signedness_fuzz.py programs through
#      the AArch64 lane and compares stdout + exit status against the
#      by-construction Python oracle. A divergence is an AArch64 LLVM-lane
#      miscompile.
#
# HOW IT RUNS AARCH64 CODE WITHOUT A CROSS LIBC
# ---------------------------------------------
# clang is a cross compiler out of the box, and binutils-aarch64-linux-gnu
# supplies as/ld, but there is no aarch64 glibc here. The programs need exactly
# two things from a runtime — an entry point and write(2) — so
# scripts/adder_llvm_runtime_aarch64.S supplies both directly against the
# kernel ABI and the result links -static -nostdlib and runs under qemu-aarch64
# (qemu-user, NOT qemu-system: no boot, ~10 ms per program).
#
# WHAT A FAILURE MEANS, AND WHAT IT DOES NOT
# ------------------------------------------
# This is EXECUTION evidence, not an emitted-code diff: the numbers below were
# produced by aarch64 instructions actually running. A bail (`unsupported`) is
# a FAIL, not a shrug — the generator is written to stay inside the SSA subset,
# so a bail is a silent loss of the only coverage this lane has. A run that
# executed zero programs is a FAIL for the same reason: it proves nothing and
# must not read as green.
#
# Usage:
#   bash scripts/test_arm64_llvm_lane_diff.sh          # 25 programs, seed 1
#   FUZZ_COUNT=200 FUZZ_SEED=9 bash scripts/test_arm64_llvm_lane_diff.sh
#
# Exit: 0 PASS, 1 FAIL (observed miscompile / no coverage),
#       125 INCONCLUSIVE (missing cross toolchain or qemu-user — never 0).
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

FUZZ_COUNT="${FUZZ_COUNT:-25}"
FUZZ_SEED="${FUZZ_SEED:-1}"
# The work dir must live INSIDE the repo: host_ac derives a module slug from
# the input PATH, and a non-[A-Za-z0-9_] byte in it (a '-' in an agent worktree
# name) corrupts private-name mangling.
WORK="$PROJ_ROOT/build/arm64_llvm_lane_diff"

# 125 = INCONCLUSIVE (scripts/_verdict.sh): the assertion was never observed.
# Never exit 0 for a missing tool — that is the false-green this lane is for.
inconc() { echo "[arm64_llvm_diff] INCONCLUSIVE $*"; exit 125; }
fail()   { echo "[arm64_llvm_diff] FAIL $*"; exit 1; }

command -v python3          >/dev/null 2>&1 || inconc "python3 not found"
command -v qemu-aarch64     >/dev/null 2>&1 || inconc "qemu-aarch64 (qemu-user) not found; apt install qemu-user"
command -v aarch64-linux-gnu-as >/dev/null 2>&1 || inconc "aarch64 binutils not found; apt install binutils-aarch64-linux-gnu"
command -v aarch64-linux-gnu-ld >/dev/null 2>&1 || inconc "aarch64 binutils not found; apt install binutils-aarch64-linux-gnu"
CLANG="${BENCH_CLANG:-}"
if [ -z "$CLANG" ]; then
    if command -v clang-19 >/dev/null 2>&1; then CLANG=clang-19; else CLANG=clang; fi
fi
command -v "$CLANG" >/dev/null 2>&1 || inconc "$CLANG not found (the LLVM lane needs clang)"
RT_SRC="$PROJ_ROOT/scripts/adder_llvm_runtime_aarch64.S"
[ -f "$RT_SRC" ] || fail "missing $RT_SRC"
GEN="$PROJ_ROOT/tests/fuzz/llvm_signedness_fuzz.py"
[ -f "$GEN" ] || fail "missing $GEN"

rm -rf "$WORK"; mkdir -p "$WORK"

# host_ac.elf is CONCATENATED from adder/compiler/*.ad (ssa_llvm.ad included),
# so a stale one silently measures the OLD compiler.
if [ -n "${ADDER_HOST_AC:-}" ]; then
    HOST_AC="$ADDER_HOST_AC"
else
    echo "[arm64_llvm_diff] bootstrapping host_ac.elf (LLVM-capable)"
    # shellcheck source=_adder_cc.sh
    source "$PROJ_ROOT/scripts/_adder_cc.sh"
    adder_cc_bootstrap >"$WORK/bootstrap.log" 2>&1 \
        || { sed 's/^/[arm64_llvm_diff]   | /' "$WORK/bootstrap.log"; fail "compiler bootstrap failed"; }
    HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
fi
[ -x "$HOST_AC" ] || fail "no host_ac.elf at $HOST_AC"

"$CLANG" --target=aarch64-linux-gnu -c "$RT_SRC" -o "$WORK/rt.o" 2>"$WORK/rt.log" \
    || aarch64-linux-gnu-as -o "$WORK/rt.o" "$RT_SRC" 2>>"$WORK/rt.log" \
    || { sed 's/^/[arm64_llvm_diff]   | /' "$WORK/rt.log"; fail "could not assemble the aarch64 runtime"; }

# run_a64 <src.ad> <tag> -> echoes "<status> <stdout-with-newlines-as-spaces> <exit>"
run_a64() {
    local src="$1" tag="$2"
    local ll="$WORK/$tag.ll" obj="$WORK/$tag.o" elf="$WORK/$tag.elf" log="$WORK/$tag.log"
    if ! "$HOST_AC" --backend=llvm --target=aarch64 "$src" "$ll" >"$log" 2>&1; then
        echo "builderror 0"; return
    fi
    if ! grep -q "^define i64 @main(" "$ll"; then
        echo "unsupported 0"; return          # main's body bailed the SSA subset
    fi
    # An external `declare` other than the runtime's sys_write means some
    # callee bailed — the exact shape of the ARM64 link bug. Not a pass.
    if grep '^declare' "$ll" | grep -v '@sys_write' | grep -q .; then
        grep '^declare' "$ll" | grep -v '@sys_write' >>"$log"
        echo "unsupported 0"; return
    fi
    if ! "$CLANG" -O2 --target=aarch64-linux-gnu -c -ffreestanding -fno-pic \
            -fno-stack-protector -fno-addrsig -mcmodel=small \
            "$ll" -o "$obj" >>"$log" 2>&1; then
        echo "builderror 0"; return
    fi
    if ! aarch64-linux-gnu-ld -static -nostdlib "$WORK/rt.o" "$obj" -o "$elf" >>"$log" 2>&1; then
        echo "builderror 0"; return
    fi
    local out rc
    out="$(timeout 30 qemu-aarch64 "$elf" 2>/dev/null)"; rc=$?
    echo "ok ${out//$'\n'/ } $rc"
}

# ---- 1) the known-bug fixture, pinned to the SAME literal as the x86 gate ---
echo "[arm64_llvm_diff] fixture: tests/fuzz/regress_ptr_signedness.ad (aarch64)"
FIX="$(run_a64 tests/fuzz/regress_ptr_signedness.ad fixture)"
echo "[arm64_llvm_diff]   result: $FIX  (expect 'ok 18446744073709550828 236')"
[ "$FIX" = "ok 18446744073709550828 236" ] \
    || fail "AArch64 LLVM lane miscompiled the element-signedness fixture: $FIX"

# ---- 2) randomized differential ------------------------------------------
echo "[arm64_llvm_diff] differential: count=$FUZZ_COUNT seed=$FUZZ_SEED"
ACC=0; UNS=0; BAD=0; ERR=0
for ((i = 0; i < FUZZ_COUNT; i++)); do
    seed=$((FUZZ_SEED * 100003 + i))
    src="$WORK/sg_$seed.ad"
    want="$(python3 "$GEN" "$seed" "$src")" || fail "generator failed for seed $seed"
    got="$(run_a64 "$src" "sg_$seed")"
    case "$got" in
        unsupported*) UNS=$((UNS + 1))
                      echo "[arm64_llvm_diff]   seed $seed: UNSUPPORTED (SSA-subset bail)"
                      continue ;;
        builderror*)  ERR=$((ERR + 1))
                      echo "[arm64_llvm_diff]   seed $seed: BUILD ERROR (see $WORK/sg_$seed.log)"
                      continue ;;
    esac
    ACC=$((ACC + 1))
    if [ "${got#ok }" != "$want" ]; then
        BAD=$((BAD + 1))
        echo "[arm64_llvm_diff]   seed $seed: MISCOMPILE want='$want' got='${got#ok }'"
        echo "[arm64_llvm_diff]     repro: python3 tests/fuzz/llvm_signedness_fuzz.py $seed /tmp/r.ad && \\"
        echo "[arm64_llvm_diff]            build/cutover/host_ac.elf --backend=llvm --target=aarch64 /tmp/r.ad /tmp/r.ll"
    fi
done

echo "[arm64_llvm_diff] ===== AARCH64 LLVM-LANE DIFFERENTIAL REPORT ====="
echo "[arm64_llvm_diff] programs generated : $FUZZ_COUNT"
echo "[arm64_llvm_diff] built + RAN on aarch64 (qemu-user) : $ACC"
echo "[arm64_llvm_diff]   MISCOMPILED      : $BAD"
echo "[arm64_llvm_diff] SSA-subset bails   : $UNS   (must be 0 -- this generator stays in-subset)"
echo "[arm64_llvm_diff] build errors       : $ERR"
echo "[arm64_llvm_diff] ==============================================="

[ "$ERR" -eq 0 ] || fail "$ERR program(s) failed to BUILD through the AArch64 LLVM lane"
[ "$UNS" -eq 0 ] || fail "$UNS program(s) bailed the SSA subset; this generator must stay inside it"
[ "$BAD" -eq 0 ] || fail "$BAD AArch64 LLVM-lane miscompile(s)"
[ "$ACC" -ge 1 ] || fail "0 programs actually ran -- no coverage, verdict UNKNOWN"
echo "[arm64_llvm_diff] PASS — $ACC programs EXECUTED on aarch64 matched the oracle exactly"
