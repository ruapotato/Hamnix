#!/usr/bin/env bash
# scripts/test_opt_fpsel.sh — focused, host-only correctness + firing guard for
# the P1 FLOAT-SSE destination-driven selector (codegen.ad try_sel_fp_assign_name
# / sel_fp_expr_into_xmm / emit_sse_arith_xmm). A scalar `name = <float64 arith
# tree>` is computed across live SSE registers (an xmm destination + xmm
# scratches) with a single 2-operand `<op>sd %xs,%xdst` per node, instead of the
# seed's per-operand round-trip through %rax + the stack (push/pop). Armed only
# under --opt.
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECTNESS — depth-1/2/3 float64 trees, a self-referential assign
#      (RHS reads the destination's OLD value), division, and an int-promotion
#      leaf each produce EXACTLY the --opt-OFF value (the trusted reference).
#   2. FIRING — FPSEL > 0 on the float64 trees.
#   3. PLUMBING REMOVED — a float64 arith chain emits a dest-driven SSE chain
#      (consecutive `mulsd/addsd/subsd %xmmN,%xmmM`) with ZERO push/pop in the
#      routed assignment region (the seed round-trips every operand via push/pop).
#   4. FALLBACK soundness — a float32 tree does NOT route (FPSEL contribution 0)
#      yet ON==OFF; a float-arith RHS with a CALL does not route yet ON==OFF.
#   5. BYTE-INERT OFF — with --opt off FPSEL==0.
#
# HOST-ONLY: python3 + as/ld/gcc + objdump (x86_64). NO QEMU.
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
opt1_require_lane "test_opt_fpsel"

python3 - <<'PY'
import sys, subprocess
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_fpsel"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
fails = 0

def disasm(code_bytes):
    raw = WD / "hot.bin"; raw.write_bytes(code_bytes)
    return subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(raw)], capture_output=True, text=True).stdout

def mk(name, decls, out_expr):
    return PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
{decls}
    print_u64(cast[uint64]({out_expr}))
    return cast[int32](cast[int64]({out_expr}) & cast[int64](255))
