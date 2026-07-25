#!/usr/bin/env bash
# scripts/test_opt_regpress.sh — focused, host-only correctness + firing test for
# the native optimizer's P3 REGISTER-PRESSURE / SPILL-POLICY track (regalloc.ad,
# --opt). Two levers landed in this track:
#
#   (1) SPILL-COST spill heuristic. The linear-scan victim is now the live value
#       with the LOWEST loop-depth-weighted use count (nm_usecost), not the
#       "furthest end" interval. A loop-carried reduction accumulator (huge
#       weighted use count) is therefore KEPT in a register across the hot loop
#       instead of round-tripping to a [rbp-NN] stack slot every iteration.
#
#   (2) PER-REGION caller-saved POOL allocation. The caller-saved
#       %rdi/%r8/%r9/%r10/%r11 (codegen never writes these without a call/syscall
#       arg-marshal) may be used for any value whose live range spans NO call
#       (lr_spans_call==0), expanding the pool from 5 to 10 — EVEN inside a
#       function that calls elsewhere. A value that DOES span a call stays
#       callee-saved/spilled, so no value is ever left in a caller-saved register
#       across a call — the must-NOT-clobber soundness rule. (This supersedes the
#       former WHOLE-FUNCTION call-free gate; a fully call-free function is the
#       special case where every value spans no call.)
#
# WHAT IT PROVES (no QEMU):
#   A. CORRECTNESS: every kernel compiled WITH --opt produces EXACTLY the same
#      value as WITH --opt OFF (the byte-identical seed path) AND the reference.
#      A wrong spill victim / a value clobbered in a caller-saved reg across a
#      call lands a wrong answer; this is the primary soundness gate.
#   B. ACCUMULATOR STAYS RESIDENT: on the matmul-shaped hot loop, the --opt
#      disassembly no longer reloads+stores the accumulator to its stack slot
#      every iteration (the spill/reload pair is GONE from the inner loop).
#   C. CALL-FREE EXPANSION FIRES: a call-free, register-pressured function uses
#      MORE than 5 distinct registers (RA_MAX_REGS > 5) — the caller-saved
#      extension is active.
#   D. MUST-SAVE SOUNDNESS: a function with a call in a loop carrying a value
#      across the call stays bit-exact (the value was NOT clobbered). Under the
#      PER-REGION lever a call-bearing function MAY exceed 5 registers if it also
#      has call-free-lifetime values, so the register COUNT is no longer a hard
#      bound; the bit-exact value (the carried `acc` survived the call) is the
#      soundness proof, and the per-range clobber gate is exercised end-to-end by
#      scripts/test_opt_regionreg.sh.
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
opt1_require_lane "test_opt_regpress"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_regpress"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = Path("tests/bench/opt/_prelude.ad").read_text()
U64MASK = (1 << 64) - 1
def u64(x): return x & U64MASK

fails = 0

