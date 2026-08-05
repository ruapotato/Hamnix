#!/usr/bin/env bash
# scripts/ssa_cluster_lift_diff.sh — DECOMPOSE the SSA-subset ceiling by
# construct CLUSTER, and size each cluster by lift-and-diff over the whole tree.
#
# WHY THIS EXISTS (2026-08-05).  scripts/ssa_lift_diff.sh established that the
# shipped --opt subset is 61.15% and that arming the whole LLVM memory model on
# the analysis lane takes it to 88.23%.  That single 27-point number sizes the
# CEILING but names no target: it lifts every remaining construct at once.  This
# script splits it by cluster.
#
# It does NOT rank by bail share.  A bail-site histogram counts which gate fires
# FIRST, so it cannot size anything: site 66 held 36.9% of all whole-tree bails
# and implementing exactly it moved the subset +0.13 points, because the same
# functions re-bailed one statement later.  Only a counterfactual sizes a target.
#
# THE MECHANISM.  ssa.ad carries six SUBTRACTIVE, analysis-lane-only levers
# (ssa_census_keep_call / _arity / _member / _float / _addr / _nonlocal).  Each
# says "even with ssa_mem_model armed, keep bailing this cluster the way the
# native lane does".  All default to 0, the six ssa_mm_*() predicates then reduce
# to a bare ssa_mem_model read, and only ssa_run_program (the --dump-ssa analysis
# lane) ever sets them — so ssa_emit_program cannot observe a lift and the real
# --opt byte output is unchanged by construction.
#
# THREE READINGS COME OUT OF THE SAME MECHANISM:
#
#   ALLKEEP    memmodel + every keep.  MUST equal the unflagged baseline.  This
#              is the decomposition's own self-check: if the six clusters are
#              exhaustive, holding all six reproduces the native subset exactly,
#              histogram and all.  Any residual is a construct no cluster names,
#              and the table below would be silently under-counting without it.
#
#   ADDITIVE   memmodel + every keep EXCEPT X.  = baseline PLUS cluster X.  This
#              is the honest "what would implementing X alone unlock TODAY"
#              number, and it is the one to rank by.
#
#   MARGINAL   memmodel + keep X only.  = ceiling MINUS cluster X.  What X is
#              still worth once everything else is already in.
#
# ADDITIVE and MARGINAL diverge exactly where gates are ENTANGLED, which is the
# entire reason a histogram misleads.  If additive(A) and additive(B) are both
# small but additive(A+B) is large, the target is the PAIR and neither half is
# worth implementing alone — that is what happened with the local memory model
# (alloca + sized load/store + index + deref, +24.5 points as one piece, ~0
# separately).  The JOINT rows at the bottom test exactly that.
#
# EVERY ROW IS AN UPPER BOUND.  Lifting a gate on the analysis lane can leave
# SVO ops the x86 emitter has no lowering for; ssa_emit.ad's se_op_lowerable
# then falls the function back anyway.  A row says "no MORE than this", never
# "this much".
#
# Usage:
#   bash scripts/ssa_cluster_lift_diff.sh            # whole tree (~40 min)
#   bash scripts/ssa_cluster_lift_diff.sh --kernel   # kernel dirs only
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

SCOPE_ARG="${1:-}"

python3 -c "import sys;sys.path.insert(0,'tests/fuzz');import ad_codegen_host as h;h.build_driver()" || exit 1
mkdir -p build

ALL_CLUSTERS="call arity member float addr nonlocal"

TBL="$(mktemp)"
: > "$TBL"
RC=0

# run_one <label> <driver flags...>
run_one() {
  local label="$1"; shift
  local extra=()
  local a
  # NOTE the `=` form: the flags start with `--`, so `--driver-arg --ssa-x`
  # makes argparse think the value is missing.
  for a in "$@"; do extra+=("--driver-arg=$a"); done
  local out
  out="$(python3 scripts/ssa_subset_census.py --top 8 ${SCOPE_ARG:+$SCOPE_ARG} "${extra[@]}" 2>&1)" || {
    echo "$label: CENSUS FAILED"; echo "$out"; RC=1; return 1; }
  local funcs acc
  funcs="$(printf '%s\n' "$out" | sed -n 's/^functions *: *\([0-9]*\).*/\1/p')"
  acc="$(printf '%s\n' "$out" | sed -n 's/^accepted into subset: *\([0-9]*\).*/\1/p')"
  printf '%s|%s|%s\n' "$label" "$funcs" "$acc" >> "$TBL"
  printf '%s\n' "$out" | sed -n '/top 8 bail SITES/,$p' > "build/ssa_cluster_${label}.sites"
  echo "  $label: $acc / $funcs"
}

