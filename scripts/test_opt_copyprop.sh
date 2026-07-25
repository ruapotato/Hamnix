#!/usr/bin/env bash
# scripts/test_opt_copyprop.sh — focused, host-only correctness + firing test for
# the native optimizer's Phase-9 Copy Propagation pass (opt.ad opt_copyprop_function).
#
# WHAT IT PROVES (no QEMU):
#   1. The pass FIRES: with --opt ON, the dump driver's COPYPROP counter is > 0
#      over a corpus of programs that each contain a pure copy `x = y` whose dest
#      is later read (so a read gets forwarded to the source).
#   2. The pass is CORRECT: each program, run through codegen.ad with --opt ON,
#      produces the SAME observable result (exit status / stdout) as the same
#      program with --opt OFF (the objdiff-proven == seed baseline) AND the known
#      expected answer — i.e. forwarding the copy changed nothing observable.
#   3. The SAFETY BARRIERS hold: a program where the COPY SOURCE is reassigned
#      between the copy and a later read must NOT forward across the reassignment
#      (an over-eager propagation would compute the wrong answer); and a program
#      whose copy is fed to an address-of / call is a barrier. In every such case
#      the result stays correct, which an unsafe transform would break.
#
# Targeted complement to the broad ADDER_OPT=1 fuzzer lane
# (scripts/fuzz_adder_diff.sh): here the copy shapes are hand-crafted so the
# counter is guaranteed to move and each shape's semantics are pinned.
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
opt1_require_lane "test_opt_copyprop"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_copyprop"); WD.mkdir(parents=True, exist_ok=True)

# Each case: (name, source, expected_exit, expect_copyprop_fires)
CASES = []

# 1. Plain pure copy then a read: `y = x; return y` -> read of y forwarded to x;
#    DCE then removes the dead `y`. Result must equal x's value.
CASES.append(("copy_simple", """
def main() -> int:
    x: int = 7
    y: int = x
    return y + 1
""", 8, True))

# 2. Copy used in an arithmetic r-value: forward the copy into the expression.
CASES.append(("copy_in_expr", """
def main() -> int:
    a: int = 10
    b: int = a
    c: int = 3
    return b * c + 1
""", 31, True))

# 3. Transitive chain `b = a; c = b; return c`: reads of c root to a.
CASES.append(("copy_chain", """
def main() -> int:
    a: int = 5
    b: int = a
    c: int = b
    return c * 2
""", 10, True))

# 4. SAFETY — source reassigned mid-range. `y = x; x = 100; return y`. y must
#    still read the OLD x (7), NOT the new x (100). An over-eager copy-prop that
#    forwarded `return y` to `return x` AFTER the reassignment would yield 100 —
#    a miscompile. The kill-on-source-write barrier must prevent that.
CASES.append(("unsafe_src_reassigned", """
def main() -> int:
    x: int = 7
    y: int = x
    x = 100
    return y
""", 7, False))

# 5. SAFETY — dest reassigned before read. `y = x; y = 42; return y`. The read
#    of y must see 42, not x. The kill-on-dest-write barrier handles this.
CASES.append(("unsafe_dest_reassigned", """
def main() -> int:
    x: int = 7
    y: int = x
    y = 42
    return y
""", 42, False))

# 6. SAFETY — address-of the copy source escapes -> whole-function alias barrier
#    in DCE keeps the local, and copy-prop's addr-of barrier flushes; result
#    correct regardless.
CASES.append(("barrier_addr", """
def main() -> int:
    x: int = 9
    y: int = x
    p: Ptr[int] = &x
    return y
""", 9, False))

total_cp = 0
fired_units = 0
fails = 0
for name, src, expected, expect_fire in CASES:
    r_opt = h.run_through_codegen_ad(name, src, WD, opt=True)
    r_off = h.run_through_codegen_ad(name, src, WD, opt=False)

    ok_kind = (r_opt.kind == "ok") and (r_off.kind == "ok")
    same_exit = (r_opt.exit == expected) and (r_off.exit == expected)
    agree = (r_opt.exit == r_off.exit) and (r_opt.stdout == r_off.stdout)

    cp = getattr(r_opt, "copyprop", 0) if r_opt.kind == "ok" else -1

    if cp > 0:
        fired_units += 1
        total_cp += cp

    status = "OK"
    if not (ok_kind and same_exit and agree):
        status = "FAIL"
        fails += 1
    if expect_fire and cp <= 0:
        status = "FAIL(no-fire)"
        fails += 1

    print(f"[{name}] {status}  opt_exit={r_opt.exit} off_exit={r_off.exit} "
          f"expected={expected} COPYPROP={cp}")

print("=" * 50)
print(f"[opt_copyprop] units that fired COPYPROP: {fired_units}   total forwards: {total_cp}")
if fails == 0 and fired_units > 0:
    print("[opt_copyprop] PASS — copy-prop fires and is behavior-preserving")
    sys.exit(0)
else:
    print(f"[opt_copyprop] FAIL — {fails} problem(s), fired_units={fired_units}")
    sys.exit(1)
PY
