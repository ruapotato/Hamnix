#!/usr/bin/env bash
# scripts/test_opt_isel.sh — focused, host-only correctness + firing test for the
# native backend's INSTRUCTION SELECTION (codegen.ad gen_index_addr: scaled-index
# `lea` for array/pointer element-address arithmetic). Armed only under --opt.
#
# WHAT IT PROVES (no QEMU):
#   1. The pass FIRES: with --opt ON the dump driver's ISEL counter is > 0 across
#      a corpus of array-index / pointer-arithmetic / memory-operand-ALU programs.
#   2. The pass is CORRECT: each program, compiled through codegen.ad WITH --opt
#      (isel active), produces EXACTLY the reference value AND the same result as
#      the same program WITH --opt OFF (the scale-shift + base-lea + add path).
#      Exercised across element strides 1/2/4/8 (uint8/uint16/uint32/uint64/int64),
#      local arrays, global arrays, pointer locals (cast[Ptr[T]]), index by
#      constant / ident / computed expression, read AND write element addresses,
#      and memory operands feeding ALU ops.
#   3. A wrong addressing mode (bad SIB scale / base / disp) silently corrupts the
#      memory access, so this is the primary correctness gate for the transform
#      (complements the broad ADDER_OPT=1 fuzzer lane scripts/fuzz_adder_diff.sh,
#      which also exercises generated array/pointer programs).
#
# HOST-ONLY: python3 + as/ld/gcc (the fuzz host harness), x86_64. NO QEMU.
#
# BUILD HYGIENE: the cached dump driver under build/fuzz_ad_codegen now
# AUTO-INVALIDATES via ad_codegen_host.build_driver()'s inputs-hash stamp, so it
# rebuilds automatically when codegen.ad / any compiler source changes. No
# manual `rm -rf build/fuzz_ad_codegen` is needed for correctness.
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
opt1_require_lane "test_opt_isel"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_isel"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE

U64MASK = (1 << 64) - 1
def u64(x): return x & U64MASK

fails = 0
fired = 0
checked = 0

