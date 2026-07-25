#!/usr/bin/env bash
# scripts/test_opt_aluload.sh — focused, host-only correctness + firing test for
# the native backend's ALU-LOAD memory-source operand fold (codegen.ad: an 8-byte
# integer array element fed as the RIGHT operand of an integer combine op is
# sourced in-place via `op (%rcx),%rax` instead of load-to-temp + reg-reg combine).
# Armed only under --opt (the Phase-3 isel arm); OFF by default -> byte-identical.
#
# WHAT IT PROVES (no QEMU):
#   1. The fold FIRES: with --opt ON the dump driver's ALULOAD counter is > 0
#      across a corpus of `local OP arr[i]` / `arr[i] OP arr[j]` / element-compare
#      programs over int64/uint64 (the foldable 8-byte width).
#   2. The fold is CORRECT and BIT-EXACT: each program compiled through codegen.ad
#      WITH --opt (fold active) produces EXACTLY the reference value AND the SAME
#      result as the same program WITH --opt OFF (the load-to-temp path). A wrong
#      addressing mode (bad ModRM/SIB), a clobbered live operand, or a wrong
#      sub-8-byte fetch would silently corrupt the value — this is the primary
#      correctness gate for the transform. Covers ADD/SUB/MUL/AND/OR/XOR and the
#      directional/equality compares, two-memory-operand ops, and signed-vs-
#      unsigned element semantics.
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
opt1_require_lane "test_opt_aluload"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_aluload"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE

U64MASK = (1 << 64) - 1
def u64(x): return x & U64MASK
def s64(x):
    x &= U64MASK
    return x - (1 << 64) if x >> 63 else x

fails = 0
fired = 0
checked = 0

