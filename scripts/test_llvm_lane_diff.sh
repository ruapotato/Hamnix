#!/usr/bin/env bash
# scripts/test_llvm_lane_diff.sh — EXECUTION differential for the LLVM lane
# (host_ac --backend=llvm -> clang -> run), against the fuzzer's
# by-construction oracle.  HOST-ONLY: no QEMU, no image build.
#
# WHY THIS EXISTS
# ---------------
# scripts/build_user.sh sends EVERY user app through host_ac --backend=llvm
# into clang by default (272 LLVM / 2 native at last count). That lane had NO
# execution-differential coverage of any kind:
#
#   * scripts/fuzz_adder_diff.sh runs the NATIVE codegen.ad backend (and, under
#     --opt/ADDER_OPT2, the native SSA emitter). It never emits a .ll.
#   * scripts/test_native_vs_seed_kobjdiff.sh compares the native lane against
#     the Python seed — a lane the LLVM emitter does not share.
#   * scripts/bench_llvm.sh does run the LLVM lane, but it is a PERFORMANCE
#     harness on a fixed benchmark set, not a randomized correctness oracle.
#
# So a miscompile confined to the LLVM lane shipped in essentially all of
# userland with both existing instruments green. That is exactly what happened
# with the ssa_expr_sgn signedness default (`o[i] >> 16` on a `Ptr[int64]`
# parameter emitting `lshr` instead of `ashr`): the ONLY reason anyone noticed
# is that it happened to land in lib/ed25519.ad, where a wrong bit means a
# rejected signature and /bin/hpm refuses to install anything. A quieter victim
# would still be shipping.
#
# WHAT IT DOES
# ------------
#   1) Runs tests/fuzz/regress_ptr_signedness.ad through the LLVM lane and
#      pins its exact output. This is the known-bug fixture: pointer/cast/
#      call/member element signedness, every input negative or bit-63-set.
#   2) Runs N randomized tests/fuzz/llvm_signedness_fuzz.py programs through
#      the LLVM lane and compares stdout + exit status against a
#      by-construction Python oracle. Any divergence is an LLVM-lane
#      miscompile. (adder_fuzzer.py is NOT usable here: its main() reliably
#      bails the SSA subset, so the lane emits no @main and every program
#      comes back "unsupported" — a differential that can never run a program
#      is not an instrument.)
#
# The generator is written to stay INSIDE the SSA subset, so an SSA bail is a
# silent loss of the only coverage this lane has and FAILS the gate. Likewise
# a run that executed zero programs fails rather than exiting 0: a lane that
# emits nothing must not read as green.
#
# Usage:
#   bash scripts/test_llvm_lane_diff.sh          # 25 programs, seed 1
#   FUZZ_COUNT=200 FUZZ_SEED=9 bash scripts/test_llvm_lane_diff.sh
#
# Exit: 0 pass, 1 miscompile / no coverage, 2 missing tooling.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

FUZZ_COUNT="${FUZZ_COUNT:-25}"
FUZZ_SEED="${FUZZ_SEED:-1}"
# NOTE: the work dir must live INSIDE the repo. host_ac derives a module slug
# from the input PATH, and until this commit any non-[A-Za-z0-9_] byte in it
# (a '-' in an agent worktree name, say) corrupted the private-name mangling.
WORK="$PROJ_ROOT/build/llvm_lane_diff"

