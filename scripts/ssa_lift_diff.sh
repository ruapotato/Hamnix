#!/usr/bin/env bash
# scripts/ssa_lift_diff.sh — size an SSA-subset target by LIFTING its gate and
# diffing the ACCEPTED count.  Reproducible; prints a table, not prose.
#
# WHY THIS EXISTS (2026-08-04, re-based onto the landed memory model 2026-08-05):
#   scripts/ssa_subset_census.py ranks bail SITES by how many functions bail
#   there.  That ranking is not a ranking of opportunity.  A function bails at
#   its FIRST failing gate and is counted once, there — so the histogram measures
#   WHICH GATE FIRES FIRST, not how many functions a gate is keeping out of the
#   subset.  An early-checked gate looks huge whether or not it blocks anything.
#
#   Site 66 (SBR_NONPROMOTABLE, address-taken / slot-read scalar locals) was the
#   largest bucket in the whole-tree census at 36.9% of all bails, and was
#   briefed as the next optimizer target ("give the native backend an alloca
#   lowering").  Implementing exactly it moved the accepted subset 36.65% ->
#   36.78%: +27 functions of 21281.  Every one of the rest re-bailed one
#   statement later at `*p`, `p[i]`, a local array or a string literal.  The
#   bail count was an upper bound, and a completely loose one.  What DID move the
#   number was landing the whole CLUSTER as one piece (SVO_ALLOCA + sized
#   LOAD/STORE + index + deref) behind ssa_mem_native: 36.65% -> 61.15%.
#
#   So: never size a subset target from bail share.  Lift the gate, re-run the
#   census, diff `accepted`.  That is what this script automates.
#
# THE AXIS THIS MEASURES TODAY:
#   (default)            ssa_mem_native = 1, ssa_mem_model = 0.  Exactly what
#                        ssa_emit_program arms, i.e. the shipped --opt subset.
#                        This is the census-fidelity invariant that
#                        scripts/test_ssa_census_fidelity.sh pins: an unflagged
#                        census must measure the subset the product applies.
#   --ssa-no-memnative   ssa_mem_native = 0.  Reproduces the PRE-memory-model
#                        native subset, so the value of the landed cluster is a
#                        measured delta on today's tree rather than a remembered
#                        one.
#   --ssa-memmodel       ssa_mem_model = 1: the whole LLVM-style memory model —
#                        float slots, %gs percpu, struct members, `&function`.
#                        This is the CEILING for the memory axis: what the native
#                        subset could reach if it gained every memory lowering
#                        the LLVM lane already has.
#
#   All are ANALYSIS-ONLY: they set ssa_census_mem_native / ssa_census_mem_model,
#   which only ssa_run_program reads.  ssa_emit_program assigns ssa_mem_native /
#   ssa_mem_model itself and never consults the census levers, so the real
#   --opt/ADDER_OPT2 emit lane cannot observe a lift and its byte output is
#   unchanged by construction.  Counting is the only thing they are valid for — a
#   lifted gate may leave SSA that is not emittable, so a row here is an UPPER
#   BOUND on what implementing that gate could unlock, never a promise.
#
# HISTORICAL NOTE — the per-half levers are GONE ON PURPOSE.  An earlier
# revision of this script carried --ssa-lift104 / --ssa-lift105, which SIMULATED
# a native stack slot for each half of the old site 66 so its value could be
# measured before anyone implemented it.  Both measured d(ACC) = +0, separately
# and together.  The real implementation has since landed (ssa_mem_native), and
# it agrees: the halves are worthless alone and the cluster is worth +24.5
# points.  Simulating a gate the compiler now really implements would only add a
# second, driftable copy of it, so the levers were dropped and the finding kept.
#
# Usage:
#   bash scripts/ssa_lift_diff.sh            # whole tree
#   bash scripts/ssa_lift_diff.sh --kernel   # kernel dirs only
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

SCOPE_ARG="${1:-}"

python3 -c "import sys;sys.path.insert(0,'tests/fuzz');import ad_codegen_host as h;h.build_driver()" || exit 1
mkdir -p build

run_one() {
  # $1 = label, rest = extra driver args
  local label="$1"; shift
  local extra=()
  local a
  # NOTE the `=` form: the lift flags themselves start with `--`, so
  # `--driver-arg --ssa-memmodel` makes argparse think the value is missing.
  for a in "$@"; do extra+=("--driver-arg=$a"); done
  local out
  out="$(python3 scripts/ssa_subset_census.py --top 6 ${SCOPE_ARG:+$SCOPE_ARG} "${extra[@]}" 2>&1)" || {
    echo "$label: CENSUS FAILED"; echo "$out"; RC=1; return 1; }
  local funcs acc
  funcs="$(printf '%s\n' "$out" | sed -n 's/^functions *: *\([0-9]*\).*/\1/p')"
  acc="$(printf '%s\n' "$out" | sed -n 's/^accepted into subset: *\([0-9]*\).*/\1/p')"
  printf '%s|%s|%s\n' "$label" "$funcs" "$acc" >> "$TBL"
  printf '%s\n' "$out" | sed -n '/top 6 bail SITES/,$p' > "build/ssa_lift_${label}.sites"
}

TBL="$(mktemp)"
: > "$TBL"
RC=0

echo "running 3 censuses ..."
run_one premem   --ssa-no-memnative
run_one baseline
run_one memmodel --ssa-memmodel

BASE_ACC="$(awk -F'|' '$1=="baseline"{print $3}' "$TBL")"

echo
echo "=== SSA subset lift-and-diff ${SCOPE_ARG:-(whole tree)} ==="
printf '%-10s %9s %9s %8s %9s\n' CONFIG FUNCS ACCEPTED PCT "d(ACC)"
awk -F'|' -v base="$BASE_ACC" '
{
  pct = ($2 > 0) ? (100.0 * $3 / $2) : 0
  printf "%-10s %9d %9d %7.2f%% %+9d\n", $1, $2, $3, pct, $3 - base
}' "$TBL"
echo
echo "per-config top bail sites written to build/ssa_lift_<config>.sites"
echo
echo "READ: d(ACC) is the ONLY column that sizes a target.  A gate whose"
echo "d(ACC) is 0 blocks nothing on its own, however large its bail count."
echo "'baseline' is the shipped --opt subset; d(ACC) is measured against it."
rm -f "$TBL"
if [ "$RC" -ne 0 ]; then
  echo "ssa_lift_diff: one or more censuses FAILED — the table above is partial"
fi
exit "$RC"