def run_case(name, src, ref, expect_fire=True):
    global fails, fired, checked
    checked += 1
    r_opt = h.run_through_codegen_ad(f"alu_{name}", src, WD, opt=True)
    r_off = h.run_through_codegen_ad(f"alu_{name}o", src, WD, opt=False)
    if r_opt.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) {name} opt={r_opt.kind}/{r_off.kind} "
              f"detail={r_opt.detail or r_off.detail}")
        fails += 1
        return
    got_opt = u64(int(r_opt.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    alu = getattr(r_opt, "aluload", 0)
    if alu > 0:
        fired += 1
    if got_opt != ref or got_off != ref:
        print(f"FAIL {name} ref={ref} opt={got_opt} off={got_off} ALULOAD={alu}")
        fails += 1
    elif expect_fire and alu == 0:
        print(f"FAIL(no-fire) {name} ALULOAD=0 (expected the mem-source fold)")
        fails += 1

# ---- local OP arr[i] : every combine op, int64 (signed) -------------------
for opn, pyf in [("+", lambda a, b: a + b), ("-", lambda a, b: a - b),
                 ("*", lambda a, b: a * b), ("&", lambda a, b: a & b),
                 ("|", lambda a, b: a | b), ("^", lambda a, b: a ^ b)]:
    src = PRELUDE + f"""
arr: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 64:
        arr[cast[int64](i)] = i * 7 - 100
        i = i + 1
    s: int64 = 0
    lhs: int64 = 0
    k: int64 = 0
    while k < 64:
        lhs = k * 3 - 50
        s = s + (lhs {opn} arr[cast[int64](k)])
        k = k + 1
    print_u64(cast[uint64](s))
    return cast[int32](0)
"""
    acc = 0
    for k in range(64):
        left = s64(k * 3 - 50)
        elem = s64(k * 7 - 100)
        acc = s64(acc + s64(pyf(left, elem)))
    run_case(f"local_op_i64_{opn}", src, u64(acc))

# ---- local OP arr[i] : uint64 (unsigned), MUL/AND/OR/XOR ------------------
for opn, pyf in [("*", lambda a, b: a * b), ("&", lambda a, b: a & b),
                 ("|", lambda a, b: a | b), ("^", lambda a, b: a ^ b)]:
    src = PRELUDE + f"""
uarr: Array[64, uint64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 64:
        uarr[cast[int64](i)] = cast[uint64](i * 2654435761 + 12345)
        i = i + 1
    s: uint64 = cast[uint64](0)
    k: int64 = 0
    while k < 64:
        s = s + (cast[uint64](k * 40503 + 7) {opn} uarr[cast[int64](k)])
        k = k + 1
    print_u64(s)
    return cast[int32](0)
"""
    acc = 0
    for k in range(64):
        left = u64(k * 40503 + 7)
        elem = u64(k * 2654435761 + 12345)
        acc = u64(acc + u64(pyf(left, elem)))
    run_case(f"local_op_u64_{opn}", src, acc)

# ---- arr[i] OP arr[j] : TWO memory operands (matmul inner-product shape) ---
src = PRELUDE + """
A: Array[64, int64]
B: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 64:
        A[cast[int64](i)] = i + 1
        B[cast[int64](i)] = i * 2 - 5
        i = i + 1
    s: int64 = 0
    k: int64 = 0
    while k < 64:
        s = s + A[cast[int64](k)] * B[cast[int64](k)]
        k = k + 1
    print_u64(cast[uint64](s))
    return cast[int32](0)
"""
ref = u64(sum((i + 1) * (i * 2 - 5) for i in range(64)))
run_case("two_mem_mul_i64", src, ref)

# ---- element compares (directional + equality), signedness from element ---
src = PRELUDE + """
sg: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 64:
        sg[cast[int64](i)] = i * 13 - 400
        i = i + 1
    cnt: int64 = 0
    k: int64 = 0
    while k < 64:
        if cast[int64](k - 20) < sg[cast[int64](k)]:
            cnt = cnt + 1
        if cast[int64](k * 13 - 400) == sg[cast[int64](k)]:
            cnt = cnt + 1000
        k = k + 1
    print_u64(cast[uint64](cnt))
    return cast[int32](0)
"""
cnt = 0
for k in range(64):
    if (k - 20) < (k * 13 - 400):
        cnt += 1
    if (k * 13 - 400) == (k * 13 - 400):
        cnt += 1000
run_case("elem_cmp_i64", src, u64(cnt))

# ---- unsigned element compare (high-bit-set elements; shr vs sar irrelevant
#      but unsigned-vs-signed setcc must match) ------------------------------
src = PRELUDE + """
ug: Array[64, uint64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 64:
        ug[cast[int64](i)] = cast[uint64](i * 1000000000000000000 + 9)
        i = i + 1
    cnt: int64 = 0
    k: int64 = 0
    while k < 64:
        if cast[uint64](k) < ug[cast[int64](k)]:
            cnt = cnt + 1
        k = k + 1
    print_u64(cast[uint64](cnt))
    return cast[int32](0)
"""
cnt = 0
for k in range(64):
    if u64(k) < u64(k * 1000000000000000000 + 9):
        cnt += 1
run_case("elem_cmp_u64", src, u64(cnt))

# ---- NEGATIVE: a sub-8-byte element must NOT be folded (extension hazard).
#      A uint8 / int32 array element feeding ADD goes through the sized
#      (extending) load, NOT `op (%rcx),%rax`. We only assert correctness here
#      (the fold is correctly DECLINED — expect_fire=False so a 0 count is OK;
#      a wrong result would still FAIL). Confirms the width guard holds.
src = PRELUDE + """
b8: Array[64, uint8]
i32: Array[64, int32]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 64:
        b8[cast[int64](i)] = cast[uint8](i * 5 + 3)
        i32[cast[int64](i)] = cast[int32](i * 100 - 2000)
        i = i + 1
    s: int64 = 0
    k: int64 = 0
    while k < 64:
        s = s + cast[int64](cast[uint64](k) + cast[uint64](b8[cast[int64](k)]))
        s = s + cast[int64](k * 2) + cast[int64](i32[cast[int64](k)])
        k = k + 1
    print_u64(cast[uint64](s))
    return cast[int32](0)
"""
acc = 0
for k in range(64):
    acc = s64(acc + s64(u64(k) + ((k * 5 + 3) & 0xFF)))
    acc = s64(acc + s64(k * 2) + s64(F.I32.wrap(k * 100 - 2000)))
run_case("subword_no_fold", src, u64(acc), expect_fire=False)

print(f"\n[test_opt_aluload] checked={checked} fired={fired} fails={fails}")
if fails:
    print("[test_opt_aluload] FAIL")
    sys.exit(1)
if fired == 0:
    print("[test_opt_aluload] FAIL: the alu-load fold never fired on any case")
    sys.exit(1)
print("[test_opt_aluload] PASS")
PY
rc=$?
exit "$rc"
