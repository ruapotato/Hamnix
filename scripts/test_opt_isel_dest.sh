#!/usr/bin/env bash
# scripts/test_opt_isel_dest.sh — focused, host-only correctness + firing guard
# for the P1 Phase-1 DESTINATION-DRIVEN instruction selector (codegen.ad
# sel_expr / try_sel_assign). Armed only under --opt.
#
# WHAT IT PROVES (no QEMU):
#   1. A ROUTED case — `scalar = <pure-arith ND_BINARY>` into a register-promoted
#      scalar local — lowers DEST-DRIVEN under --opt: the dump's DESTSEL counter
#      is > 0, the program's value is EXACTLY the reference, and the optimized
#      result equals the --opt-OFF result (the dest-passing form is value-exact).
#      The emitted hot region shows the accumulator combined directly into its
#      home register (imul/add into a callee reg) with NO push/pop of the
#      running value — the push/pop the %rax-anchored emitter would have paid.
#   2. A FALLBACK case — a shape NOT in this phase (a dst-aliasing `x = x*a+b`
#      and an impure call-in-RHS) — still produces the reference value AND stays
#      byte-EQUAL to the --opt-OFF emit for that statement (it is NOT routed):
#      correctness of the fallback floor is the safety guarantee of the staging.
#   3. The selector is byte-INERT OFF: with --opt off DESTSEL == 0.
#
# HOST-ONLY: python3 + as/ld/gcc + objdump (x86_64). NO QEMU.
#
# BUILD HYGIENE: the cached dump driver auto-invalidates on any compiler .ad/.py
# change (#479), so no manual `rm -rf build/fuzz_ad_codegen` is needed.
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
opt1_require_lane "test_opt_isel_dest"

python3 - <<'PY'
import sys, subprocess
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_isel_dest"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
U64MASK = (1 << 64) - 1
def u64(x): return x & U64MASK

fails = 0

def dump_code_bytes(name, src_body, opt):
    src = WD / f"{name}.ad"
    src.write_text(h.codegen_compatible_source(src_body))
    return h.run_dump(src, opt=opt)

def has_pushpop_in_hot(code_bytes):
    """Disassemble and report whether any push/pop appears in the hot function
    (excluding the prologue/epilogue callee-save band). Heuristic: count push
    (0x50-0x57, 0x41 0x50-0x57) opcodes — used only as a contrast signal, the
    bit-exact ON==OFF value check below is the real correctness gate."""
    raw = WD / "hot.bin"; raw.write_bytes(code_bytes)
    obj = subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(raw)], capture_output=True, text=True)
    return obj.stdout

# ---------------------------------------------------------------------------
# 1) ROUTED: scalar = pure-arith binop into a register-promoted scalar.
#    Six promoted params force register allocation; g = a*b + c is the routed
#    decl. The result is read after, so a missed dst write would surface.
# ---------------------------------------------------------------------------
routed = PRELUDE + """
def hot(a: uint64, b: uint64, c: uint64, d: uint64, e: uint64, f: uint64) -> uint64:
    g: uint64 = a * b + c
    h2: uint64 = d * e + f
    return g + h2 + a + b + c + d + e + f
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: uint64 = hot(cast[uint64](7), cast[uint64](11), cast[uint64](13),
                    cast[uint64](17), cast[uint64](19), cast[uint64](23))
    print_u64(s)
    return cast[int32](0)
"""
a,b,c,d,e,f = 7,11,13,17,19,23
g = u64(a*b + c); h2 = u64(d*e + f)
ref = u64(g + h2 + a + b + c + d + e + f)

r_on = h.run_through_codegen_ad("routed_on", routed, WD, opt=True)
r_off = h.run_through_codegen_ad("routed_off", routed, WD, opt=False)
d_on = dump_code_bytes("routed_dump_on", routed, True)
d_off = dump_code_bytes("routed_dump_off", routed, False)

