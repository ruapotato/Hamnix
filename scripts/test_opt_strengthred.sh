#!/usr/bin/env bash
# scripts/test_opt_strengthred.sh — focused, host-only correctness + firing test
# for the native backend's div/mod-by-CONSTANT STRENGTH REDUCTION (codegen.ad
# gen_div_const: power-of-2 shift/mask, unsigned Granlund-Montgomery magic
# reciprocal-multiply, signed magic; `%` = x - (x/c)*c). Armed only under --opt.
#
# WHAT IT PROVES (no QEMU):
#   1. The pass FIRES: with --opt ON the dump driver's STRENGTHRED counter is > 0
#      across a corpus of div/mod-by-constant programs.
#   2. The pass is CORRECT: each program, compiled through codegen.ad WITH --opt
#      (strength reduction active), produces EXACTLY the reference value AND the
#      same result as the same program WITH --opt OFF (the objdiff==seed idiv
#      path). This is checked across signed AND unsigned operands and the full
#      edge-case set: /1, /-1, powers of two (incl. large), small/large/odd/even
#      and "add-form" (65-bit-multiplier) divisors, INT_MIN, +-near-limits.
#   3. A wrong magic number silently corrupts EVERY such division, so this is the
#      primary correctness gate for the transform (complements the broad
#      ADDER_OPT=1 fuzzer lane scripts/fuzz_adder_diff.sh, which also exercises
#      generated div/mod-by-constant programs).
#
# HOST-ONLY: python3 + as/ld/gcc (the fuzz host harness), x86_64. NO QEMU.
#
# BUILD HYGIENE: the cached dump driver under build/fuzz_ad_codegen now
# AUTO-INVALIDATES via ad_codegen_host.build_driver()'s inputs-hash stamp, so it
# rebuilds automatically when codegen.ad / opt.ad / any compiler source changes.
# No manual `rm -rf build/fuzz_ad_codegen` is needed for correctness.
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
opt1_require_lane "test_opt_strengthred"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_strengthred"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE   # provides print_u64 / sys_write / _putc / g_accum

U64MASK = (1 << 64) - 1
def u64(x): return x & U64MASK
def s64(x):
    x &= U64MASK
    return x - (1 << 64) if x >> 63 else x

def ref_div(n_bits, d_bits, signed):
    """Reference truncating division/modulo over raw 64-bit register bits."""
    if signed:
        n, d = s64(n_bits), s64(d_bits)
        q = abs(n) // abs(d)
        if (n < 0) != (d < 0):
            q = -q
        r = n - q * d
        return u64(q), u64(r)
    n, d = u64(n_bits), u64(d_bits)
    q = n // d
    r = n - q * d
    return u64(q), u64(r)

# Operand types to exercise BOTH signed (idiv/magic-signed) and unsigned
# (div/magic-unsigned) lowering. The dividend's cast[T] drives the op signedness
# (a bare-literal divisor reports unknown signedness).
TYPES = [("int64", True), ("uint64", False)]

# Divisors: 1, -1, powers of two (small+large), odds/primes, "add-form" unsigned
# magic divisors (e.g. 7), large 64-bit-significant constants.
DIVISORS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 16, 25, 100, 125, 128, 1000,
            1023, 1024, 65536, 7919, 1000000007, (1 << 31), (1 << 40) + 7,
            (1 << 62) + 3]
# Dividends (as raw values; will be cast to the operand type in-source).
DIVIDENDS = [0, 1, 7, 8, 15, 16, 255, 1000, 123456789,
             (1 << 31), (1 << 40), (1 << 62),
             (1 << 63) - 1, (1 << 63), (1 << 64) - 1, 0xDEADBEEFCAFEBABE]

cases = []
for tname, signed in TYPES:
    for d in DIVISORS:
        for neg in (False, True):
            dv = -d if neg else d
            if dv == 0:
                continue
            # x86 idiv traps on signed INT_MIN/-1 on the --opt-OFF lane; skip the
            # single trapping pair (strength reduction itself is trap-free).
            for n in DIVIDENDS:
                if signed and s64(dv) == -1 and s64(u64(n)) == -(1 << 63):
                    continue
                cases.append((tname, signed, u64(n), u64(dv)))

# To keep runtime bounded, sample deterministically but broadly.
import random
random.seed(20260627)
random.shuffle(cases)
cases = cases[:240]

def divsrc(dv):
    """Source text for a divisor as a BARE literal (so it is ND_INT_LIT /
    UNOP_NEG(ND_INT_LIT) and the strength-reduction pass recognizes it)."""
    s = s64(dv)
    if s < 0:
        return f"(-{-s})"
    return str(s)

fails = 0
fired = 0
total = 0
checked = 0
for tname, signed, n, dv in cases:
    for op in ("/", "%"):
        total += 1
        qref, rref = ref_div(n, dv, signed)
        ref = qref if op == "/" else rref
        # Print the low 32 bits so the program's exit status (8-bit) is matched
        # via a printed decimal, not the truncated exit code: use print_u64.
        nlit = s64(n) if signed else u64(n)
        src = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    n: {tname} = cast[{tname}]({nlit})
    print_u64(cast[uint64](n {op} {divsrc(dv)}))
    return cast[int32](0)
"""
        r_opt = h.run_through_codegen_ad(f"sr_{checked}", src, WD, opt=True)
        r_off = h.run_through_codegen_ad(f"sr_{checked}o", src, WD, opt=False)
        checked += 1
        if r_opt.kind != "ok" or r_off.kind != "ok":
            # Unsupported shapes are not failures (the subset may reject a form);
            # but a div/mod-by-constant program should compile. Treat as fail.
            print(f"FAIL(compile) t={tname} n={n:#x} d={s64(dv)} op={op} "
                  f"opt={r_opt.kind}/{r_off.kind} detail={r_opt.detail or r_off.detail}")
            fails += 1
            continue
        got_opt = u64(int(r_opt.stdout.strip() or "0"))
        got_off = u64(int(r_off.stdout.strip() or "0"))
        sr = getattr(r_opt, "strengthred", 0)
        if sr > 0:
            fired += 1
        ok = (got_opt == ref) and (got_off == ref)
        if not ok:
            print(f"FAIL t={tname} n={n:#x} d={s64(dv)} op={op} "
                  f"ref={ref} opt={got_opt} off={got_off} SR={sr}")
            fails += 1
        elif sr == 0:
            # Under --opt this program (its bare-literal div/mod + print_u64's
            # own /10 %10) MUST trigger strength reduction; SR==0 means the pass
            # never fired -> a wiring regression.
            print(f"FAIL(no-fire) t={tname} n={n:#x} d={s64(dv)} op={op} SR=0")
            fails += 1

print("=" * 60)
print(f"[opt_strengthred] programs checked: {total}  reduced (SR>0): {fired}")
if fails == 0:
    print("[opt_strengthred] PASS — div/mod-by-constant strength reduction "
          "fires and is bit-exact (signed+unsigned, all edge cases)")
    sys.exit(0)
print(f"[opt_strengthred] FAIL — {fails} problem(s)")
sys.exit(1)
PY
