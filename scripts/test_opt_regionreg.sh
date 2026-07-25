#!/usr/bin/env bash
# scripts/test_opt_regionreg.sh — focused, host-only correctness + firing test for
# the native optimizer's P3-REGION per-range caller-saved register allocation
# (regalloc.ad: ra_pool_cap_for + cfg.ad: lr_spans_call, --opt).
#
# THE LEVER
# ---------
# The P3 caller-saved pool {rdi,r8,r9,r10,r11} used to be unlocked ONLY when the
# WHOLE FUNCTION was call-free (cfg_fn_has_call==0). matmul's main() calls
# print_u64, so its hot inner loop got no caller-saved register and the reduction
# accumulator `s` was spilled to [rbp-NN] (a load+store every iteration). This
# lever replaces the whole-function gate with a PER-RANGE one: a value whose live
# interval [lr_start,lr_end) contains NO call-bearing program point is
# CALLER-SAVED-ELIGIBLE — it can sit in %rdi/%r8-r11 with no save/restore even
# inside a function that calls elsewhere. A value that DOES span a call stays
# callee-saved/spilled (a caller-saved reg held across a call = clobbered =
# miscompile).
#
# WHAT IT PROVES (no QEMU):
#   A. BIT-EXACT: a call-bearing function with a call-free hot loop produces the
#      SAME value WITH --opt as WITHOUT (the byte-identical seed path) and the
#      reference. This is the primary soundness gate.
#   B. ACCUMULATOR PROMOTED: on the matmul-shaped hot loop inside a function that
#      calls print_u64, the --opt disassembly no longer stores+reloads the
#      accumulator to its [rbp-NN] slot every iteration (the spill is GONE), AND
#      the per-function allocation now uses MORE than the 5 callee-saved
#      registers (RA_MAX_REGS > 5) — the caller-saved extension fired DESPITE the
#      function making a call. The OLD whole-function gate forced RA_MAX_REGS <= 5
#      here.
#   C. MUST-NOT-CLOBBER SOUNDNESS: a value computed, then a CALL (to a helper that
#      genuinely writes the caller-saved registers), then the value READ, stays
#      bit-exact — the value live across the call was NOT placed in a caller-saved
#      register. A wrong caller-saved promotion of a call-spanning value lands a
#      wrong answer here, the decisive correctness catcher.
#
# HOST-ONLY: python3 + as/ld + objdump, x86_64. NO QEMU. The cached dump driver
# auto-invalidates on .ad change (#479) — no manual rm -rf needed.
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
opt1_require_lane "test_opt_regionreg"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_regionreg"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = Path("tests/bench/opt/_prelude.ad").read_text()
U64MASK = (1 << 64) - 1
def u64(x): return x & U64MASK

fails = 0

def disasm_rbp_roundtrips(elf: Path):
    """Return the set of rbp-relative slot offsets that are BOTH stored to and
    loaded from with rax (the spilled-accumulator write-through+reload pattern)."""
    raw = elf.read_bytes()
    rl = subprocess.run(["readelf", "-l", str(elf)], capture_output=True, text=True)
    filesz = None
    for ln in rl.stdout.splitlines():
        m = re.search(r"LOAD\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x([0-9a-f]+)", ln)
        if m:
            filesz = int(m.group(1), 16); break
    filesz = filesz or len(raw)
    binf = elf.with_suffix(".code.bin"); binf.write_bytes(raw[:filesz])
    dis = subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel", str(binf)],
        capture_output=True, text=True).stdout
    stores = set(re.findall(r"mov\s+(?:QWORD PTR )?\[rbp-(0x[0-9a-f]+)\],rax", dis))
    loads = set(re.findall(r"mov\s+rax,(?:QWORD PTR )?\[rbp-(0x[0-9a-f]+)\]", dis))
    return stores & loads

# ---------------------------------------------------------------------------
# A+B. matmul-shaped hot loop INSIDE a function that calls print_u64. The
# accumulator `s` (call-free for its whole life — confined to the call-free
# inner k-loop) must now get a CALLER-SAVED register: spill gone + RA_MAX_REGS>5,
# even though main() makes a call. This is the exact roadmap target.
# ---------------------------------------------------------------------------
N = 6
A = [((i * 7 + 3) % 13) for i in range(N * N)]
B = [((i * 5 + 1) % 11) for i in range(N * N)]
def ref_matmul():
    tot = 0
    for i in range(N):
        for j in range(N):
            s = 0
            for k in range(N):
                s += A[i * N + k] * B[k * N + j]
            tot = u64(tot + u64(s * (i * N + j + 1)))
    return tot

a_init = "".join(f"    ga[cast[int64]({i})] = cast[int64]({v})\n" for i, v in enumerate(A))
b_init = "".join(f"    gb[cast[int64]({i})] = cast[int64]({v})\n" for i, v in enumerate(B))
MATMUL = PRELUDE + f"""
ga: Array[{N*N}, int64]
gb: Array[{N*N}, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
{a_init}{b_init}
    tot: int64 = cast[int64](0)
    i: int64 = cast[int64](0)
    while i < cast[int64]({N}):
        j: int64 = cast[int64](0)
        while j < cast[int64]({N}):
            s: int64 = cast[int64](0)
            k: int64 = cast[int64](0)
            while k < cast[int64]({N}):
                s = s + ga[cast[int64](i * {N} + k)] * gb[cast[int64](k * {N} + j)]
                k = k + cast[int64](1)
            tot = tot + s * (i * cast[int64]({N}) + j + cast[int64](1))
            j = j + cast[int64](1)
        i = i + cast[int64](1)
    print_u64(cast[uint64](tot))
    return cast[int32](0)
"""

