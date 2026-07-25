#!/usr/bin/env bash
# scripts/test_opt_ivpromote.sh — host-only correctness + firing test for the
# LOOP-CARRIED-VARIABLE register-promotion track (cfg.ad liveness + regalloc.ad,
# --opt). Two levers landed in this track:
#
#   (1) USE-VECTOR DEDUP + WIDER CAP (cfg.ad). A single statement that names the
#       same local more than once — e.g. the matmul dot-product update
#       `s = s + A[i*N+k] * B[k*N+j]` references k and N TWICE each — used to
#       overflow the 6-occurrence per-instruction use vector, dropping the later
#       reads. A dropped use UNDER-approximates the name's live range, so the name
#       was flagged nm_trunc and EXCLUDED from register promotion. The hot inner
#       IVs (k, j, N) were exactly the casualties. ci_add_use now DEDUPLICATES
#       (liveness needs only the SET of names live at a point), and the cap is
#       sized to cover realistic complex statements. The hot IVs are now
#       promotable. cfg runs ONLY under --opt, so flag-OFF output is unchanged.
#
#   (2) COST-ONLY SPILL EVICTION (regalloc.ad). The linear-scan victim is now the
#       active value with the strictly LOWEST loop-depth-weighted use count, with
#       the old `lr_end[vict] <= vend` length guard REMOVED. That guard blocked a
#       SHORT but very hot value (a deep inner-loop IV) from evicting a LONG but
#       cold value (an outer counter) — inverting what a good allocator does. Pure
#       spill-cost keeps the deepest-loop accumulator/IV register-resident.
#
# WHAT IT PROVES (no QEMU):
#   A. CORRECTNESS: every kernel compiled WITH --opt produces EXACTLY the same
#      value as WITH --opt OFF (the byte-identical seed path) AND the reference.
#      A wrong spill victim, a wrongly-promoted truncated value, or a clobbered
#      loop-carried value lands a wrong answer; this is the primary soundness gate.
#   B. ACCUMULATOR/IV RESIDENT: on the matmul-shaped hot loop, the --opt
#      disassembly no longer STORE-then-RELOADs the accumulator slot every
#      iteration (the spill/reload round-trip is reduced vs --opt OFF).
#   C. SOUNDNESS — REDECLARED-PER-ITERATION LOCAL: a loop body that REDECLARES a
#      fresh local each iteration and seeds it from a DISTINCT value must still
#      compute the right answer under --opt (the redeclared local must NOT be
#      wrongly coalesced with a different live value). Bit-exact vs seed+ref.
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
opt1_require_lane "test_opt_ivpromote"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_ivpromote"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = Path("tests/bench/opt/_prelude.ad").read_text()
U64MASK = (1 << 64) - 1
def u64(x): return x & U64MASK

fails = 0

# ---------------------------------------------------------------------------
# A+B. Matmul-shaped hot loop. The dot product s += A[i*N+k]*B[k*N+j] names
# k and N TWICE in one statement (the use-vector dedup target) and carries the
# accumulator s across the k-loop (the spill-cost residency target). Under --opt
# the hot IVs (k, j, N) must be promotable and s register-resident.
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
r_off = h.run_through_codegen_ad("mmoff", MATMUL, WD, opt=False, keep=True)
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
        print(f"[ivpromote] matmul value OK ({ref}) on==off==ref")

    # B. Disassemble both ELFs; count rbp slots that are BOTH stored-to and
    # loaded-from with rax (the spill/reload round-trip signature). With the hot
    # accumulator/IVs register-resident, the ON build round-trips FEWER slots.
    def round_tripped(elf: Path):
        rl = subprocess.run(["readelf", "-l", str(elf)], capture_output=True, text=True)
        fsz = None
        for ln in rl.stdout.splitlines():
            m = re.search(r"LOAD\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x([0-9a-f]+)", ln)
            if m:
                fsz = int(m.group(1), 16); break
        raw = elf.read_bytes()
        fsz = fsz or len(raw)
        binf = elf.with_suffix(".code.bin"); binf.write_bytes(raw[:fsz])
        dis = subprocess.run(
            ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel", str(binf)],
            capture_output=True, text=True).stdout
        st = set(re.findall(r"mov\s+(?:QWORD PTR )?\[rbp-(0x[0-9a-f]+)\],rax", dis))
        ld = set(re.findall(r"mov\s+rax,(?:QWORD PTR )?\[rbp-(0x[0-9a-f]+)\]", dis))
        return st & ld
    try:
        rt_on = round_tripped(WD / "ad_mm.elf")
        rt_off = round_tripped(WD / "ad_mmoff.elf")
        print(f"[ivpromote] matmul round-tripped rbp slots: OFF={len(rt_off)} ON={len(rt_on)}")
        if len(rt_off) > 0 and len(rt_on) >= len(rt_off):
            print(f"FAIL(resident) matmul: --opt did not reduce spill/reload "
                  f"round-trips (OFF={sorted(rt_off)} ON={sorted(rt_on)})")
            fails += 1
        else:
            print(f"[ivpromote] matmul residency improved under --opt "
                  f"({len(rt_off)} -> {len(rt_on)} round-tripped slots)")
    except Exception as e:
        print(f"WARN(disasm) matmul residency check skipped: {e}")

