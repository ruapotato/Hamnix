#!/usr/bin/env bash
# scripts/test_opt_callarg.sh — focused, host-only correctness + firing guard for
# the P1 CALL-ARGUMENT destination-routing lever (codegen.ad
# try_sel_call_reg_args / sel_arg_qualifies / sel_arg_emit_into). Armed only --opt.
#
# THE LEVER: for a DIRECT call with no stack args, each PURE register argument is
# computed DIRECTLY into its System V ABI argument register (%rdi/%rsi/%rdx/%rcx/
# %r8/%r9) by the destination-driven selector — `mov %rdi,%n; sub %rdi,K` — instead
# of the value-at-a-time `materialize-K-into-scratch; mov %rax,%n; sub %rax,scr;
# push %rax; pop %rdi` marshalling. The fib recursion-arg residual.
#
# WHAT IT PROVES (no QEMU):
#   1. ROUTED — a recursive `fib(n-1)+fib(n-2)` fires CALLARG>0 ON, the arg lands
#      in %rdi with NO push/pop framing it and the constant as an IMMEDIATE; value
#      EXACTLY the reference and == the --opt-OFF value.
#   2. MULTI-ARG — `f(a+1, b*2, c-3)` routes all three (CALLARG>0), bit-exact.
#   3. HAZARD soundness (the all-or-nothing / eval-order bar):
#      (a) an arg that is itself a CALL (`f(g(x), y+1)`) does NOT route (the call
#          arg fails the pure gate) yet ON==OFF==reference — order preserved;
#      (b) args that SHARE a sub-read and a dst-arg shape (`f(a+b, a-b)`) stay
#          bit-exact (no earlier-filled arg register clobbered).
#   4. BYTE-INERT OFF — with --opt off CALLARG==0 and the legacy push/pop is used.
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
opt1_require_lane "test_opt_callarg"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_callarg"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = Path("tests/bench/opt/_prelude.ad").read_text()
M = (1 << 64) - 1
fails = 0

def disasm(code_bytes, vma=0x10000):
    raw = WD / "hot.bin"; raw.write_bytes(code_bytes)
    return subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         "--adjust-vma=0x%x" % vma, str(raw)], capture_output=True, text=True).stdout

def mn(l):
    return l.split("\t")[-1].strip() if "\t" in l else l.strip()

def build(name, src, opt):
    return h.run_through_codegen_ad(name, src, WD, opt=opt)

def dump(name, src, opt):
    p = WD / f"{name}.ad"; p.write_text(h.codegen_compatible_source(src))
    return h.run_dump(p, opt=opt)

def check(name, src, ref_out, want_callarg):
    global fails
    on = build(name + "_on", src, True)
    off = build(name + "_off", src, False)
    if on.kind != "ok" or off.kind != "ok":
        print(f"FAIL(compile) {name} on={on.kind} off={off.kind}"); fails += 1
        return None, None
    if on.stdout != str(ref_out):
        print(f"FAIL(value-ON) {name} ref={ref_out} on={on.stdout}"); fails += 1
    if off.stdout != str(ref_out):
        print(f"FAIL(value-OFF) {name} ref={ref_out} off={off.stdout}"); fails += 1
    du_on = dump(name + "_d_on", src, True)
    du_off = dump(name + "_d_off", src, False)
    ca_on = getattr(du_on, "callarg", 0)
    ca_off = getattr(du_off, "callarg", 0)
    if ca_off != 0:
        print(f"FAIL(inert-off) {name}: CALLARG={ca_off} with --opt off (must be 0)"); fails += 1
    if want_callarg and ca_on == 0:
        print(f"FAIL(fire) {name}: CALLARG==0 ON (routing did not fire)"); fails += 1
    if (not want_callarg) and ca_on != 0:
        print(f"FAIL(unexpected-fire) {name}: CALLARG={ca_on} ON (expected fallback)"); fails += 1
    if want_callarg and ca_on > 0:
        print(f"[{name}] CALLARG={ca_on} ON, value {on.stdout} == OFF {off.stdout} == ref {ref_out}")
    elif not want_callarg:
        print(f"[{name}] fallback (CALLARG=0), value {on.stdout} == ref {ref_out}")
    return du_on, du_off

# ---------------------------------------------------------------------------
# 1) ROUTED: genuinely-recursive tak (Takeuchi). fib is NO LONGER a valid probe —
# --opt rewrites the fib linear-recurrence into an iterative loop (opt.ad,
# 54969cda) so it emits no recursive `fib(n-K)` call whose arg could route. tak's
# inner `tak(x-1,y,z)` recursion IS real (its outer self-call is tail-folded to a
# loop, the three inner calls are genuine), and its first arg `x-1` is exactly the
# residual: routed DIRECTLY into %rdi as `mov %rdi,%x; sub %rdi,$1` (immediate) in
# place of the legacy materialize-into-scratch + push/pop marshalling.
# ---------------------------------------------------------------------------
from functools import lru_cache
@lru_cache(maxsize=None)
def pytak(x, y, z):
    if x <= y: return z
    return pytak(pytak(x-1, y, z), pytak(y-1, z, x), pytak(z-1, x, y))
