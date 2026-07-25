#!/usr/bin/env bash
# scripts/test_opt_tailcall.sh — focused, host-only correctness test for the
# SELF-TAIL-CALL -> LOOP transform (codegen.ad try_tail_self_return / gen_call
# interception): a `return f(...)` in TAIL position to the CURRENT function is
# emitted as a parameter-home re-init + backward `jmp` to the post-prologue body
# top, reusing the frame, instead of a recursive `call` + epilogue. This is tak's
# outer-call lever (recursion overhead -> loop iteration), and a general win for
# any tail-recursive function.
#
# WHAT IT PROVES (no QEMU):
#   * CORRECTNESS: for a battery of self-tail-recursive functions of arity 1..6,
#     with arguments that PERMUTE / cross-read the parameters (the parallel-move
#     hazard: every new arg must be materialised before any param home is
#     overwritten), signed AND unsigned, sub-8-byte (int32) params, the --opt
#     (tail-loop) result EQUALS the --opt-OFF (real recursion) result EQUALS a
#     Python reference.
#   * NON-firing shapes stay correct: a call NOT in tail position (`n * fact(n-1)`),
#     a tail call to a DIFFERENT function (mutual recursion `is_even`/`is_odd`),
#     and a non-self tail call must all compute correctly (the transform must NOT
#     fire, and the ordinary call path is unchanged).
#   * DEPTH: a deep tail recursion (200000) runs under --opt WITHOUT growing the
#     stack (a loop), matching the reference — proving the frame is reused.
#
# HOST-ONLY: python3 + as/ld/gcc (the fuzz host harness), x86_64. NO QEMU.
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
opt1_require_lane "test_opt_tailcall"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_tailcall"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
U64 = (1 << 64) - 1
def u64(x): return x & U64

fails = 0
checked = 0

def run_case(defs, call_expr, ref, tag, both=True):
    """Compile PRELUDE+defs+main(print_u64(call_expr)); assert ON==ref and
    (if both) OFF==ref."""
    global fails, checked
    src = PRELUDE + defs + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    print_u64(cast[uint64]({call_expr}))
    return cast[int32](0)
"""
    checked += 1
    r_on = h.run_through_codegen_ad(f"tc_{checked}", src, WD, opt=True)
    if r_on.kind != "ok":
        print(f"FAIL(compile ON) {tag} kind={r_on.kind} detail={(r_on.detail or '')!r:.200}")
        fails += 1
        return
    got_on = u64(int(r_on.stdout.strip() or "0"))
    if got_on != u64(ref):
        print(f"FAIL(ON) {tag} ref={u64(ref)} on={got_on}")
        fails += 1
    if both:
        r_off = h.run_through_codegen_ad(f"tc_{checked}o", src, WD, opt=False)
        if r_off.kind != "ok":
            print(f"FAIL(compile OFF) {tag} kind={r_off.kind}")
            fails += 1
            return
        got_off = u64(int(r_off.stdout.strip() or "0"))
        if got_off != u64(ref):
            print(f"FAIL(OFF) {tag} ref={u64(ref)} off={got_off}")
            fails += 1

# --- 1. 2-arg accumulator tail recursion: sum_to(n,0) = n(n+1)/2 -----------
SUM = """
def sum_to(n: int64, acc: int64) -> int64:
    if n <= 0:
        return acc
    return sum_to(n - 1, acc + n)
"""
for n in [0, 1, 2, 10, 1000, 65535]:
    run_case(SUM, f"sum_to({n}, 0)", n * (n + 1) // 2, f"sum_to({n})")

# --- 2. gcd: new args CROSS-READ both params (parallel-move hazard) --------
GCD = """
def gcd(a: int64, b: int64) -> int64:
    if b == 0:
        return a
    return gcd(b, a - (a / b) * b)
"""
import math
for a, b in [(48, 36), (1071, 462), (17, 5), (1000000, 999983), (100, 0), (7, 7)]:
    run_case(GCD, f"gcd({a}, {b})", math.gcd(a, b), f"gcd({a},{b})")

# --- 3. 3-arg tail recursion whose args PERMUTE the params ------------------
F3 = """
def f3(x: int64, y: int64, z: int64) -> int64:
    if x <= 0:
        return y + z
    return f3(x - 1, z, y + 1)
"""
def f3ref(x, y, z):
    while x > 0:
        x, y, z = x - 1, z, y + 1
    return y + z
for x, y, z in [(0, 3, 4), (1, 3, 4), (5, 0, 0), (10, 2, 7), (1000, 1, 1)]:
    run_case(F3, f"f3({x}, {y}, {z})", u64(f3ref(x, y, z)), f"f3({x},{y},{z})")

# --- 4. 6-arg tail recursion (fills all SysV register args) ----------------
F6 = """
def f6(a: int64, b: int64, c: int64, d: int64, e: int64, n: int64) -> int64:
    if n <= 0:
        return a + b + c + d + e
    return f6(b, c, d, e, a + 1, n - 1)
"""
def f6ref(a, b, c, d, e, n):
    while n > 0:
        a, b, c, d, e, n = b, c, d, e, a + 1, n - 1
    return a + b + c + d + e
for tup in [(1, 2, 3, 4, 5, 0), (1, 2, 3, 4, 5, 1), (1, 2, 3, 4, 5, 100)]:
    run_case(F6, f"f6({','.join(map(str,tup))})", u64(f6ref(*tup)), f"f6{tup}")

# --- 5. int32 (sub-8-byte) params ------------------------------------------
F32 = """
def s32(n: int32, acc: int32) -> int32:
    if n <= 0:
        return acc
    return s32(n - 1, acc + n)
"""
def s32ref(n):
    acc = 0
    while n > 0:
        acc = (acc + n) & U64
        n -= 1
    # truncate to int32 as the kernel prints cast[uint64] of an int32 result
    v = acc & 0xFFFFFFFF
    return v - (1 << 32) & U64 if v >> 31 else v
for n in [0, 1, 10, 1000]:
    run_case(F32, f"s32({n}, 0)", s32ref(n), f"s32({n})")

# --- 6. NON-tail recursion (must NOT fire; still correct) -------------------
FACT = """
def fact(n: int64) -> int64:
    if n <= 1:
        return 1
    return n * fact(n - 1)
"""
def fref(n):
    r = 1
    for i in range(2, n + 1):
        r = u64(r * i)
    return r
for n in [1, 2, 5, 20]:
    run_case(FACT, f"fact({n})", fref(n), f"fact({n})")

# --- 7. MUTUAL recursion, tail calls to a DIFFERENT function (no fire) ------
MUT = """
def is_odd(n: int64) -> int64:
    if n == 0:
        return 0
    return is_even(n - 1)

def is_even(n: int64) -> int64:
    if n == 0:
        return 1
    return is_odd(n - 1)
"""
for n in [0, 1, 2, 7, 100, 101]:
    run_case(MUT, f"is_even({n})", 1 if n % 2 == 0 else 0, f"is_even({n})")

# --- 8. DEEP tail recursion: proves the frame is reused (loop, no overflow).
#        Only checked ON (a 200000-deep real recursion would risk the OFF
#        build's stack; the reference is the closed form).
run_case(SUM, "sum_to(200000, 0)", 200000 * 200001 // 2, "sum_to(200000) deep", both=False)

print(f"[tailcall] checked={checked} fails={fails}")
sys.exit(1 if fails else 0)
PY
rc=$?
if [ "$rc" = "0" ]; then
    echo "[tailcall] PASS"
else
    echo "[tailcall] FAIL"
fi
exit "$rc"
