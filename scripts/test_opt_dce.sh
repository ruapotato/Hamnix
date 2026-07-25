#!/usr/bin/env bash
# scripts/test_opt_dce.sh — focused, host-only correctness + firing test for the
# native optimizer's Phase-8 Dead Code Elimination pass (opt.ad opt_dce_function).
#
# WHAT IT PROVES (no QEMU):
#   1. The DCE pass FIRES: with --opt ON, the dump driver's DCE counter is > 0
#      over a corpus of programs that each contain a provably-dead local.
#   2. The pass is CORRECT: each program, run through codegen.ad with --opt ON,
#      produces the SAME observable result (exit status / stdout) as the seed
#      oracle (codegen_x86.py) — i.e. removing the dead locals changed nothing.
#   3. The barrier holds: a program whose dead-looking local is kept alive by an
#      address-of / call removes NOTHING (DCE=0 for that unit).
#
# This is a targeted complement to the broad ADDER_OPT=1 fuzzer lane
# (scripts/fuzz_adder_diff.sh), which asserts behavioral identity across a
# random corpus; here we hand-craft the dead-local shapes so the counter is
# guaranteed to move and the per-shape semantics are pinned to a known answer.
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
opt1_require_lane "test_opt_dce"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_dce"); WD.mkdir(parents=True, exist_ok=True)

# Each case: (name, source, expected_exit, expect_dce_fires)
# The program's exit status is the observable. A dead local must NOT change it.
CASES = []

# 1. Plain dead local: computed, never read.
CASES.append(("dead_simple", """
def main() -> int:
    x: int = 5 + 3
    y: int = 41
    return y
""", 41, True, 1))

# 2. Dead local whose init is itself pure arithmetic over other locals.
CASES.append(("dead_arith", """
def main() -> int:
    a: int = 7
    b: int = 6
    dead: int = a * b + 2
    return a + b
""", 13, True, 1))

# 3. Fixpoint: dead2's only use is in dead1's init; removing dead1 frees dead2.
#    (dead1 is read nowhere; dead2 is read only by dead1.) Both must vanish.
CASES.append(("dead_chain", """
def main() -> int:
    keep: int = 9
    dead2: int = keep + 1
    dead1: int = dead2 * 2
    return keep
""", 9, True, 2))

# 4. NOT dead: y is read in the return, so it must be kept (DCE may still fire on
#    nothing here -> we only assert correctness, not firing).
CASES.append(("live_local", """
def main() -> int:
    y: int = 20 + 2
    return y
""", 22, False, 0))

# 5. Per-name escape, amid a kept addr-taken local: `dead` is never read and its
#    address is never taken -> it IS removed even though `z`'s address escapes.
#    `z` must be KEPT (address taken) and the result correct. This is the refined
#    per-name escape rule replacing the old whole-function barrier bail.
CASES.append(("escape_mixed", """
def main() -> int:
    z: int = 4
    p: Ptr[int] = &z
    dead: int = 99
    return z
""", 4, True, 1))

# 6. dcecopy-shape amid a CALL: a copy chain (b=a; c=b; d=c) fully forwarded, a
#    dead arithmetic chain (dead1->dead2->dead3, none read), and a helper CALL
#    present. The OLD whole-function barrier removed NOTHING here (a call in the
#    fn killed DCE). The new per-name escape rule removes the dead chain + the
#    forwarded copies even with the call. Result = the live value; seed-exact.
CASES.append(("dcecopy_call", """
def ident(v: int) -> int:
    return v
def main() -> int:
    a: int = 7
    b: int = a
    c: int = b
    d: int = c
    dead1: int = a * 99 + 7
    dead2: int = dead1 + a
    dead3: int = dead2 * 3
    live: int = ident(0)
    return d + live
""", 7, True, 1))