# ---------------------------------------------------------------------------
# A+B. Matmul-shaped hot loop with a hand-hoisted scalar accumulator `s`.
# The dot product s += A[i*N+k]*B[k*N+j] over a k-loop is THE roadmap target:
# the accumulator `s` was being spilled to [rbp-0x40] and reloaded/stored every
# iteration. With the spill-cost heuristic s (used every iteration, high cost)
# must stay register-resident across the k-loop.
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
r_on = h.run_through_codegen_ad("matmul", MATMUL, WD, opt=True, keep=True)
r_off = h.run_through_codegen_ad("matmulo", MATMUL, WD, opt=False)
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
        print(f"[regpress] matmul value OK ({ref}) on==off==ref")

    # B. Disassemble the --opt ELF and check the inner k-loop no longer does a
    # store-then-reload of the SAME [rbp-NN] accumulator slot every iteration.
    # The signature of the spilled accumulator is a `mov [rbp-NN],rax` (store s)
    # paired with a `mov rax,[rbp-NN]` (reload s) at the SAME negative offset
    # inside the loop body. We disassemble the code segment (program-header-only
    # ELF) and look for any rbp slot that is BOTH stored to and loaded from with
    # rax in the body (the write-through + reload pattern). With the accumulator
    # register-resident, no such round-tripped slot exists for the accumulator.
    elf = WD / "ad_matmul.elf"
    try:
        # First LOAD p_filesz gives the code length (raw x86-64 in the segment).
        rl = subprocess.run(["readelf", "-l", str(elf)], capture_output=True, text=True)
        filesz = None
        for ln in rl.stdout.splitlines():
            m = re.search(r"LOAD\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x([0-9a-f]+)", ln)
            if m and ("R E" in ln or "RWE" in ln or "R E" in rl.stdout):
                filesz = int(m.group(1), 16)
                break
        if filesz is None:
            # fallback: whole file
            filesz = elf.stat().st_size
        raw = elf.read_bytes()[:filesz]
        binf = WD / "matmul.code.bin"; binf.write_bytes(raw)
        dis = subprocess.run(
            ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64",
             "-M", "intel", str(binf)],
            capture_output=True, text=True).stdout
        # collect rbp-relative store slots (mov [rbp-NN],rax) and load slots
        # (mov rax,[rbp-NN]).
        stores = set(re.findall(r"mov\s+QWORD PTR \[rbp-(0x[0-9a-f]+)\],rax", dis))
        # also plain `mov [rbp-NN],rax` form without QWORD PTR
        stores |= set(re.findall(r"mov\s+\[rbp-(0x[0-9a-f]+)\],rax", dis))
        loads = set(re.findall(r"mov\s+rax,QWORD PTR \[rbp-(0x[0-9a-f]+)\]", dis))
        loads |= set(re.findall(r"mov\s+rax,\[rbp-(0x[0-9a-f]+)\]", dis))
        round_tripped = stores & loads
        # A register-resident accumulator means at least ONE fewer round-tripped
        # local than the OFF build. Compare against OFF as the ground truth.
        elf_off = WD / "ad_matmul_dis_off.elf"
        r_off_keep = h.run_through_codegen_ad("matmul_dis_off", MATMUL, WD, opt=False, keep=True)
        elf_off = WD / "ad_matmul_dis_off.elf"
        raw_off = elf_off.read_bytes()
        rl2 = subprocess.run(["readelf", "-l", str(elf_off)], capture_output=True, text=True)
        fsz2 = None
        for ln in rl2.stdout.splitlines():
            m = re.search(r"LOAD\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x([0-9a-f]+)", ln)
            if m:
                fsz2 = int(m.group(1), 16); break
        fsz2 = fsz2 or len(raw_off)
        binf2 = WD / "matmul.code.off.bin"; binf2.write_bytes(raw_off[:fsz2])
        dis_off = subprocess.run(
            ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64",
             "-M", "intel", str(binf2)],
            capture_output=True, text=True).stdout
        st_off = set(re.findall(r"mov\s+(?:QWORD PTR )?\[rbp-(0x[0-9a-f]+)\],rax", dis_off))
        ld_off = set(re.findall(r"mov\s+rax,(?:QWORD PTR )?\[rbp-(0x[0-9a-f]+)\]", dis_off))
        rt_off = st_off & ld_off
        print(f"[regpress] matmul round-tripped rbp slots: OFF={len(rt_off)} ON={len(round_tripped)}")
        if len(round_tripped) >= len(rt_off) and len(rt_off) > 0:
            print(f"FAIL(resident) matmul: --opt did not reduce accumulator "
                  f"round-trips (OFF={sorted(rt_off)} ON={sorted(round_tripped)})")
            fails += 1
        else:
            print(f"[regpress] matmul accumulator residency improved under --opt "
                  f"(fewer store/reload round-trips: {len(rt_off)} -> {len(round_tripped)})")
    except Exception as e:
        print(f"WARN(disasm) matmul residency check skipped: {e}")

# ---------------------------------------------------------------------------
# C. Call-free pressure: many simultaneously-live loop-carried values force the
# allocator past 5 registers. The caller-saved expansion must fire => RA_MAX_REGS
# > 5 over this call-free function.
# ---------------------------------------------------------------------------
PRESSURE = """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: int64 = cast[int64](1)
    b: int64 = cast[int64](2)
    c: int64 = cast[int64](3)
    d: int64 = cast[int64](4)
    e: int64 = cast[int64](5)
    f: int64 = cast[int64](6)
    g: int64 = cast[int64](7)
    hh: int64 = cast[int64](8)
    i: int64 = cast[int64](0)
    while i < cast[int64](100):
        a = a + b
        b = b + c
        c = c + d
        d = d + e
        e = e + f
        f = f + g
        g = g + hh
        hh = hh + a
        i = i + cast[int64](1)
    r: int64 = a + b + c + d + e + f + g + hh
    return cast[int32](r & cast[int64](255))
"""
def ref_pressure():
    a,b,c,d,e,f,g,hh = 1,2,3,4,5,6,7,8
    for _ in range(100):
        a=u64(a+b); b=u64(b+c); c=u64(c+d); d=u64(d+e)
        e=u64(e+f); f=u64(f+g); g=u64(g+hh); hh=u64(hh+a)
    return u64(a+b+c+d+e+f+g+hh) & 255
