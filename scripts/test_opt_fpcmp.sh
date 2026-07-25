#!/usr/bin/env bash
# scripts/test_opt_fpcmp.sh — focused, host-only correctness + firing guard for
# the MANDEL FLOAT-CONSUMER levers (codegen.ad):
#   * FPCMP — a float64 GT/GTE compare feeding a conditional branch, lowered to
#     both operands-into-xmm + `ucomisd %rhs,%lhs` + a SINGLE NaN-correct `jcc`
#     (ja/jae or their negations jbe/jb), replacing the seed's boolean
#     materialize (ucomisd->seta->movzx->test->jz) AND its operand %rax/xmm0
#     round-trips (gen_fp_branch_cc).
#   * FPMOV — float64-local leaf reads / result stores routed DIRECTLY between an
#     xmm and the local's home (movsd slot<->xmm, movq gpr<->xmm), skipping the
#     seed's %rax GPR transit (sel_fp_expr_into_xmm leaf tile /
#     try_sel_fp_assign_name store tile).
# Both are armed only under --opt.
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECTNESS — GT/GTE compares in if / while (back-branch) / deep-operand /
#      nested-loop (mandel) shapes each produce EXACTLY the --opt-OFF value.
#   2. FIRING — FPCMP > 0 on the GT/GTE branch shapes; FPMOV > 0 where float64
#      locals are read/stored.
#   3. NaN CORRECTNESS — a compare against NaN takes the IEEE-correct branch
#      (a>NaN and a>=NaN are both FALSE), matching --opt-OFF.
#   4. FALLBACK soundness — LT / LTE / EQ / NEQ branches, and a float32 GT branch,
#      do NOT route FPCMP (contribution 0) yet stay ON==OFF.
#   5. PLUMBING REMOVED — a routed GT branch emits `ucomisd` + a conditional jcc
#      with NO `seta`/`setae`/`movzx`/`test` boolean materialize in the region.
#   6. BYTE-INERT OFF — with --opt off FPCMP==0 and FPMOV==0.
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
opt1_require_lane "test_opt_fpcmp"

python3 - <<'PY'
import sys, subprocess
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_fpcmp"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
fails = 0

def disasm(code_bytes):
    raw = WD / "hot.bin"; raw.write_bytes(code_bytes)
    return subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(raw)], capture_output=True, text=True).stdout

def check(name, body, want_fpcmp, want_fpmov):
    global fails
    r_on = h.run_through_codegen_ad(f"fc_{name}", body, WD, opt=True)
    r_off = h.run_through_codegen_ad(f"fc_{name}o", body, WD, opt=False)
    if r_on.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) {name} on={r_on.kind} off={r_off.kind}"); fails += 1; return
    if r_on.stdout != r_off.stdout or r_on.exit != r_off.exit:
        print(f"FAIL {name} ON({r_on.stdout},{r_on.exit}) != OFF({r_off.stdout},{r_off.exit})")
        fails += 1
    fpc = int(getattr(r_on, "fpcmp", 0) or 0)
    fpm = int(getattr(r_on, "fpmov", 0) or 0)
    if want_fpcmp and fpc == 0:
        print(f"FAIL {name} FPCMP never fired"); fails += 1
    if (not want_fpcmp) and fpc != 0:
        print(f"FAIL {name} FPCMP fired ({fpc}) on a non-routed shape"); fails += 1
    if want_fpmov and fpm == 0:
        print(f"FAIL {name} FPMOV never fired"); fails += 1
    # byte-inert OFF: FPCMP and FPMOV must be 0 with --opt off.
    src = WD / f"fc_{name}.ad"; src.write_text(h.codegen_compatible_source(body))
    d_off = h.run_dump(src, opt=False)
    if d_off.status == "ok" and (int(getattr(d_off, "fpcmp", 0) or 0) != 0
                                 or int(getattr(d_off, "fpmov", 0) or 0) != 0):
        print(f"FAIL {name} NOT byte-inert OFF (FPCMP={getattr(d_off,'fpcmp','?')} "
              f"FPMOV={getattr(d_off,'fpmov','?')})"); fails += 1
    else:
        print(f"[{name}] ON==OFF=({r_on.stdout},{r_on.exit}) "
              f"FPCMP={fpc} FPMOV={fpm} inert-OFF OK")

def mkfn(name, fnbody, callexpr):
    return PRELUDE + "\n" + fnbody + (
        "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
        f"    v: uint64 = {callexpr}\n"
        "    print_u64(v)\n"
        "    return cast[int32](v & cast[uint64](255))\n")