# 7. MUST-KEEP — side-effecting "dead-looking" init: `s = f()` whose result is
#    never read still must run f() (a call is NOT pure; ir_lower_pure_expr rejects
#    it), so the decl is KEPT. We can't observe the side effect without globals,
#    but ir-purity guarantees a call-init decl is never a DCE candidate; the
#    correctness check (opt==off==expected) plus DCE-count assertion pin it.
CASES.append(("keep_call_init", """
def f() -> int:
    return 5
def main() -> int:
    s: int = f()
    return 9
""", 9, False, 0))

# 8. MUST-KEEP — store to a LATER-READ local: `x = 1` then `x = 2` then read x.
#    The first store is dead but partial-liveness is not modelled; the name IS
#    read (x in return), so the global-unused proof fails and NOTHING is removed.
#    Correctness pinned: x == 2.
CASES.append(("keep_later_read", """
def main() -> int:
    x: int = 1
    x = 2
    return x
""", 2, False, 0))

# 9. MUST-KEEP — address-taken local read through the pointer: w is address-taken
#    (&w), so even though w is not named in the return, the pointer read p[0]
#    observes it -> w must be KEPT. The per-name escape check sees &w and refuses.
CASES.append(("keep_addr_taken", """
def main() -> int:
    w: int = 3
    p: Ptr[int] = &w
    return p[0]
""", 3, False, 0))

# 10. CALL-ARG UNDER-COUNT regression: x/y/z are locals used ONLY as the 1st/2nd/
#     3rd arguments of a call (and nowhere else). DCE's use counter must follow
#     the nd_next argument chain — pre-fix it counted only the 1st arg, deemed y
#     and z dead, deleted their decls, and codegen ABORTED (cgfail) because the
#     slots were gone. A genuinely-dead local (`gone`) keeps DCE firing. The call
#     args must SURVIVE; add3(3,4,5) = 12.
CASES.append(("callarg_chain", """
def add3(a: int, b: int, c: int) -> int:
    return a + b + c
def main() -> int:
    x: int = 3
    y: int = 4
    z: int = 5
    gone: int = 77
    return add3(x, y, z)
""", 12, True, 1))

total_dce = 0
fired_units = 0
fails = 0
for name, src, expected, expect_fire, exp_dce in CASES:
    # codegen.ad WITH --opt ON (DCE active); carries the per-run DCE count.
    r_opt = h.run_through_codegen_ad(name, src, WD, opt=True)
    # codegen.ad with --opt OFF (baseline behavior; objdiff-proven == seed).
    r_off = h.run_through_codegen_ad(name, src, WD, opt=False)

    ok_kind = (r_opt.kind == "ok") and (r_off.kind == "ok")
    same_exit = (r_opt.exit == expected) and (r_off.exit == expected)
    # The opt and off runs must agree (opt changed nothing observable).
    agree = (r_opt.exit == r_off.exit) and (r_opt.stdout == r_off.stdout)

    dce = getattr(r_opt, "dce", 0) if r_opt.kind == "ok" else -1

    if dce > 0:
        fired_units += 1
        total_dce += dce

    status = "OK"
    if not (ok_kind and same_exit and agree):
        status = "FAIL"
        fails += 1
    if expect_fire and dce < exp_dce:
        status = "FAIL(under-fire)"
        fails += 1
    # MUST-KEEP cases (expect_fire False with exp_dce 0): DCE must remove NOTHING.
    if (not expect_fire) and exp_dce == 0 and dce != 0:
        status = "FAIL(keep-leaked)"
        fails += 1

    print(f"[{name}] {status}  opt_exit={r_opt.exit} off_exit={r_off.exit} "
          f"expected={expected} DCE={dce} exp_dce>={exp_dce}")

print("=" * 50)
print(f"[opt_dce] units that fired DCE: {fired_units}   total DCE removals: {total_dce}")
if fails == 0:
    print("[opt_dce] PASS — DCE fires and is behavior-preserving")
    sys.exit(0)
else:
    print(f"[opt_dce] FAIL — {fails} problem(s)")
    sys.exit(1)
PY