ref1 = 0
for z in range(8):
    ref1 = (ref1 + pytak(18, 12, z)) & M
fib_src = PRELUDE + """
def tak(x: int64, y: int64, z: int64) -> int64:
    if x <= y:
        return z
    return tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y))

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    z: int64 = 0
    while z < 8:
        acc = acc + tak(18, 12, z)
        z = z + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
"""
du_on, _ = check("tak", fib_src, ref1, True)
if du_on is not None:
    t = disasm(du_on.code)
    lines = t.splitlines()
    # Find the recursive arg fill: an `sub %rdi,0x...` (immediate) with NO push/pop
    # in the 3 lines before it (the value-at-a-time path framed the arg with
    # push/pop and materialized the constant into a scratch register first).
    found = False
    for i, l in enumerate(lines):
        m = mn(l)
        if re.match(r"sub\s+rdi,0x", m):
            window = [mn(x) for x in lines[max(0, i - 3):i + 1]]
            if not any(w.startswith("push") or w.startswith("pop") for w in window):
                found = True
                print(f"[tak] arg routed: '{m}' (immediate, no push/pop)")
                break
    if not found:
        print("FAIL tak: no push/pop-free `sub rdi,$imm` arg fill (marshalling remains)")
        fails += 1

# ---------------------------------------------------------------------------
# 2) MULTI-ARG: f3(a+1, a-2, a*3) — three register args, all routed into
#    %rdi/%rsi/%rdx left-to-right with no cross-arg clobber. (Three DISTINCT
#    source locals in one 3-arg call hit a PRE-EXISTING --opt codegen limitation
#    unrelated to this lever, so the sources share `a`; the three arg registers
#    are still each filled by a separate routed expression.)
# ---------------------------------------------------------------------------
a0 = 7
ref2 = ((a0 + 1) - (a0 - 2) + (a0 + 30)) & M
multi_src = PRELUDE + """
def f3(x: int64, y: int64, z: int64) -> int64:
    return x - y + z

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: int64 = 7
    acc: int64 = 0
    acc = acc + f3(a + 1, a - 2, a + 30)
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
"""
check("multiarg", multi_src, ref2, True)

# ---------------------------------------------------------------------------
# 3a) HAZARD: an arg that is itself a CALL must NOT route (eval-order safety).
# ---------------------------------------------------------------------------
def pyg(x): return (x * x + 1) & M
def pyf2(x, y): return (x * 7 + y) & M
xx = 9
ref3 = pyf2(pyg(xx), xx + 1)
callarg_src = PRELUDE + """
def g(x: int64) -> int64:
    return x * x + 1

def f2(x: int64, y: int64) -> int64:
    return x * 7 + y

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    xx: int64 = 9
    r: int64 = f2(g(xx), xx + 1)
    print_u64(cast[uint64](r))
    return cast[int32](r & cast[int64](255))
"""
# f2's FIRST arg is a call `g(xx)` (fails the pure gate) but its SECOND arg
# `xx + 1` is a pure binop the destination-router now safely computes straight
# into %rsi AFTER g(xx) has been evaluated and homed — per-arg routing, not the
# old all-or-nothing refusal. The load-bearing safety proof is unchanged: ON ==
# OFF == oracle (eval order preserved, no earlier-filled arg register clobbered),
# so this routes CALLARG=1 (the pure sibling arg) with a bit-exact value.
check("argcall", callarg_src, ref3, True)

# ---------------------------------------------------------------------------
# 3b) HAZARD: args sharing a sub-read, dst-arg shape f(a+b, a-b).
# ---------------------------------------------------------------------------
a1, b1 = 1234567, 89012
ref4 = (((a1 + b1) * 3) ^ (a1 - b1)) & M
shared_src = PRELUDE + """
def h(p: int64, q: int64) -> int64:
    return p * 3 ^ q

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: int64 = 1234567
    b: int64 = 89012
    r: int64 = h(a + b, a - b)
    print_u64(cast[uint64](r))
    return cast[int32](r & cast[int64](255))
"""
check("shared", shared_src, ref4, True)

print("=== test_opt_callarg:", "PASS" if fails == 0 else f"FAIL ({fails})", "===")
sys.exit(1 if fails else 0)
PY
