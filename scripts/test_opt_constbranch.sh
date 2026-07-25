#!/usr/bin/env bash
# scripts/test_opt_constbranch.sh — focused, host-only correctness + firing test
# for the native optimizer's Phase-1.5 CONSTANT-CONDITION BRANCH FOLDING pass
# (opt.ad opt_constbranch_function / opt_try_condfold_expr).
#
# WHAT IT PROVES (no QEMU):
#   1. The pass FIRES: with --opt ON, the dump driver's CONSTBRANCH counter is
#      > 0 over a corpus of if/elif/else/while/ternary whose condition is a
#      provable, side-effect-free compile-time constant.
#   2. The pass is CORRECT: each program, run through codegen.ad with --opt ON,
#      produces the SAME observable exit/stdout as with --opt OFF (which is
#      itself objdiff-proven == the seed oracle). Folding the dead arm changed
#      nothing observable, and the SURVIVING arm is the one that would actually
#      have run.
#   3. The SAFETY guard holds: a condition with a SIDE EFFECT (a call) is NOT
#      folded (CONSTBRANCH=0 for that unit) and the side effect still executes —
#      a control-flow miscompile is exactly what this asserts against.
#
# Complements the broad ADDER_OPT=1 fuzzer lane (scripts/fuzz_adder_diff.sh):
# here we hand-craft the branch shapes so the counter is guaranteed to move and
# each fold's semantics are pinned to a known answer (including the deliberate
# NON-folds: while-true, ordering compares, side-effecting conditions).
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# LEGACY opt1 LANE GUARD (added 2026-07-25).  Every "the lever FIRED" assertion
# below targets the opt1 optimizer lane (opt.ad's AST passes + the
# ra_enabled-gated codegen levers).  Commit ba2e4bcf (2026-07-21) retired that
# lane — `--opt` now arms the SSA pipeline and the dump driver never calls
# ra_enable() on the emission path — so those counters are structurally 0 while
# the values stay CORRECT (opt == off == reference).  The helper PROBES the lane
# and skips loudly only while it is genuinely retired; it re-arms this guard
# automatically the moment the lane comes back.  See docs/ci_status_2026-07-25.md.
source "$PROJ_ROOT/scripts/lib_opt1_lane.sh"
opt1_require_lane "test_opt_constbranch"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_constbranch"); WD.mkdir(parents=True, exist_ok=True)

# Each case: (name, source, expected_exit, expect_fold_fires)
CASES = []

# 1. if CONST_TRUE: keep then-arm, drop else.
CASES.append(("if_true", """
def main() -> int:
    r: int = 1
    if 1:
        r = 10
    else:
        r = 20
    return r
""", 10, True))

# 2. if CONST_FALSE: drop then-arm, keep else.
CASES.append(("if_false", """
def main() -> int:
    r: int = 1
    if 0:
        r = 10
    else:
        r = 20
    return r
""", 20, True))

# 3. if CONST_FALSE with NO else: whole construct is a no-op.
CASES.append(("if_false_noelse", """
def main() -> int:
    r: int = 5
    if 0:
        r = 99
    return r
""", 5, True))

# 4. Equality-compare condition (the fuzz-bait shape): `1 != 0` -> TRUE.
CASES.append(("if_neq_true", """
def main() -> int:
    r: int = 0
    if cast[int64](1) != cast[int64](0):
        r = 7
    return r
""", 7, True))

# 5. Foldable arithmetic condition `(2 + 3) - 5` -> 0 -> FALSE.
CASES.append(("if_arith_false", """
def main() -> int:
    r: int = 3
    if (2 + 3) - 5:
        r = 100
    return r
""", 3, True))

# 6. elif chain: primary false, an elif true -> keep that elif's body.
CASES.append(("elif_true", """
def main() -> int:
    r: int = 0
    if 0:
        r = 1
    elif 1:
        r = 2
    else:
        r = 3
    return r
""", 2, True))

# 7. Short-circuit AND of constants: `1 and 0` -> FALSE.
CASES.append(("if_and_false", """
def main() -> int:
    r: int = 8
    if 1 and 0:
        r = 50
    return r
""", 8, True))