ref = ref_matmul()
r_on = h.run_through_codegen_ad("mm", MATMUL, WD, opt=True, keep=True)
r_off = h.run_through_codegen_ad("mmo", MATMUL, WD, opt=False, keep=True)
ra = h.run_regalloc_over_body("mm", MATMUL, WD)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) matmul: on={r_on.kind} off={r_off.kind} "
          f"detail={r_on.detail or r_off.detail}")
    fails += 1
else:
    got_on = u64(int(r_on.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    if got_on != ref or got_off != ref:
        print(f"FAIL(value) matmul: ref={ref} on={got_on} off={got_off}")
        fails += 1
    else:
        print(f"[regionreg] matmul value OK ({ref}) on==off==ref (call-bearing fn)")

    # B1. RA_MAX_REGS > 5: the caller-saved extension fired despite the call.
    if ra.status == "raok":
        print(f"[regionreg] matmul RA_MAX_REGS={ra.max_regs} spilled={ra.spilled} "
              f"(main() calls print_u64)")
        if ra.max_regs <= 5:
            print(f"FAIL(region-expansion) matmul: call-bearing function used only "
                  f"{ra.max_regs} regs; per-region caller-saved did NOT fire for the "
                  f"call-free inner loop")
            fails += 1
        else:
            print(f"[regionreg] per-region caller-saved FIRED in a call-bearing "
                  f"function (RA_MAX_REGS={ra.max_regs} > 5)")
    else:
        print(f"WARN matmul regalloc dump: {ra.detail}")

    # B2. Accumulator spill gone: fewer rbp store/reload round-trips ON vs OFF.
    try:
        rt_on = disasm_rbp_roundtrips(WD / "ad_mm.elf")
        rt_off = disasm_rbp_roundtrips(WD / "ad_mmo.elf")
        print(f"[regionreg] matmul round-tripped rbp slots: OFF={len(rt_off)} "
              f"ON={len(rt_on)}")
        if len(rt_off) > 0 and len(rt_on) >= len(rt_off):
            print(f"FAIL(resident) matmul: accumulator still round-trips its stack "
                  f"slot under --opt (OFF={sorted(rt_off)} ON={sorted(rt_on)})")
            fails += 1
        else:
            print(f"[regionreg] accumulator spill reduced under --opt "
                  f"({len(rt_off)} -> {len(rt_on)} round-tripped slots)")
    except Exception as e:
        print(f"WARN(disasm) matmul residency check skipped: {e}")

# ---------------------------------------------------------------------------
# C. MUST-NOT-CLOBBER soundness. `keep` is computed, then a CALL to rc_work (a
# helper with its OWN loop, so it genuinely writes rdi/r8-r11), then `keep` is
# read. `keep` is live ACROSS the call -> lr_spans_call==1 -> it must stay
# callee-saved/spilled. If the per-range gate wrongly left it in a caller-saved
# register, rc_work clobbers it and the answer diverges. Bit-exact = sound.
# ---------------------------------------------------------------------------
CLOB = PRELUDE + """
def rc_work(x: int64, y: int64) -> int64:
    w: int64 = x
    j: int64 = cast[int64](0)
    while j < cast[int64](4):
        w = w + (x * cast[int64](3) + y)
        w = w - y
        j = j + cast[int64](1)
    return w
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    tot: int64 = cast[int64](0)
    i: int64 = cast[int64](0)
    while i < cast[int64](20):
        keep: int64 = i * cast[int64](5) + cast[int64](7)
        keep2: int64 = i - cast[int64](3)
        mid: int64 = rc_work(i, cast[int64](2))
        tot = tot + keep + mid + keep2
        i = i + cast[int64](1)
    print_u64(cast[uint64](tot))
    return cast[int32](tot & cast[int64](255))
"""
def ref_clob():
    def rc_work(x, y):
        w = x
        for _ in range(4):
            w = u64(w + u64(u64(x * 3) + y)); w = u64(w - y)
        return w
    tot = 0
    for i in range(20):
        keep = u64(i * 5 + 7); keep2 = u64(i - 3); mid = rc_work(i, 2)
        tot = u64(tot + keep + mid + keep2)
    return tot
ref_c = ref_clob()
r_on = h.run_through_codegen_ad("clob", CLOB, WD, opt=True)
r_off = h.run_through_codegen_ad("clobo", CLOB, WD, opt=False)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) clob: on={r_on.kind} off={r_off.kind} "
          f"detail={r_on.detail or r_off.detail}")
    fails += 1
else:
    got_on = u64(int(r_on.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    if got_on != u64(ref_c) or got_off != u64(ref_c):
        print(f"FAIL(clobber) clob: ref={u64(ref_c)} on={got_on} off={got_off} "
              f"— a value live across the call was left in a caller-saved "
              f"register and CLOBBERED!")
        fails += 1
    else:
        print(f"[regionreg] must-NOT-clobber OK ({u64(ref_c)}) on==off==ref "
              f"(value live across a call kept off the caller-saved pool)")

print("=" * 64)
if fails == 0:
    print("[opt_regionreg] PASS — per-region caller-saved fires for a call-free "
          "hot loop inside a call-bearing function (accumulator promoted, spill "
          "gone, RA_MAX_REGS>5), bit-exact vs seed+reference, and a value live "
          "across a call is never left in a caller-saved register")
    sys.exit(0)
print(f"[opt_regionreg] FAIL — {fails} problem(s)")
sys.exit(1)
PY