def run_case(name, src, ref):
    global fails, fired, checked
    checked += 1
    r_opt = h.run_through_codegen_ad(f"isel_{name}", src, WD, opt=True)
    r_off = h.run_through_codegen_ad(f"isel_{name}o", src, WD, opt=False)
    if r_opt.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) {name} opt={r_opt.kind}/{r_off.kind} "
              f"detail={r_opt.detail or r_off.detail}")
        fails += 1
        return
    got_opt = u64(int(r_opt.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    isel = getattr(r_opt, "isel", 0)
    if isel > 0:
        fired += 1
    if got_opt != ref or got_off != ref:
        print(f"FAIL {name} ref={ref} opt={got_opt} off={got_off} ISEL={isel}")
        fails += 1
    elif isel == 0:
        print(f"FAIL(no-fire) {name} ISEL=0 (expected the lea-fold to fire)")
        fails += 1

# ---- Local array, every stride (1/2/4/8), index by ident + constant -------
for tname, width in [("uint8", 1), ("uint16", 2), ("uint32", 4),
                     ("uint64", 8), ("int64", 8)]:
    # a[i] write then a[k] read, with a computed index, summed.
    src = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: Array[64, {tname}]
    i: int64 = 0
    while i < 64:
        a[cast[int64](i)] = cast[{tname}](i * 3 + 1)
        i = i + 1
    s: uint64 = cast[uint64](0)
    k: int64 = 0
    while k < 64:
        s = s + cast[uint64](a[cast[int64](k)])
        k = k + 1
    print_u64(s)
    return cast[int32](0)
"""
    mask = (1 << (width * 8)) - 1
    ref = u64(sum((i * 3 + 1) & mask for i in range(64)))
    run_case(f"local_{tname}", src, ref)

# ---- Global array (rip base + scaled index) -------------------------------
src = PRELUDE + """
g: Array[128, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 128:
        g[cast[int64](i)] = i * i - 7
        i = i + 1
    s: int64 = 0
    j: int64 = 0
    while j < 128:
        s = s + g[cast[int64](j)]
        j = j + 1
    print_u64(cast[uint64](s))
    return cast[int32](0)
"""
ref = u64(sum(i * i - 7 for i in range(128)))
run_case("global_i64", src, ref)

# ---- Global byte array (stride 1) -----------------------------------------
src = PRELUDE + """
gb: Array[256, uint8]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 256:
        gb[cast[int64](i)] = cast[uint8](i * 5 + 2)
        i = i + 1
    s: uint64 = cast[uint64](0)
    j: int64 = 0
    while j < 256:
        s = s + cast[uint64](gb[cast[int64](j)])
        j = j + 1
    print_u64(s)
    return cast[int32](0)
"""
ref = u64(sum((i * 5 + 2) & 0xFF for i in range(256)))
run_case("global_u8", src, ref)

# ---- Pointer local: cast[Ptr[T]] base + scaled index ----------------------
src = PRELUDE + """
buf: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    p: Ptr[int64] = cast[Ptr[int64]](&buf[0])
    i: int64 = 0
    while i < 64:
        p[cast[int64](i)] = i * 11 + 3
        i = i + 1
    s: int64 = 0
    j: int64 = 0
    while j < 64:
        s = s + p[cast[int64](j)]
        j = j + 1
    print_u64(cast[uint64](s))
    return cast[int32](0)
"""
ref = u64(sum(i * 11 + 3 for i in range(64)))
run_case("ptr_local_i64", src, ref)

# ---- Pointer local stride 4 (cast[Ptr[uint32]]) ---------------------------
src = PRELUDE + """
buf32: Array[64, uint32]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    p: Ptr[uint32] = cast[Ptr[uint32]](&buf32[0])
    i: int64 = 0
    while i < 64:
        p[cast[int64](i)] = cast[uint32](i * 7)
        i = i + 1
    s: uint64 = cast[uint64](0)
    j: int64 = 0
    while j < 64:
        s = s + cast[uint64](p[cast[int64](j)])
        j = j + 1
    print_u64(s)
    return cast[int32](0)
"""
ref = u64(sum((i * 7) & 0xFFFFFFFF for i in range(64)))
run_case("ptr_local_u32", src, ref)

# ---- Memory operand feeding ALU: a[i] * b[i] accumulate (matmul-shape) -----
src = PRELUDE + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: Array[32, int64]
    b: Array[32, int64]
    i: int64 = 0
    while i < 32:
        a[cast[int64](i)] = i + 1
        b[cast[int64](i)] = i * 2 + 1
        i = i + 1
    s: int64 = 0
    k: int64 = 0
    while k < 32:
        s = s + a[cast[int64](k)] * b[cast[int64](k)]
        k = k + 1
    print_u64(cast[uint64](s))
    return cast[int32](0)
"""
ref = u64(sum((i + 1) * (i * 2 + 1) for i in range(32)))
run_case("mem_alu_mul", src, ref)

# ---- 2-D flattened global (i*N+j index, stride 8) -------------------------
src = PRELUDE + """
M: Array[256, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    N: int64 = 16
    i: int64 = 0
    while i < N:
        j: int64 = 0
        while j < N:
            M[cast[int64](i * N + j)] = i * 100 + j
            j = j + 1
        i = i + 1
    s: int64 = 0
    p: int64 = 0
    while p < N * N:
        s = s + M[cast[int64](p)]
        p = p + 1
    print_u64(cast[uint64](s))
    return cast[int32](0)
"""
N = 16
ref = u64(sum(i * 100 + j for i in range(N) for j in range(N)))
run_case("flat2d_i64", src, ref)

print(f"\n[test_opt_isel] checked={checked} fired={fired} fails={fails}")
if fails:
    print("[test_opt_isel] FAIL")
    sys.exit(1)
if fired == 0:
    print("[test_opt_isel] FAIL: isel never fired")
    sys.exit(1)
print("[test_opt_isel] PASS")
PY
rc=$?
exit $rc
