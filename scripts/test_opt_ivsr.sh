#!/usr/bin/env bash
# scripts/test_opt_ivsr.sh — focused, host-only correctness + firing test for the
# native optimizer's INDUCTION-VARIABLE STRENGTH REDUCTION (opt.ad Phase 3.6,
# --opt). The pass rewrites an array index that is an AFFINE function of a
# counted loop's induction variable — `arr[i*C + R]`, `arr[i*N + j]` — into a
# pre-header-seeded RUNNING variable advanced by a constant `C*step` each
# iteration, eliminating the per-iteration index multiply.
#
# WHAT IT PROVES (no QEMU):
#   1. The pass FIRES: with --opt ON the dump driver's IVSR counter is > 0 on a
#      corpus of affine-index counted-loop programs.
#   2. The pass is CORRECT: each program compiled WITH --opt (IVSR active)
#      produces EXACTLY the reference value AND the same value as WITH --opt OFF
#      (the byte-identical seed path). A wrong running-variable seed/step lands
#      stores at the wrong address and the position-weighted checksum diverges,
#      so this is the primary focused correctness gate (complements the broad
#      ADDER_OPT=1 fuzzer lane scripts/fuzz_adder_diff.sh, which stresses affine
#      loop+index shapes differentially).
#
# Shapes: 1-D constant coefficient, 1-D with invariant remainder, 2-D row-major
# a[i*N+j] (variable invariant coefficient — the matmul win), decreasing loops,
# step != 1, multiple distinct affine indices over one IV, and a runtime-
# invariant coefficient held in a local.
#
# HOST-ONLY: python3 + as/ld (the fuzz host harness), x86_64. NO QEMU.
#
# BUILD HYGIENE: the cached dump driver under build/fuzz_ad_codegen now
# AUTO-INVALIDATES via ad_codegen_host.build_driver()'s inputs-hash stamp, so it
# is rebuilt automatically when opt.ad / codegen.ad / any compiler source
# changes. No manual `rm -rf build/fuzz_ad_codegen` is needed for correctness.
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
opt1_require_lane "test_opt_ivsr"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_ivsr"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
U64MASK = (1 << 64) - 1
def u64(x): return x & U64MASK
def s64(x):
    x &= U64MASK
    return x - (1 << 64) if x >> 63 else x

DIM = 16
NCELL = DIM * DIM

# Each case is (name, body_lines, shadow_fill) where shadow_fill(sh) populates
# the Python reference array exactly as the loop should. The program writes the
# array then folds a POSITION-WEIGHTED checksum sum(a[k]*(k+1)) so a mislanded
# store (wrong running-var address) diverges.
def make_program(body_lines):
    body = "\n".join("    " + ln for ln in body_lines)
    src = PRELUDE + f"""
g_ivsr: Array[{NCELL}, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
{body}
    ivsum: int64 = cast[int64](0)
    ivk: int64 = cast[int64](0)
    while ivk < cast[int64]({NCELL}):
        ivsum = ivsum + g_ivsr[cast[int64](ivk)] * (ivk + cast[int64](1))
        ivk = ivk + cast[int64](1)
    print_u64(cast[uint64](ivsum))
    return cast[int32](0)
"""
    return src

def checksum(sh):
    tot = 0
    for k in range(NCELL):
        tot = u64(tot + u64(sh[k] * (k + 1)))
    return tot

cases = []