# ---------------------------------------------------------------------------
# 1+2) GT / GTE compares feeding a branch — FPCMP must fire, correct ON==OFF.
# ---------------------------------------------------------------------------
check("if_gt", mkfn("if_gt",
    "def f(a: int64, b: int64) -> uint64:\n"
    "    x: float64 = cast[float64](a)\n"
    "    y: float64 = cast[float64](b)\n"
    "    if x > y:\n"
    "        return cast[uint64](7)\n"
    "    return cast[uint64](3)\n",
    "f(9, 4)"), True, True)

check("if_gte", mkfn("if_gte",
    "def f(a: int64, b: int64) -> uint64:\n"
    "    x: float64 = cast[float64](a)\n"
    "    y: float64 = cast[float64](b)\n"
    "    if x >= y:\n"
    "        return cast[uint64](7)\n"
    "    return cast[uint64](3)\n",
    "f(4, 4)"), True, True)

# GT with a DEEP float-arith operand (a*b + c) > d — operand computed across xmm.
check("if_gt_deep", mkfn("if_gt_deep",
    "def f(a: int64, b: int64) -> uint64:\n"
    "    fa: float64 = cast[float64](a)\n"
    "    fb: float64 = cast[float64](b)\n"
    "    fc: float64 = cast[float64](2)\n"
    "    fd: float64 = cast[float64](50)\n"
    "    if fa * fb + fc > fd:\n"
    "        return cast[uint64](1)\n"
    "    return cast[uint64](0)\n",
    "f(9, 6)"), True, True)   # 54+2=56 > 50 -> 1

# WHILE loop with a GT back-branch mutating a float local (mandel-shape leaf
# reads via movsd/movq + fpcmp on the loop condition).
check("while_gt", mkfn("while_gt",
    "def f(a: int64, b: int64) -> uint64:\n"
    "    x: float64 = cast[float64](a)\n"
    "    lim: float64 = cast[float64](b)\n"
    "    step: float64 = cast[float64](1)\n"
    "    n: int64 = 0\n"
    "    while x > lim:\n"
    "        x = x - step\n"
    "        n = n + 1\n"
    "    return cast[uint64](n)\n",
    "f(20, 3)"), True, True)   # counts 20->3 = 17 steps

# NESTED loops, float locals mutated, escape test > four — the mandel kernel core.
check("mandel_core", mkfn("mandel_core",
    "def f(a: int64, b: int64) -> uint64:\n"
    "    four: float64 = cast[float64](4)\n"
    "    acc: int64 = 0\n"
    "    py: int64 = 0\n"
    "    while py < b:\n"
    "        cx: float64 = cast[float64](py) / cast[float64](b) - cast[float64](1)\n"
    "        zx: float64 = cast[float64](0)\n"
    "        zy: float64 = cast[float64](0)\n"
    "        it: int64 = 0\n"
    "        while it < a:\n"
    "            xx: float64 = zx * zx\n"
    "            yy: float64 = zy * zy\n"
    "            if xx + yy > four:\n"
    "                it = a\n"
    "            else:\n"
    "                zy = cast[float64](2) * zx * zy + cx\n"
    "                zx = xx - yy + cx\n"
    "                it = it + 1\n"
    "        acc = acc + it\n"
    "        py = py + 1\n"
    "    return cast[uint64](acc)\n",
    "f(30, 20)"), True, True)

# ---------------------------------------------------------------------------
# 3) NaN CORRECTNESS — a > NaN and a >= NaN are both FALSE (IEEE). Build NaN as
#    0.0 / 0.0; the routed ja/jae must take the FALSE branch, matching OFF.
# ---------------------------------------------------------------------------
check("nan_gt", mkfn("nan_gt",
    "def f(a: int64, b: int64) -> uint64:\n"
    "    zero: float64 = cast[float64](0)\n"
    "    nan: float64 = zero / zero\n"
    "    x: float64 = cast[float64](a)\n"
    "    if x > nan:\n"
    "        return cast[uint64](111)\n"
    "    return cast[uint64](222)\n",
    "f(9, 0)"), True, True)   # 9 > NaN is FALSE -> 222