skip() { echo "[llvm_lane_diff] SKIP $*"; exit 2; }
fail() { echo "[llvm_lane_diff] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || skip "python3 not found"
[ "$(uname -m)" = "x86_64" ] || skip "host $(uname -m), need x86_64 to run the ELFs"
CLANG="${BENCH_CLANG:-}"
if [ -z "$CLANG" ]; then
    if command -v clang-19 >/dev/null 2>&1; then CLANG=clang-19; else CLANG=clang; fi
fi
command -v "$CLANG" >/dev/null 2>&1 || skip "$CLANG not found (LLVM lane needs clang)"

rm -rf "$WORK"; mkdir -p "$WORK"

echo "[llvm_lane_diff] bootstrapping host_ac.elf (LLVM-capable)"
# shellcheck source=_adder_cc.sh
source "$PROJ_ROOT/scripts/_adder_cc.sh"
adder_cc_bootstrap || fail "compiler bootstrap failed"

run_llvm() {   # run_llvm <src.ad> <tag> -> echoes "<status> <stdout> <exit>"
    local src="$1" tag="$2"
    local elf="$WORK/$tag.elf" log="$WORK/$tag.log"
    if ! bash scripts/adder_cc_llvm.sh "$src" "$elf" >"$log" 2>&1; then
        if grep -q 'BAILED\|no @main\|undefined reference' "$log"; then
            echo "unsupported  0"
        else
            echo "builderror  0"
        fi
        return
    fi
    local out rc
    out="$(timeout 20 "$elf" 2>/dev/null)"; rc=$?
    echo "ok ${out//$'\n'/ } $rc"
}

# ---- 1) the known-bug fixture -------------------------------------------
echo "[llvm_lane_diff] fixture: tests/fuzz/regress_ptr_signedness.ad"
FIX="$(run_llvm tests/fuzz/regress_ptr_signedness.ad fixture)"
echo "[llvm_lane_diff]   result: $FIX  (expect 'ok 18446744073709550828 236')"
[ "$FIX" = "ok 18446744073709550828 236" ] \
    || fail "LLVM lane miscompiled the element-signedness fixture: $FIX"

# ---- 2) randomized differential -----------------------------------------
# Programs come from tests/fuzz/llvm_signedness_fuzz.py, NOT adder_fuzzer.py:
# adder_fuzzer's main() reliably bails the SSA subset (SBR_MEMORY -- 2-D array
# globals, float traffic), so the LLVM lane emits no @main for it and every
# program returns "unsupported". A differential that can never run a program
# is not an instrument. The dedicated generator emits SSA-subset-clean
# programs whose only subject is element signedness, with the same style of
# by-construction oracle.
echo "[llvm_lane_diff] differential: count=$FUZZ_COUNT seed=$FUZZ_SEED"
ACC=0; UNS=0; BAD=0; ERR=0
for ((i = 0; i < FUZZ_COUNT; i++)); do
    seed=$((FUZZ_SEED * 100003 + i))
    src="$WORK/sg_$seed.ad"
    want="$(python3 tests/fuzz/llvm_signedness_fuzz.py "$seed" "$src")" \
        || fail "generator failed for seed $seed"
    got="$(run_llvm "$src" "sg_$seed")"
    case "$got" in
        unsupported*) UNS=$((UNS + 1))
                      echo "[llvm_lane_diff]   seed $seed: UNSUPPORTED (SSA-subset bail)"
                      continue ;;
        builderror*)  ERR=$((ERR + 1))
                      echo "[llvm_lane_diff]   seed $seed: BUILD ERROR (see $WORK/sg_$seed.log)"
                      continue ;;
    esac
    ACC=$((ACC + 1))
    if [ "${got#ok }" != "$want" ]; then
        BAD=$((BAD + 1))
        echo "[llvm_lane_diff]   seed $seed: MISCOMPILE want='$want' got='${got#ok }'"
        echo "[llvm_lane_diff]     repro: python3 tests/fuzz/llvm_signedness_fuzz.py $seed /tmp/r.ad \\"
        echo "[llvm_lane_diff]            && bash scripts/adder_cc_llvm.sh /tmp/r.ad /tmp/r.elf && /tmp/r.elf"
    fi
done

echo "[llvm_lane_diff] ===== LLVM-LANE DIFFERENTIAL REPORT ====="
echo "[llvm_lane_diff] programs generated : $FUZZ_COUNT"
echo "[llvm_lane_diff] built + ran        : $ACC"
echo "[llvm_lane_diff]   MISCOMPILED      : $BAD"
echo "[llvm_lane_diff] SSA-subset bails    : $UNS   (must be 0 -- this generator stays in-subset)"
echo "[llvm_lane_diff] build errors       : $ERR"
echo "[llvm_lane_diff] ========================================="

[ "$ERR" -eq 0 ] || fail "$ERR program(s) failed to BUILD through the LLVM lane"
# llvm_signedness_fuzz.py is written to stay INSIDE the SSA subset, so a bail
# here is a silent loss of the only coverage this lane has -- not a shrug.
[ "$UNS" -eq 0 ] || fail "$UNS program(s) bailed the SSA subset; this generator must stay inside it"
[ "$BAD" -eq 0 ] || fail "$BAD LLVM-lane miscompile(s)"
# A run that executed nothing proves nothing. Say so instead of exiting 0.
[ "$ACC" -ge 1 ] || fail "0 programs actually ran -- no coverage, verdict UNKNOWN"
echo "[llvm_lane_diff] PASS"