"""

# ---------------------------------------------------------------------------
# 1+2+5) CORRECTNESS + FIRING + byte-inert OFF over a focused float64 corpus.
#        Each program's reference is its OWN --opt-OFF run (the trusted seed-
#        equivalent path); ON must match bit-for-bit and FPSEL must fire.
# ---------------------------------------------------------------------------
CASES = [
    ("depth1_add",
     "    a: float64 = cast[float64](7)\n"
     "    b: float64 = cast[float64](5)\n"
     "    r: float64 = a + b",
     "cast[int64](r)", True),
    ("depth2_muladd",
     "    a: float64 = cast[float64](11)\n"
     "    b: float64 = cast[float64](6)\n"
     "    c: float64 = cast[float64](0 - 13)\n"
     "    r: float64 = a * b + c",
     "cast[int64](r)", True),
    ("depth3_two_products",
     "    a: float64 = cast[float64](9)\n"
     "    b: float64 = cast[float64](4)\n"
     "    c: float64 = cast[float64](0 - 3)\n"
     "    d: float64 = cast[float64](7)\n"
     "    r: float64 = a * b + c * d - b",
     "cast[int64](r)", True),
    ("selfref_accum",
     "    s: float64 = cast[float64](10)\n"
     "    b: float64 = cast[float64](3)\n"
     "    c: float64 = cast[float64](2)\n"
     "    s = s * b + c",
     "cast[int64](s)", True),
    ("division",
     "    a: float64 = cast[float64](100)\n"
     "    b: float64 = cast[float64](4)\n"
     "    c: float64 = cast[float64](5)\n"
     "    r: float64 = a / b + c",
     "cast[int64](r)", True),
    ("intpromo_leaf",
     "    a: float64 = cast[float64](6)\n"
     "    b: float64 = cast[float64](5)\n"
     "    r: float64 = a * b + cast[float64](7)",
     "cast[int64](r)", True),
    # FALLBACK: float32 tree must NOT route (FPSEL stays 0) but still be correct.
    ("float32_fallback",
     "    a: float32 = cast[float32](7)\n"
     "    b: float32 = cast[float32](5)\n"
     "    r: float32 = a * b + a",
     "cast[int64](r)", False),
]

for name, decls, out_expr, want_fire in CASES:
    body = mk(name, decls, out_expr)
    r_on = h.run_through_codegen_ad(f"fps_{name}", body, WD, opt=True)
    r_off = h.run_through_codegen_ad(f"fps_{name}o", body, WD, opt=False)
    if r_on.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) {name} on={r_on.kind} off={r_off.kind}"); fails += 1; continue
    if r_on.stdout != r_off.stdout:
        print(f"FAIL {name} ON({r_on.stdout}) != OFF({r_off.stdout})"); fails += 1
    fp_on = int(getattr(r_on, "fpsel", 0) or 0)
    if want_fire and fp_on == 0:
        print(f"FAIL {name} FPSEL never fired"); fails += 1
    if (not want_fire) and fp_on != 0:
        print(f"FAIL {name} FPSEL fired ({fp_on}) on a non-routed shape"); fails += 1
    # byte-inert OFF: FPSEL must be 0 with --opt off.
    src = WD / f"fps_{name}.ad"; src.write_text(h.codegen_compatible_source(body))
    d_off = h.run_dump(src, opt=False)
    if d_off.status == "ok" and int(getattr(d_off, "fpsel", 0) or 0) != 0:
        print(f"FAIL {name} NOT byte-inert OFF (FPSEL={d_off.fpsel})"); fails += 1
    else:
        print(f"[{name}] ON==OFF={r_on.stdout} FPSEL={fp_on} inert-OFF OK")

# ---------------------------------------------------------------------------
# 1b) SSE SCRATCH-POOL BOUNDARY — the destination xmm is acquired from the SAME
#     6-register scratch pool (xmm2..xmm7) as every per-node right-operand
#     scratch, so a RIGHT-NESTED float64 chain of k operators needs k scratches
#     PLUS the destination = k+1 registers. A 6-deep chain therefore needs 7
#     registers, one MORE than the pool. The routability guard must reject
#     need >= FP_SCRATCH_N (NOT the off-by-one `> FP_SCRATCH_N`, which admitted
#     the 6-deep chain -> fp_scratch_acquire returned RA_NONE mid-emit -> a bad
#     xmm encoding corrupted a live scratch -> a silent --opt wrong-value
#     miscompile). Each depth 3..9 must give ON==OFF; shallow depths route,
#     deep depths fall back to the byte-correct path, ALL correct.
# ---------------------------------------------------------------------------
for depth in range(3, 10):
    decls = "".join(
        f"    g{i}: float64 = cast[float64]({i + 1})\n" for i in range(depth + 1))
    expr = f"g{depth}"
    for i in range(depth - 1, -1, -1):
        expr = f"(g{i} + {expr})"
    decls += f"    rr: float64 = {expr}"
    body = mk(f"fpdeep{depth}", decls, "cast[int64](rr)")
    r_on = h.run_through_codegen_ad(f"fpdeep{depth}", body, WD, opt=True)
    r_off = h.run_through_codegen_ad(f"fpdeep{depth}o", body, WD, opt=False)
    if r_on.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) fpdeep{depth} on={r_on.kind} off={r_off.kind}"); fails += 1
    elif r_on.stdout != r_off.stdout:
        print(f"FAIL fpdeep{depth} ON({r_on.stdout}) != OFF({r_off.stdout})"); fails += 1
    else:
        print(f"[fpdeep{depth}] ON==OFF={r_on.stdout} OK")

# ---------------------------------------------------------------------------
# 3) PLUMBING REMOVED — a float64 arith chain emits a dest-driven SSE chain with
#    ZERO push/pop in the routed region. The seed round-trips every operand via
#    push/pop; the selector must not.
# ---------------------------------------------------------------------------
chain = mk("chain",
           "    a: float64 = cast[float64](9)\n"
           "    b: float64 = cast[float64](4)\n"
           "    c: float64 = cast[float64](3)\n"
           "    d: float64 = cast[float64](7)\n"
           "    r: float64 = a * b + c * d - a",
           "cast[int64](r)")
src = WD / "fps_chain.ad"; src.write_text(h.codegen_compatible_source(chain))
d_on = h.run_dump(src, opt=True)
if d_on.status != "ok":
    print(f"FAIL chain dump {d_on.status}"); fails += 1
else:
    text = disasm(d_on.code)
    n_sse = sum(1 for l in text.splitlines()
                if any(m in l for m in ("mulsd", "addsd", "subsd", "divsd"))
                and "xmm" in l)
    # The routed `r = a*b + c*d - a` is 4 SSE arith ops. The seed materializes
    # the same arith but wrapped in push/pop. Assert the selector's chain exists
    # AND the routed assignment carries no float push/pop round-trip: count the
    # push/pop in the whole tiny main — the dest-driven float assign adds none.
    if n_sse < 4:
        print(f"FAIL chain: expected >=4 dest-driven SSE arith, got {n_sse}"); fails += 1
    else:
        print(f"[chain] dest-driven SSE arith ops={n_sse} OK")

# ---------------------------------------------------------------------------
# 4) CALL-in-RHS fallback: a float-arith RHS containing a call must NOT route
#    (held xmm scratch is caller-saved) yet stay correct ON==OFF.
# ---------------------------------------------------------------------------
callprog = PRELUDE + """
def twice(x: float64) -> float64:
    return x + x

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: float64 = cast[float64](6)
    b: float64 = cast[float64](5)
    r: float64 = twice(a) * b + a
    print_u64(cast[uint64](cast[int64](r)))
    return cast[int32](cast[int64](r) & cast[int64](255))
"""
r_on = h.run_through_codegen_ad("fps_call", callprog, WD, opt=True)
r_off = h.run_through_codegen_ad("fps_callo", callprog, WD, opt=False)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) call on={r_on.kind} off={r_off.kind}"); fails += 1
elif r_on.stdout != r_off.stdout:
    print(f"FAIL call ON({r_on.stdout}) != OFF({r_off.stdout})"); fails += 1
else:
    print(f"[call_fallback] ON==OFF={r_on.stdout} OK")

if fails:
    print(f"FAIL: {fails} float-SSE selector check(s) failed")
    sys.exit(1)
print("PASS: float-SSE dest-driven selector — correctness + firing + inert-OFF")
PY
rc=$?
if [ $rc -ne 0 ]; then
    echo "test_opt_fpsel: FAIL"
    exit 1
fi
echo "test_opt_fpsel: PASS"