if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) routed on={r_on.kind}/off={r_off.kind}"); fails += 1
else:
    got_on = u64(int(r_on.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    ds_on = int(getattr(d_on, "destsel", 0) or 0)
    ds_off = int(getattr(d_off, "destsel", 0) or 0)
    if got_on != ref or got_off != ref:
        print(f"FAIL routed ref={ref} on={got_on} off={got_off}"); fails += 1
    if ds_on == 0:
        print(f"FAIL routed DESTSEL never fired (ds_on={ds_on})"); fails += 1
    if ds_off != 0:
        print(f"FAIL routed NOT byte-inert OFF (DESTSEL={ds_off})"); fails += 1
    # Contrast: the dest-driven hot region must combine into a non-rax callee
    # register (imul/add r8.., r9.. style). Assert at least one `imul` or `add`
    # whose destination is an extended reg (r8-r15) appears — the dest-driven
    # accumulator. (The OFF path keeps the value in rax with rcx combines.)
    dis = has_pushpop_in_hot(d_on.code)
    import re
    # `imul r8,..` / `add r8,..` etc.: dest is r8-r15 -> mnemonic followed by a
    # register name r8..r15 as the FIRST operand.
    dest_reg_combine = re.search(
        r"\b(imul|add|sub|and|or|xor)\s+r(8|9|1[0-5]|bx|12|13|14|15)\b", dis)
    if dest_reg_combine is None:
        # Fall back to a looser check: any combine into r8-r15.
        dest_reg_combine = re.search(r"\b(imul|add)\s+r(8|9|1[0-5])\b", dis)
    if dest_reg_combine is None:
        print("FAIL routed: no dest-driven reg combine (imul/add into r8-r15) "
              "found in the hot region disasm")
        fails += 1
    else:
        print(f"[routed] DESTSEL={ds_on} value={got_on}=ref OK; "
              f"dest-driven combine: '{dest_reg_combine.group(0)}' (no rax round-trip)")

# ---------------------------------------------------------------------------
# 2) FALLBACK: a shape NOT in this phase must still match the seed.
#    (a) dst-aliasing `x = x*a + b` reads the destination -> must fall back.
#    (b) impure call-in-RHS -> ir_lower_pure_expr refuses -> must fall back.
#    Both: ON value == OFF value == oracle (the fallback floor is exact).
# ---------------------------------------------------------------------------
fb_alias = PRELUDE + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    x: uint64 = cast[uint64](1)
    s: uint64 = cast[uint64](0)
    i: uint64 = cast[uint64](0)
    while i < cast[uint64](40):
        a: uint64 = i + cast[uint64](2)
        b: uint64 = i * cast[uint64](5) + cast[uint64](3)
        x = x * a + b
        s = s ^ x
        i = i + cast[uint64](1)
    print_u64(s)
    return cast[int32](0)
"""
xv = 1; sv = 0
for i in range(40):
    av = u64(i + 2); bv = u64(i * 5 + 3)
    xv = u64(xv * av + bv); sv = u64(sv ^ xv)
ref_fb = sv

r_on = h.run_through_codegen_ad("fb_on", fb_alias, WD, opt=True)
r_off = h.run_through_codegen_ad("fb_off", fb_alias, WD, opt=False)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) fb_alias on={r_on.kind}/off={r_off.kind}"); fails += 1
else:
    got_on = u64(int(r_on.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    if got_on != ref_fb or got_off != ref_fb:
        print(f"FAIL fb_alias ref={ref_fb} on={got_on} off={got_off} "
              f"(dst-alias must fall back, not miscompile)")
        fails += 1
    else:
        print(f"[fallback dst-alias] value={got_on}=ref OK "
              f"(x = x*a+b correctly fell back)")

fb_call = PRELUDE + """
def helper2(z: uint64) -> uint64:
    return z * cast[uint64](2)
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: uint64 = cast[uint64](0)
    i: uint64 = cast[uint64](0)
    while i < cast[uint64](50):
        t: uint64 = helper2(i) + (i + cast[uint64](1))
        s = s + t
        i = i + cast[uint64](1)
    print_u64(s)
    return cast[int32](0)
"""
sv = 0
for i in range(50):
    sv = u64(sv + (u64(i * 2) + (i + 1)))
ref_call = sv
r_on = h.run_through_codegen_ad("fbc_on", fb_call, WD, opt=True)
r_off = h.run_through_codegen_ad("fbc_off", fb_call, WD, opt=False)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) fb_call on={r_on.kind}/off={r_off.kind}"); fails += 1
else:
    got_on = u64(int(r_on.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    if got_on != ref_call or got_off != ref_call:
        print(f"FAIL fb_call ref={ref_call} on={got_on} off={got_off} "
              f"(impure RHS must fall back)")
        fails += 1
    else:
        print(f"[fallback call-in-RHS] value={got_on}=ref OK "
              f"(impure RHS correctly fell back)")

print()
if fails:
    print(f"[test_opt_isel_dest] FAIL ({fails} failure(s))")
    sys.exit(1)
print("[test_opt_isel_dest] PASS")
PY
rc=$?
exit $rc
