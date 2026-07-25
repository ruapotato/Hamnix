#!/usr/bin/env bash
# scripts/test_opt_vectorfill.sh — focused, host-only correctness + firing test
# for the native backend's SSE2 AUTO-VECTORIZER (codegen.ad try_vectorize_fill /
# vec_emit_fill_loop). Armed only under --opt (vec_enable()); OFF by default the
# loop is emitted by the byte-identical scalar path.
#
# WHAT IT PROVES (no QEMU):
#   1. The pass FIRES: a counted invariant-32-bit-word unit-stride store loop
#      (the vk_2d opaque rect-fill / clear shape) reports VEC>0 under --opt.
#   2. The pass is CORRECT: the fill compiled WITH the vectorizer (--opt) writes
#      a memory image BYTE-IDENTICAL to the SAME fill WITHOUT the vectorizer
#      (--opt --no-vec) AND to the fully-scalar build (--opt OFF), across every
#      trip-count remainder (n mod 4 == 0,1,2,3), n=0, and both promoted and
#      unpromoted loop locals. A wrong broadcast/stride/epilogue corrupts the
#      buffer, so the differential checksum is the correctness gate.
#   3. It is BYTE-INERT with --opt OFF (VEC==0): the vectorizer never perturbs
#      the default build (the objdiff gate proves the whole-program byte
#      identity; this asserts the counter specifically stays 0).
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
opt1_require_lane "test_opt_vectorfill"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_vectorfill"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE

U32 = (1 << 32) - 1

def prog(n, word, unpromoted):
    # A vk_2d-shaped opaque word fill of `n` uint32 slots, then a checksum over
    # the whole (64-slot) buffer's low bytes. `unpromoted` toggles whether the
    # loop locals are register-PROMOTED (the realistic vk_2d case: o/xx/n land in
    # rbx/r12..r15) or forced STACK-slot-resident by taking their address (which
    # vetoes regalloc promotion) — exercising BOTH the promoted-register and the
    # stack-slot arms of vec_read_to_rax / vec_write_from_rax.
    veto = ""
    guard = ""
    if unpromoted:
        veto = """
    sink: uint64 = cast[uint64](&o)
    sink2: uint64 = cast[uint64](&xx)"""
        guard = """
    if sink == 7 and sink2 == 9:
        print_u64(0)"""
    return PRELUDE + f"""
def fillbuf(base: uint64, n: int64, word: uint32):
    o: uint64 = base
    xx: int64 = 0{veto}
    while xx < n:
        cast[Ptr[uint32]](o)[0] = word
        o = o + 4
        xx = xx + 1{guard}

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    buf: Array[64, uint32]
    i: int64 = 0
    while i < 64:
        buf[i] = cast[uint32](0)
        i = i + 1
    fillbuf(cast[uint64](&buf[0]), {n}, cast[uint32]({word}))
    s: uint64 = 0
    j: int64 = 0
    while j < 64:
        s = s + cast[uint64](buf[j] & 0xFF)
        s = s + cast[uint64]((buf[j] >> 8) & 0xFF) * 7
        j = j + 1
    print_u64(s)
    return cast[int32](0)
"""

def ref(n, word):
    n = min(max(n, 0), 64)
    lo = word & 0xFF
    hi = (word >> 8) & 0xFF
    return n * (lo + hi * 7)

WORDS = [0xAABBCCDD, 0x00000000, 0xFFFFFFFF, 0x11223344, 0x0000FF00]
fails = 0
fired = 0
total = 0
for unpromoted in (False, True):
    for word in WORDS:
        for n in range(0, 49):
            total += 1
            src = prog(n, word, unpromoted)
            r_vec = h.run_through_codegen_ad(f"vv{n}_{word}_{int(unpromoted)}",
                                             src, WD, opt=True)
            r_nov = h.run_through_codegen_ad(f"vn{n}_{word}_{int(unpromoted)}",
                                             src, WD, opt=True, no_vec=True)
            r_off = h.run_through_codegen_ad(f"vo{n}_{word}_{int(unpromoted)}",
                                             src, WD, opt=False)
            if r_vec.kind != "ok" or r_nov.kind != "ok" or r_off.kind != "ok":
                print(f"FAIL(compile) n={n} word={word:#x} up={unpromoted} "
                      f"vec={r_vec.kind} nov={r_nov.kind} off={r_off.kind} "
                      f"detail={r_vec.detail or r_nov.detail or r_off.detail}")
                fails += 1
                continue
            exp = str(ref(n, word))
            gv = r_vec.stdout.strip()
            gn = r_nov.stdout.strip()
            go = r_off.stdout.strip()
            vc = getattr(r_vec, "vec", 0)
            voff = getattr(r_off, "vec", 0)
            if not (gv == gn == go == exp):
                print(f"FAIL n={n} word={word:#x} up={unpromoted} "
                      f"vec={gv} nov={gn} off={go} exp={exp} VEC={vc}")
                fails += 1
                continue
            if voff != 0:
                print(f"FAIL(byte-inert) n={n} word={word:#x} --opt OFF VEC={voff}")
                fails += 1
                continue
            if n >= 4:
                if vc < 1:
                    print(f"FAIL(no-fire) n={n} word={word:#x} up={unpromoted} VEC=0")
                    fails += 1
                    continue
                fired += 1

print("=" * 62)
print(f"[opt_vectorfill] programs checked: {total}  vectorized (VEC>0): {fired}")
if fails == 0:
    print("[opt_vectorfill] PASS — SSE2 word-fill vectorizer fires and is "
          "byte-exact vs --no-vec and scalar (all remainders, promoted + "
          "unpromoted locals), and byte-inert with --opt OFF")
    sys.exit(0)
print(f"[opt_vectorfill] FAIL — {fails} problem(s)")
sys.exit(1)
PY
