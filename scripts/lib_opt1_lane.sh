# scripts/lib_opt1_lane.sh — shared guard for the test_opt_* battery.
#
# Source this at the top of any optimizer guard whose "the pass FIRED"
# assertions are written against the LEGACY opt1 lane (adder/compiler/opt.ad's
# AST passes + the ra_enabled-gated codegen levers in codegen.ad/regalloc.ad):
#
#     source "$(dirname "${BASH_SOURCE[0]}")/lib_opt1_lane.sh"
#     opt1_require_lane "test_opt_dce"
#
# opt1_require_lane EMPIRICALLY probes (scripts/_opt1_lane_probe.py) whether
# that lane is still wired on the --opt emission path.  Commit ba2e4bcf
# (2026-07-21) retired it: opt.ad is deleted and `--opt` now arms the SSA
# pipeline instead, so those counters can never move.  When the probe says
# "retired" the guard prints a LOUD, machine-greppable SKIPPED line and exits 0;
# when it says "active" (i.e. somebody re-armed the lane, or the SSA rewrite
# reinstated the counters) the guard runs for real and a failure is a REAL bug.
#
# The probe is content-hash cached against the dump driver's inputs, so ANY
# compiler/driver edit re-probes automatically — this is self-healing, not a
# hardcoded skip list.
#
# Correctness is NOT skipped away: in every case observed on 2026-07-25 the
# failing guards reported opt_exit == off_exit == expected (values correct,
# counters zero).  The broad behavioural coverage that used to ride along with
# these guards still runs elsewhere: scripts/fuzz_adder_diff.sh (differential
# fuzzer, ADDER_OPT2 lane) and the SSA-pipeline guards.
#
# TRACKING: docs/ci_status_2026-07-25.md  /  docs/adder_ssa_optimizer_design.md
#   Re-enable condition: the SSA optimizer rewrite reaches Phase-4 cutover and
#   either re-arms the codegen levers under --opt or these guards are rewritten
#   against the SSAOPT_* counters the dump driver already emits.

OPT1_TRACKING_DOC="docs/ci_status_2026-07-25.md"

# opt1_lane_state -> echoes "active" | "retired" | "unknown"
opt1_lane_state() {
  local root state
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if state="$(cd "$root" && python3 scripts/_opt1_lane_probe.py 2>/dev/null)"; then
    case "$state" in
      active|retired) echo "$state"; return 0 ;;
    esac
  fi
  echo "unknown"
}

# opt1_require_lane <test-name> [extra note]
#   Exits 0 with a SKIPPED banner when the legacy lane is retired.
#   Returns (does nothing) when the lane is active OR the probe is inconclusive
#   — an inconclusive probe must never silence a test.
opt1_require_lane() {
  local name="${1:-$(basename "$0" .sh)}"
  local note="${2:-}"
  local state
  state="$(opt1_lane_state)"
  case "$state" in
    retired)
      echo "SKIPPED: --opt legacy opt1 optimizer lane is RETIRED (ba2e4bcf, 2026-07-21) — $name asserts counters that can no longer fire"
      echo "SKIPPED-REASON: feature intentionally OFF pending the SSA optimizer rewrite; NOT a broken optimization"
      echo "SKIPPED-EVIDENCE: scripts/_opt1_lane_probe.py — no legacy counter is higher with --opt ON than OFF; --dump-regalloc positive control passes"
      echo "SKIPPED-TRACKING: $OPT1_TRACKING_DOC (see docs/adder_ssa_optimizer_design.md for the replacement pipeline)"
      [ -n "$note" ] && echo "SKIPPED-NOTE: $note"
      echo "[$name] SKIP"
      exit 0
      ;;
    unknown)
      echo "[$name] opt1-lane probe INCONCLUSIVE — running the guard for real" >&2
      ;;
  esac
}
