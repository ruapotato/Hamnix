#!/usr/bin/env bash
# scripts/test_opt_parity_pow2.sh — focused, host-only correctness + firing test
# for the native optimizer's POW2 PARITY / DIVISIBILITY idiom fold (opt.ad
# opt_paritymod_function): `x - (x/C)*C == 0` and `x % C == 0` (C a power of two)
# are rewritten to `(x & (C-1)) == 0`, a SIGN-INDEPENDENT divisibility test that
# codegen lowers to a single `and`/`test`.
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECTNESS across SIGNEDNESS, ESPECIALLY NEGATIVE DIVIDENDS. The fold is
#      only valid because, for a power-of-two C, `x` is divisible by C iff its
#      low log2(C) bits are zero — TRUE FOR EVERY SIGN. This gate compiles the
#      idiom/mod evenness tests with --opt ON (fold active) and OFF (literal
#      div/mul/sub or idiv path) and asserts BOTH equal a Python reference, over
#      signed int64 (negative + positive) and unsigned uint64 dividends.
#   2. The VALUE-CONTEXT signed `%` is NOT mis-lowered: `x % C` used as a value
#      (not compared to 0) must stay C-truncated (e.g. -7 % 4 == -3), which the
#      pass deliberately leaves to gen_div_const. Checked here too.
#   3. The fold FIRES: the driver's PARITYMOD counter is > 0 on the idiom corpus.
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
opt1_require_lane "test_opt_parity_pow2"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_parity_pow2"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE

U64 = (1 << 64) - 1
def u64(x): return x & U64
def s64(x):
    x &= U64
    return x - (1 << 64) if x >> 63 else x

# Power-of-two divisors only (the pass gates on pow2); include large.
POW2 = [2, 4, 8, 16, 1024, (1 << 20)]
# Dividends span negative/positive/edges. Divisibility by a pow2 is sign-agnostic.
DIVIDENDS = [0, 1, 2, 3, 4, 7, 8, 15, 16, 17, 1023, 1024, 123456,
             -1, -2, -3, -4, -7, -8, -15, -16, -1024, -123456,
             (1 << 40), -(1 << 40), (1 << 62) - 1, -(1 << 62)]
TYPES = [("int64", True), ("uint64", False)]

def litsrc(v):
    # bare literal so it is ND_INT_LIT / UNOP_NEG(ND_INT_LIT)
    return f"(-{-v})" if v < 0 else str(v)

fails = 0
fired = 0
checked = 0

def run_case(src, ref, tag):
    global fails, fired, checked
    r_on = h.run_through_codegen_ad(f"pp_{checked}", src, WD, opt=True)
    r_off = h.run_through_codegen_ad(f"pp_{checked}o", src, WD, opt=False)
    checked += 1
    if r_on.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) {tag} on={r_on.kind} off={r_off.kind} "
              f"detail={(r_on.detail or r_off.detail)!r:.200}")
        fails += 1
        return
    got_on = u64(int(r_on.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    if getattr(r_on, "paritymod", 0) > 0:
        fired += 1
    if not (got_on == u64(ref) and got_off == u64(ref)):
        print(f"FAIL {tag} ref={u64(ref)} on={got_on} off={got_off} "
              f"parity={getattr(r_on,'paritymod',0)}")
        fails += 1

for tname, signed in TYPES:
    for C in POW2:
        for n in DIVIDENDS:
            nlit = s64(n) if signed else u64(n)
            # low log2 bits zero == divisible by C (sign-agnostic for pow2)
            even = 1 if (u64(nlit) & (C - 1)) == 0 else 0
            # (a) sub-idiom in ==0 context: `n - (n/C)*C == 0`
            src = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    n: {tname} = cast[{tname}]({litsrc(nlit)})
    h: {tname} = n / {C}
    r: int64 = 0
    if n - h * {C} == 0:
        r = 1
    print_u64(cast[uint64](r))
    return cast[int32](0)
"""
            run_case(src, even, f"subidiom t={tname} n={nlit} C={C}")
            # (b) direct mod in !=0 context: `n % C != 0`  -> odd/indivisible
            src2 = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    n: {tname} = cast[{tname}]({litsrc(nlit)})
    r: int64 = 0
    if n % {C} != 0:
        r = 1
    print_u64(cast[uint64](r))
    return cast[int32](0)
"""
            run_case(src2, 1 - even, f"modneq t={tname} n={nlit} C={C}")

# VALUE-CONTEXT guard: signed `%` used as a value must stay C-truncated (the pass
# must NOT touch it). Reference is the truncated remainder for both signs.
for n in [-7, -6, -1, 7, 6, 1, -1024 - 3, 1024 + 3]:
    for C in [2, 4, 8, 1024]:
        q = abs(n) // C
        if n < 0:
            q = -q
        rref = n - q * C
        src3 = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    n: int64 = {litsrc(n)}
    print_u64(cast[uint64](n % {C}))
    return cast[int32](0)
"""
        run_case(src3, rref, f"valuemod n={n} C={C}")

print(f"[parity_pow2] checked={checked} idiom-folds-fired={fired} fails={fails}")
if fired == 0:
    print("FAIL: the parity/divisibility fold never fired (expected >0)")
    fails += 1
sys.exit(1 if fails else 0)
PY
rc=$?
if [ "$rc" = "0" ]; then
    echo "[parity_pow2] PASS"
else
    echo "[parity_pow2] FAIL"
fi
exit "$rc"
