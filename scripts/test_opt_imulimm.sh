#!/usr/bin/env bash
# scripts/test_opt_imulimm.sh — focused, host-only correctness + firing guard for
# the IMUL-CONST-MATERIALIZE lever (codegen.ad sel_combine_into_home + the legacy
# gen_expr_ir binop arm). Armed only under --opt; byte-identical to the frozen
# seed OFF.
#
# THE LEVER: `x * C` for a non-negative imm32 constant C (C <= 0x7FFFFFFF) is
# emitted as the single x86 3-operand `imul %dst,%src,$C` (6B imm8 form for
# C<=127, else 7B imm32 form) instead of materializing C into a scratch register
# and doing a 2-operand imul (`mov $C,%scratch; imul %scratch,%r`). MUL is
# commutative, so C may be on either side. The gate C<=0x7FFFFFFF makes C
# sign-extend to itself, so the low 64 bits of the product are identical whether
# read signed or unsigned — exactly what the 2-operand imul it replaces computed.
# Hot in collatz (`n*3`) and dcecopy (`i*2`); fires in every bench kernel with a
# constant multiply.
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECT + MATCHES OFF: const-multiply kernels produce EXACTLY the reference
#      value under --opt AND equal the --opt-OFF value.
#   2. THE 3-OPERAND FORM IS EMITTED: in the ON disassembly a constant multiply is
#      one `imul <reg>,<reg>,<imm>` with NO preceding `mov $C,<scratch>` const
#      materialize for that multiply.
#   3. FIRED + BYTE-INERT OFF: IMULIMM>0 under --opt; IMULIMM==0 with --opt off.
#   4. SAFETY: the differential corpus (adder_fuzzer._run_imulimm_corpus) pins the
#      emitted immediate + source operand across dst-alias (`s = s*3`), the
#      imm8/imm32 boundary (127/128), imm32-max (0x7FFFFFFF), and signed/unsigned
#      operands — a wrong immediate or wrong source operand is a value mismatch the
#      oracle catches — and asserts a var*var multiply does NOT fire the lever.
#      The DELIBERATE-BREAK for this net: change emit_imul_imm_reg to encode
#      `imm+1` (or swap the dst/src modrm fields) — the dst-alias and imm32-max
#      cases then miscompile, proving the corpus sees the bug; revert to restore.
#
# HOST-ONLY: python3 + as/ld/gcc + objdump (x86_64). NO QEMU. The cached dump
# driver under build/fuzz_ad_codegen AUTO-INVALIDATES on any compiler change.
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
opt1_require_lane "test_opt_imulimm"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_imulimm"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
M = (1 << 64) - 1
fails = 0

# ---------------------------------------------------------------------------
# A Horner-style checksum hot loop with a constant multiply `acc*101 + i`. NOTE
# the previous collatz probe (`3*n + 1`) is NO LONGER valid here: the Phase-5 DAG
# tiler (3a4de73d) now folds a small-scale constant multiply-add into a single
# `lea [base + idx*S + K]` (S in {1,2,4,8}, absorbing *3/*5/*9), a strictly better
# lowering than imul — so the imul-imm lever legitimately does NOT fire for those.
# 101 is not a lea scale, so `acc*101` must still lower to the 3-operand
# `imul %acc,%acc,$0x65` this lever targets.
# ---------------------------------------------------------------------------
N = 100000
acc = 0
for i in range(N):
    acc = (acc * 101 + i) & M
ref = acc & M

SRC = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    i: int64 = 0
    while i < {N}:
        acc = acc * 101 + i
        i = i + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