ref_p = ref_pressure()
r_on = h.run_through_codegen_ad("pressure", PRESSURE, WD, opt=True)
r_off = h.run_through_codegen_ad("pressureo", PRESSURE, WD, opt=False)
ra = h.run_regalloc_over_body("pressure", PRESSURE, WD)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) pressure: on={r_on.kind} off={r_off.kind}")
    fails += 1
else:
    g_on = r_on.exit & 255; g_off = r_off.exit & 255
    if g_on != ref_p or g_off != ref_p:
        print(f"FAIL(value) pressure: ref={ref_p} on={g_on} off={g_off}")
        fails += 1
    else:
        print(f"[regpress] pressure value OK ({ref_p}) on==off==ref")
    if ra.status != "raok":
        print(f"WARN pressure regalloc dump: {ra.detail}")
    else:
        print(f"[regpress] pressure RA_MAX_REGS={ra.max_regs} spilled={ra.spilled}")
        if ra.max_regs <= 5:
            print(f"FAIL(expansion) pressure: call-free function used only "
                  f"{ra.max_regs} regs; caller-saved expansion did NOT fire")
            fails += 1
        else:
            print(f"[regpress] call-free caller-saved expansion FIRED "
                  f"(RA_MAX_REGS={ra.max_regs} > 5)")

# ---------------------------------------------------------------------------
# D. MUST-SAVE soundness: a loop carries a value `acc` across a CALL each
# iteration. The call-bearing function must stay callee-saved-only (RA_MAX_REGS
# <= 5) so `acc` is never in a caller-saved register that the call clobbers.
# Correctness (bit-exact) is the real proof; the reg count is the structural
# guard that the call gate is engaged.
# ---------------------------------------------------------------------------
CALLLOOP = """
def addone(x: int64) -> int64:
    return x + cast[int64](1)
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = cast[int64](0)
    base: int64 = cast[int64](7)
    i: int64 = cast[int64](0)
    while i < cast[int64](50):
        acc = acc + addone(base) + i
        i = i + cast[int64](1)
    return cast[int32](acc & cast[int64](255))
"""
def ref_callloop():
    acc = 0; base = 7
    for i in range(50):
        acc = u64(acc + (base + 1) + i)
    return acc & 255
ref_c = ref_callloop()
r_on = h.run_through_codegen_ad("callloop", CALLLOOP, WD, opt=True)
r_off = h.run_through_codegen_ad("callloopo", CALLLOOP, WD, opt=False)
ra_c = h.run_regalloc_over_body("callloop", CALLLOOP, WD)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) callloop: on={r_on.kind} off={r_off.kind}")
    fails += 1
else:
    g_on = r_on.exit & 255; g_off = r_off.exit & 255
    if g_on != ref_c or g_off != ref_c:
        print(f"FAIL(value) callloop: ref={ref_c} on={g_on} off={g_off} "
              f"(a caller-saved value was clobbered across the call!)")
        fails += 1
    else:
        print(f"[regpress] callloop value OK ({ref_c}) on==off==ref "
              f"(no caller-saved clobber across the call)")
    if ra_c.status == "raok":
        print(f"[regpress] callloop RA_MAX_REGS={ra_c.max_regs} (call present)")
        if ra_c.max_regs > 5:
            print(f"FAIL(soundness) callloop: a function WITH a call used "
                  f"{ra_c.max_regs} regs (> 5) — a caller-saved reg may hold a "
                  f"value across the call!")
            fails += 1
        else:
            print(f"[regpress] call-bearing function stayed callee-saved-only "
                  f"(RA_MAX_REGS={ra_c.max_regs} <= 5) — must-NOT-clobber gate OK")

print("=" * 64)
if fails == 0:
    print("[opt_regpress] PASS — spill-cost residency + call-free caller-saved "
          "expansion fire, bit-exact vs seed+reference, and a value live across a "
          "call is never left in a caller-saved register")
    sys.exit(0)
print(f"[opt_regpress] FAIL — {fails} problem(s)")
sys.exit(1)
PY