# keeps_except <cluster...>  -> emit --ssa-keep-<c> for every cluster NOT listed
keeps_except() {
  local skip=" $* "
  local c
  for c in $ALL_CLUSTERS; do
    case "$skip" in *" $c "*) ;; *) printf -- '--ssa-keep-%s\n' "$c" ;; esac
  done
}

echo "running cluster censuses ${SCOPE_ARG:-(whole tree)} ..."

run_one baseline
run_one ceiling --ssa-memmodel
# shellcheck disable=SC2046
run_one allkeep --ssa-memmodel $(keeps_except)

echo "-- additive: baseline + one cluster --"
for c in $ALL_CLUSTERS; do
  # shellcheck disable=SC2046
  run_one "add_$c" --ssa-memmodel $(keeps_except "$c")
done

echo "-- marginal: ceiling - one cluster --"
for c in $ALL_CLUSTERS; do
  run_one "marg_$c" --ssa-memmodel "--ssa-keep-$c"
done

echo "-- joint: baseline + two/three clusters (entanglement probe) --"
JOINTS="call+member call+addr member+addr call+arity call+member+addr call+member+addr+arity"
for j in $JOINTS; do
  # shellcheck disable=SC2046
  run_one "add_$(echo "$j" | tr '+' '_')" --ssa-memmodel $(keeps_except $(echo "$j" | tr '+' ' '))
done

BASE_ACC="$(awk -F'|' '$1=="baseline"{print $3}' "$TBL")"
CEIL_ACC="$(awk -F'|' '$1=="ceiling"{print $3}' "$TBL")"
KEEP_ACC="$(awk -F'|' '$1=="allkeep"{print $3}' "$TBL")"

echo
echo "=== SSA subset CLUSTER lift-and-diff ${SCOPE_ARG:-(whole tree)} ==="
printf '%-26s %8s %9s %8s %10s %10s\n' CONFIG FUNCS ACCEPTED PCT "vs base" "vs ceil"
awk -F'|' -v base="$BASE_ACC" -v ceil="$CEIL_ACC" '
{
  pct  = ($2 > 0) ? (100.0 * $3 / $2) : 0
  bpts = ($2 > 0) ? (100.0 * ($3 - base) / $2) : 0
  printf "%-26s %8d %9d %7.2f%% %+6d/%+.2fpt %+9d\n", $1, $2, $3, pct, $3 - base, bpts, $3 - ceil
}' "$TBL"

echo
echo "-- SELF-CHECK: are the six clusters EXHAUSTIVE? --"
if [ "$KEEP_ACC" = "$BASE_ACC" ]; then
  echo "  PASS  allkeep ($KEEP_ACC) == baseline ($BASE_ACC): the six clusters"
  echo "        account for the ENTIRE baseline->ceiling gap.  No unnamed"
  echo "        construct hides in the table above."
else
  echo "  FAIL  allkeep ($KEEP_ACC) != baseline ($BASE_ACC), residual"
  echo "        $((KEEP_ACC - BASE_ACC)) functions.  Some construct that separates the"
  echo "        native lane from the memory model is NOT covered by a keep lever,"
  echo "        so every additive row below is an OVER-count by up to that much."
  RC=1
fi

echo
echo "READ THIS.  'vs base' is the ONLY column that sizes a target, and it sizes"
echo "it as an UPPER BOUND: an analysis-lane lift can leave SVO ops the x86"
echo "emitter has no lowering for, in which case se_op_lowerable falls the"
echo "function back anyway.  Never rank by bail share -- site 66 was 36.9% of"
echo "all bails and worth +0.13 points implemented alone."
echo
echo "Compare add_A, add_B and add_A_B.  If the pair beats the sum of the halves,"
echo "the gates are ENTANGLED and the TARGET IS THE PAIR: implementing either"
echo "half alone just moves the bail down one line."
echo
echo "per-config top bail sites in build/ssa_cluster_<config>.sites"
rm -f "$TBL"
exit "$RC"