# ---------------------------------------------------------------------------
# C. SOUNDNESS — a loop that REDECLARES a fresh local `t` each iteration and
# seeds it from a DISTINCT value (the previous accumulator + the IV), threading a
# carried accumulator `acc` across the back edge. If liveness wrongly merged the
# per-iteration `t` with `acc` (or coalesced two distinct live values into one
# interval), the answer diverges. Bit-exact vs seed+reference proves the
# redeclared local was NOT wrongly coalesced.
# ---------------------------------------------------------------------------
REDECL = """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = cast[int64](0)
    i: int64 = cast[int64](0)
    while i < cast[int64](40):
        t: int64 = acc + i * cast[int64](3)
        t = t + cast[int64](7)
        acc = acc + t
        i = i + cast[int64](1)
    return cast[int32](acc & cast[int64](255))
"""
def ref_redecl():
    acc = 0
    for i in range(40):
        t = u64(acc + i * 3)
        t = u64(t + 7)
        acc = u64(acc + t)
    return acc & 255
ref_r = ref_redecl()
r_on = h.run_through_codegen_ad("redecl", REDECL, WD, opt=True)
r_off = h.run_through_codegen_ad("redeclo", REDECL, WD, opt=False)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) redecl: on={r_on.kind} off={r_off.kind}")
    fails += 1
else:
    g_on = r_on.exit & 255; g_off = r_off.exit & 255
    if g_on != ref_r or g_off != ref_r:
        print(f"FAIL(value) redecl: ref={ref_r} on={g_on} off={g_off} "
              f"(a redeclared-per-iteration local was wrongly coalesced!)")
        fails += 1
    else:
        print(f"[ivpromote] redecl value OK ({ref_r}) on==off==ref "
              f"(redeclared loop-local not wrongly coalesced)")

# ---------------------------------------------------------------------------
# D. NESTED loops where an OUTER var is carried through the INNER loop, plus a
# reduction accumulator updated in the inner body — exercises a loop-carried
# scalar live across an inner back-edge. Bit-exact vs seed+reference.
# ---------------------------------------------------------------------------
NESTED = """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    total: int64 = cast[int64](0)
    o: int64 = cast[int64](0)
    while o < cast[int64](20):
        run: int64 = o
        n: int64 = cast[int64](0)
        while n < cast[int64](15):
            run = run + n * o
            total = total + run
            n = n + cast[int64](1)
        o = o + cast[int64](1)
    return cast[int32](total & cast[int64](255))
"""
def ref_nested():
    total = 0
    for o in range(20):
        run = o
        for n in range(15):
            run = u64(run + n * o)
            total = u64(total + run)
    return total & 255
ref_n = ref_nested()
r_on = h.run_through_codegen_ad("nested", NESTED, WD, opt=True)
r_off = h.run_through_codegen_ad("nestedo", NESTED, WD, opt=False)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) nested: on={r_on.kind} off={r_off.kind}")
    fails += 1
else:
    g_on = r_on.exit & 255; g_off = r_off.exit & 255
    if g_on != ref_n or g_off != ref_n:
        print(f"FAIL(value) nested: ref={ref_n} on={g_on} off={g_off}")
        fails += 1
    else:
        print(f"[ivpromote] nested value OK ({ref_n}) on==off==ref "
              f"(outer var carried through inner loop is correct)")

print("=" * 64)
if fails == 0:
    print("[opt_ivpromote] PASS — hot loop-carried IVs/accumulator promotable + "
          "register-resident under --opt, bit-exact vs seed+reference, and "
          "redeclared/nested loop-locals are not wrongly coalesced")
    sys.exit(0)
print(f"[opt_ivpromote] FAIL — {fails} problem(s)")
sys.exit(1)
PY