"""

r_on = h.run_through_codegen_ad("imm_on", SRC, WD, opt=True, keep=True)
r_off = h.run_through_codegen_ad("imm_off", SRC, WD, opt=False, keep=True)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) on={r_on.kind}/off={r_off.kind} "
          f"{(r_on.detail or r_off.detail)[:160]}")
    sys.exit(1)

# (1) correctness ON==OFF==ref
if r_on.stdout != str(ref) or r_off.stdout != str(ref):
    print(f"FAIL(value) ref={ref} on={r_on.stdout} off={r_off.stdout}"); fails += 1
else:
    print(f"[value] on==off==ref ({ref}) OK")

# (3) fired + byte-inert OFF
im_on = int(getattr(r_on, "imulimm", 0) or 0)
im_off = int(getattr(r_off, "imulimm", 0) or 0)
if im_on < 1:
    print(f"FAIL(no-fire) imulimm_on={im_on} (<1: the acc*101 multiply did not "
          f"lower to a 3-operand imul)"); fails += 1
elif im_off != 0:
    print(f"FAIL(off-fired) imulimm_off={im_off} (must be 0 — byte-inert OFF)")
    fails += 1
else:
    print(f"[fire] imulimm_on={im_on} imulimm_off=0 OK")

# (2) DISASM: a constant multiply is one `imul <reg>,<reg>,<imm>` with NO
#     preceding `mov $C,<scratch>` const-materialize for that multiply.
def disasm(dump):
    raw = WD / "imm.code.bin"; raw.write_bytes(dump.code)
    txt = subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(raw)], capture_output=True, text=True).stdout
    rows = []
    for ln in txt.splitlines():
        mm = re.match(r"\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(.*)$", ln)
        if mm:
            rows.append(mm.group(2).strip())
    return rows

try:
    dsrc = WD / "imm_dump.ad"
    dsrc.write_text(h.codegen_compatible_source(SRC))
    d_on = h.run_dump(dsrc, opt=True)
    if d_on.status != "ok":
        raise RuntimeError(f"run_dump status={d_on.status} "
                           f"{getattr(d_on, 'detail', '')[:160]}")
    rows = disasm(d_on)
    # 3-operand imul: `imul <reg>,<reg>,<imm>` (three comma-separated operands).
    three_op = 0
    for t in rows:
        if re.match(r"imul\s+\w+,\w+,0x[0-9a-f]+", t):
            three_op += 1
    if three_op < 1:
        print(f"FAIL(disasm) found {three_op} 3-operand imul (expected >=1 for "
              f"the acc*101 multiply)"); fails += 1
    else:
        print(f"[disasm] {three_op} 3-operand imul-by-const emitted OK")
except Exception as ex:
    print(f"FAIL(disasm) exception: {ex}"); fails += 1

# (4) SAFETY: a differential corpus pinning the emitted immediate + source operand
#     across dst-alias, the imm8/imm32 boundary (127/128), imm32-max (0x7FFFFFFF)
#     and signed/unsigned operands, plus a var*var fallback that must NOT fire (a
#     wrong immediate / wrong source operand = a value mismatch the oracle catches).
#     INLINED here (previously adder_fuzzer._run_imulimm_corpus) and repointed OFF
#     the lea-scale constants 3/5/9: the DAG tiler (3a4de73d) now lowers those to a
#     single `lea` (strictly better than imul), so the imul-imm lever correctly
#     does not fire for them — 7/11/13/100/127/128/0x7FFFFFFF are not lea scales and
#     still exercise the lever. The corpus intent (operand pinning, dst-alias,
#     boundaries, unsigned, fallback-must-not-fire) is preserved verbatim.
def _imm_case(name, body, exp_out, want_fire):
    global fails
    exp_exit = exp_out & 255
    r_on = h.run_through_codegen_ad(f"cimm_{name}", body, WD, opt=True)
    r_off = h.run_through_codegen_ad(f"cimm_{name}o", body, WD, opt=False)
    if r_on.kind != "ok" or r_off.kind != "ok":
        print(f"  [imulimm corpus '{name}'] codegen on={r_on.kind}/off={r_off.kind}: "
              f"{(r_on.detail or r_off.detail or '')[:120]}"); fails += 1
        return 0
    io = int(getattr(r_on, "imulimm", 0) or 0)
    iof = int(getattr(r_off, "imulimm", 0) or 0)
    if r_on.stdout != str(exp_out) or r_on.exit != exp_exit:
        print(f"  [imulimm corpus '{name}'] MISCOMPILE opt=({r_on.stdout},"
              f"{r_on.exit}) oracle=({exp_out},{exp_exit})"); fails += 1
    if r_off.stdout != str(exp_out) or r_off.exit != exp_exit:
        print(f"  [imulimm corpus '{name}'] OFF wrong=({r_off.stdout},"
              f"{r_off.exit}) oracle=({exp_out},{exp_exit})"); fails += 1
    if iof != 0:
        print(f"  [imulimm corpus '{name}'] NOT byte-inert OFF (imulimm={iof})"); fails += 1
    if want_fire and io == 0:
        print(f"  [imulimm corpus '{name}'] lever never fired (imulimm_on=0)"); fails += 1
    if (not want_fire) and io != 0:
        print(f"  [imulimm corpus '{name}'] lever fired on a non-const multiply "
              f"(imulimm_on={io})"); fails += 1
    return io

def _fn(decls_main):
    return PRELUDE + "\n" + decls_main

def _f_const(ret_expr, xtype, xval, ret_type="int64"):
    call = f"cast[uint64](f(cast[int64]({xval})))" if ret_type == "int64" \
        else f"f(cast[uint64]({xval}))"
    return _fn(
        f"def f(x: {xtype}) -> {ret_type}:\n    return {ret_expr}\n"
        "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
        f"    g_accum = {call}\n"
        "    print_u64(g_accum)\n"
        "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n")

im_total = 0
x = 123456789   # const on the RIGHT, imm8: x * 7
im_total += _imm_case("mul_c_right", _f_const("x * 7", "int64", x), (x * 7) & M, True)
x = 98765       # const on the LEFT (commutative), imm8: 11 * x   [was 9*x -> lea]
im_total += _imm_case("mul_c_left", _f_const("11 * x", "int64", x), (11 * x) & M, True)
n = 20; s = 1   # dst-ALIAS accumulator loop: s = s*11 + 1   [was s*3+1 -> lea muladd]
for _ in range(n): s = (s * 11 + 1) & M
im_total += _imm_case("mul_dst_alias_loop", _fn(
    "def hot(n: int64) -> int64:\n    s: int64 = 1\n    i: int64 = 0\n"
    "    while i < n:\n        s = s * 11 + 1\n        i = i + 1\n    return s\n"
    "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
    f"    g_accum = cast[uint64](hot(cast[int64]({n})))\n"
    "    print_u64(g_accum)\n"
    "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n"), s, True)
x = 777         # imm8 boundary: x*127 (last imm8) and x*128 (first imm32 form)
im_total += _imm_case("mul_imm8_max", _f_const("x * 127", "int64", x), (x * 127) & M, True)
im_total += _imm_case("mul_imm32_first", _f_const("x * 128", "int64", x), (x * 128) & M, True)
x = 3           # imm32-MAX: x * 0x7FFFFFFF (largest C that sign-extends to itself)
im_total += _imm_case("mul_imm32_max", _f_const("x * 2147483647", "int64", x),
                      (x * 2147483647) & M, True)
x = (1 << 40) + 12345   # UNSIGNED operand: (uint64)x * 13   [was *5 -> lea]
im_total += _imm_case("mul_unsigned", _f_const("x * 13", "uint64", x, "uint64"),
                      (x * 13) & M, True)
x, y = 6001, 7  # FALLBACK: x * y (both variable) — lever must NOT fire.
im_total += _imm_case("mul_var_var_fallback", _fn(
    "def f(x: int64, y: int64) -> int64:\n    return x * y\n"
    "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
    f"    g_accum = cast[uint64](f(cast[int64]({x}), cast[int64]({y})))\n"
    "    print_u64(g_accum)\n"
    "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n"), (x * y) & M, False)

if im_total == 0:
    print(f"FAIL(corpus) imulimm differential corpus inert (0 imul-imm fires)")
    fails += 1
else:
    print(f"[corpus] imulimm corpus OK ({im_total} imul-imm fires, fallback "
          f"var*var did not fire)")

if fails:
    print(f"\n[test_opt_imulimm] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_imulimm] PASS (const multiply -> 3-operand imul, correct, "
      "fired, byte-inert OFF, immediate/operand pinned by the corpus)")
PY