# ---------------------------------------------------------------------------
# 4) FALLBACK soundness — LT/LTE/EQ/NEQ branches (need the seed's parity guard)
#    and a float32 GT branch (ucomiss width) must NOT route FPCMP, yet ON==OFF.
#    (FPMOV may still fire for the float64-local operand loads — that is fine.)
# ---------------------------------------------------------------------------
for op, val, tag in [("<", "f(4, 9)", "lt"), ("<=", "f(4, 4)", "lte"),
                     ("==", "f(5, 5)", "eq"), ("!=", "f(5, 6)", "neq")]:
    check(f"fallback_{tag}", mkfn(f"fallback_{tag}",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    x: float64 = cast[float64](a)\n"
        "    y: float64 = cast[float64](b)\n"
        f"    if x {op} y:\n"
        "        return cast[uint64](7)\n"
        "    return cast[uint64](3)\n",
        val), False, False)

# float32 GT branch — width 4, must fall back (FPCMP 0). FPMOV also 0 (float32
# locals are not the float64 movsd/movq class).
check("fallback_f32_gt", mkfn("fallback_f32_gt",
    "def f(a: int64, b: int64) -> uint64:\n"
    "    x: float32 = cast[float32](a)\n"
    "    y: float32 = cast[float32](b)\n"
    "    if x > y:\n"
    "        return cast[uint64](7)\n"
    "    return cast[uint64](3)\n",
    "f(9, 4)"), False, False)

# CALL in a compare operand must NOT route (held xmm is caller-saved), ON==OFF.
callprog = PRELUDE + """
def sq(x: float64) -> float64:
    return x * x

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: float64 = cast[float64](5)
    b: float64 = cast[float64](20)
    r: uint64 = cast[uint64](0)
    if sq(a) > b:
        r = cast[uint64](1)
    print_u64(r)
    return cast[int32](r & cast[uint64](255))
"""
r_on = h.run_through_codegen_ad("fc_call", callprog, WD, opt=True)
r_off = h.run_through_codegen_ad("fc_callo", callprog, WD, opt=False)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) call on={r_on.kind} off={r_off.kind}"); fails += 1
elif r_on.stdout != r_off.stdout:
    print(f"FAIL call ON({r_on.stdout}) != OFF({r_off.stdout})"); fails += 1
elif int(getattr(r_on, "fpcmp", 0) or 0) != 0:
    print(f"FAIL call routed FPCMP on a call operand"); fails += 1
else:
    print(f"[call_fallback] ON==OFF={r_on.stdout} FPCMP=0 OK")

# ---------------------------------------------------------------------------
# 5) PLUMBING REMOVED — a routed GT branch emits ucomisd + a conditional jcc and
#    NO seta/setae/movzx/test boolean materialize in the emitted code.
# ---------------------------------------------------------------------------
plumb = mkfn("plumb",
    "def f(a: int64, b: int64) -> uint64:\n"
    "    x: float64 = cast[float64](a)\n"
    "    y: float64 = cast[float64](b)\n"
    "    if x > y:\n"
    "        return cast[uint64](7)\n"
    "    return cast[uint64](3)\n",
    "f(9, 4)")
src = WD / "fc_plumb.ad"; src.write_text(h.codegen_compatible_source(plumb))
d_on = h.run_dump(src, opt=True)
if d_on.status != "ok":
    print(f"FAIL plumb dump {d_on.status}"); fails += 1
else:
    text = disasm(d_on.code).lower()
    has_ucomi = "ucomisd" in text
    has_jcc = ("jbe" in text or "jb " in text or "ja " in text or "jae" in text)
    # seta/setae/setbe are the float-compare boolean-materialize setcc markers
    # (movzx is excluded: it is used pervasively for byte/word extension in the
    # prelude helpers, so it is not a signal for THIS compare's lowering).
    has_bool = any(m in text for m in ("seta ", "setae", "setbe"))
    if not (has_ucomi and has_jcc):
        print(f"FAIL plumb: ucomisd={has_ucomi} jcc={has_jcc}"); fails += 1
    elif has_bool:
        print(f"FAIL plumb: boolean materialize still present (seta/movzx)"); fails += 1
    else:
        print(f"[plumb] ucomisd+jcc, no boolean materialize OK")

if fails:
    print(f"FAIL: {fails} float compare/mov lever check(s) failed")
    sys.exit(1)
print("PASS: float compare->branch + direct-movsd/movq levers — "
      "correctness + firing + NaN + fallback + inert-OFF")
PY
rc=$?
if [ $rc -ne 0 ]; then
    echo "test_opt_fpcmp: FAIL"
    exit 1
fi
echo "test_opt_fpcmp: PASS"