# 1-D constant coefficient: a[i*C] = i*7+1
for C in (2, 3, 4, 5):
    n = min(8, (NCELL - 1) // C + 1)
    body = [
        "i: int64 = cast[int64](0)",
        f"while i < cast[int64]({n}):",
        f"    g_ivsr[cast[int64](i * {C})] = i * cast[int64](7) + cast[int64](1)",
        "    i = i + cast[int64](1)",
    ]
    sh = [0] * NCELL
    for i in range(n):
        sh[(i * C) % NCELL] = u64(i * 7 + 1)
    cases.append((f"lin1d_C{C}", body, checksum(sh)))

# 1-D with invariant remainder: a[i*C + R] = i - R
for C, R in ((2, 1), (3, 2), (4, 0), (2, 5)):
    n = min(7, (NCELL - 1 - R) // C + 1)
    body = [
        f"R: int64 = cast[int64]({R})",
        "i: int64 = cast[int64](0)",
        f"while i < cast[int64]({n}):",
        f"    g_ivsr[cast[int64](i * {C} + R)] = i - R",
        "    i = i + cast[int64](1)",
    ]
    sh = [0] * NCELL
    for i in range(n):
        sh[(i * C + R) % NCELL] = u64(i - R)
    cases.append((f"lin1d_C{C}_R{R}", body, checksum(sh)))

# 2-D row-major a[i*N + j] with N a runtime-invariant local (the matmul win).
for ni, nj in ((3, 4), (4, 3), (2, 6)):
    N = DIM
    body = [
        f"N: int64 = cast[int64]({N})",
        "i: int64 = cast[int64](0)",
        f"while i < cast[int64]({ni}):",
        "    j: int64 = cast[int64](0)",
        f"    while j < cast[int64]({nj}):",
        "        g_ivsr[cast[int64](j * N + i)] = i * cast[int64](3) + j",
        "        j = j + cast[int64](1)",
        "    i = i + cast[int64](1)",
    ]
    # Inner IV is j with coefficient N (non-unit) -> IVSR target.
    sh = [0] * NCELL
    for i in range(ni):
        for j in range(nj):
            idx = (j * N + i) % NCELL
            sh[idx] = u64(i * 3 + j)
    cases.append((f"twod_{ni}x{nj}", body, checksum(sh)))

# Decreasing loop: i = n-1 .. 0, a[i*C] = i+2
for C in (2, 3):
    n = min(6, (NCELL - 1) // C + 1)
    body = [
        f"i: int64 = cast[int64]({n - 1})",
        "while i >= cast[int64](0):",
        f"    g_ivsr[cast[int64](i * {C})] = i + cast[int64](2)",
        "    i = i - cast[int64](1)",
    ]
    sh = [0] * NCELL
    for i in range(n - 1, -1, -1):
        sh[(i * C) % NCELL] = u64(i + 2)
    cases.append((f"dec_C{C}", body, checksum(sh)))

# Step != 1: iv advances by s, index iv*C; running var advances C*s.
for C, s in ((2, 2), (3, 2), (2, 3)):
    n = min(5, (NCELL - 1) // (C * s) + 1)
    body = [
        "iv: int64 = cast[int64](0)",
        "c: int64 = cast[int64](0)",
        f"while c < cast[int64]({n}):",
        f"    g_ivsr[cast[int64](iv * {C})] = iv + cast[int64](5)",
        f"    iv = iv + cast[int64]({s})",
        "    c = c + cast[int64](1)",
    ]
    sh = [0] * NCELL
    iv = 0
    for _c in range(n):
        sh[(iv * C) % NCELL] = u64(iv + 5)
        iv += s
    cases.append((f"stepk_C{C}_s{s}", body, checksum(sh)))

# Multiple distinct affine indices over the same IV: a[i*2] and a[i*3+1].
n = 5
body = [
    "i: int64 = cast[int64](0)",
    f"while i < cast[int64]({n}):",
    "    g_ivsr[cast[int64](i * 2)] = i + cast[int64](1)",
    "    g_ivsr[cast[int64](i * 3 + 1)] = i * cast[int64](4)",
    "    i = i + cast[int64](1)",
]
sh = [0] * NCELL
for i in range(n):
    sh[(i * 2) % NCELL] = u64(i + 1)
    sh[(i * 3 + 1) % NCELL] = u64(i * 4)
cases.append(("multi_iv", body, checksum(sh)))

fails = 0
fired = 0
for name, body, ref in cases:
    src = make_program(body)
    r_opt = h.run_through_codegen_ad(f"iv_{name}", src, WD, opt=True)
    r_off = h.run_through_codegen_ad(f"iv_{name}o", src, WD, opt=False)
    if r_opt.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) {name}: opt={r_opt.kind}/{r_off.kind} "
              f"detail={r_opt.detail or r_off.detail}")
        fails += 1
        continue
    got_opt = u64(int(r_opt.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    iv = getattr(r_opt, "ivsr", 0)
    if iv > 0:
        fired += 1
    if got_opt != ref or got_off != ref:
        print(f"FAIL {name}: ref={ref} opt={got_opt} off={got_off} IVSR={iv}")
        fails += 1
    elif iv == 0:
        print(f"FAIL(no-fire) {name}: IVSR=0 — the pass did not fire on an "
              f"affine-index counted loop (wiring regression)")
        fails += 1

print("=" * 60)
print(f"[opt_ivsr] programs checked: {len(cases)}  IVSR-fired: {fired}")
if fails == 0:
    print("[opt_ivsr] PASS — affine-index induction-variable strength reduction "
          "fires and is bit-exact vs both the seed path and the reference")
    sys.exit(0)
print(f"[opt_ivsr] FAIL — {fails} problem(s)")
sys.exit(1)
PY