# 8. Logical NOT of a constant: `not 0` -> TRUE.
CASES.append(("if_not_true", """
def main() -> int:
    r: int = 0
    if not 0:
        r = 4
    return r
""", 4, True))

# 9. while CONST_FALSE: loop is removed entirely (body never runs).
CASES.append(("while_false", """
def main() -> int:
    r: int = 11
    while 0:
        r = r + 1
    return r
""", 11, True))

# 10. Ternary with const condition -> taken arm. NOTE: codegen.ad's BASE subset
#     does not compile a bare ND_CONDITIONAL (the --opt-OFF path cgfails), so
#     this case is flagged off_unsupported: we assert ONLY that the --opt run
#     folds it and yields the correct value (the fold itself makes the program
#     compilable; the not-taken arm is dropped before codegen).
CASES.append(("ternary_true", """
def main() -> int:
    r: int = 1 if 1 else 2
    return r
""", 1, True, True))

# ---- DELIBERATE NON-FOLDS (safety): must NOT fold, must stay correct --------

# 11. SIDE-EFFECTING condition: `bump()` increments g and returns 1. If the
#     branch were (wrongly) folded by dropping the call, g would stay 0 and the
#     result would be 100 not 107. CONSTBRANCH must be 0 for this unit.
CASES.append(("side_effect_cond", """
g: int = 0
def bump() -> int:
    g = g + 7
    return 1
def main() -> int:
    if bump() != 0:
        g = g + 100
    return g
""", 107, False))

# 12. Ordering compare `2 < 3` — deliberately LEFT UNKNOWN (signedness-sensitive
#     in codegen; we never fold it). Must stay correct, CONSTBRANCH=0.
CASES.append(("ordering_not_folded", """
def main() -> int:
    r: int = 0
    if 2 < 3:
        r = 9
    return r
""", 9, False))

# 13. NON-constant condition (reads a local): not folded, stays correct.
CASES.append(("nonconst_cond", """
def main() -> int:
    n: int = 1
    r: int = 0
    if n:
        r = 6
    return r
""", 6, False))

total_cb = 0
fired_units = 0
fails = 0
for case in CASES:
    name, src, expected, expect_fire = case[0], case[1], case[2], case[3]
    # Optional 5th field: the --opt-OFF baseline is UNSUPPORTED by codegen.ad's
    # base subset (e.g. a bare ternary), so we skip the A/B agreement check and
    # assert only the --opt run's correctness + fold.
    off_unsupported = len(case) > 4 and case[4]
    r_opt = h.run_through_codegen_ad(name, src, WD, opt=True)
    if off_unsupported:
        ok_kind = (r_opt.kind == "ok")
        same_exit = (r_opt.exit == expected)
        agree = True
    else:
        r_off = h.run_through_codegen_ad(name, src, WD, opt=False)
        ok_kind = (r_opt.kind == "ok") and (r_off.kind == "ok")
        same_exit = (r_opt.exit == expected) and (r_off.exit == expected)
        agree = (r_opt.exit == r_off.exit) and (r_opt.stdout == r_off.stdout)
    cb = getattr(r_opt, "constbranch", 0) if r_opt.kind == "ok" else -1

    if cb > 0:
        fired_units += 1
        total_cb += cb

    status = "OK"
    if not (ok_kind and same_exit and agree):
        status = "FAIL"
        fails += 1
    if expect_fire and cb <= 0:
        status = "FAIL(no-fire)"
        fails += 1
    if (not expect_fire) and cb != 0:
        status = "FAIL(folded-unsafe)"
        fails += 1

    off_exit = "n/a" if off_unsupported else r_off.exit
    print(f"[{name}] {status}  opt_exit={r_opt.exit} off_exit={off_exit} "
          f"expected={expected} CONSTBRANCH={cb}")

print("=" * 56)
print(f"[opt_constbranch] units that folded: {fired_units}   total folds: {total_cb}")
if fails == 0:
    print("[opt_constbranch] PASS — const-branch folding fires, is behavior-"
          "preserving, and never folds a side-effecting condition")
    sys.exit(0)
else:
    print(f"[opt_constbranch] FAIL — {fails} problem(s)")
    sys.exit(1)
PY
