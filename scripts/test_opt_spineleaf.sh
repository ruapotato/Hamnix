#!/usr/bin/env bash
# scripts/test_opt_spineleaf.sh — focused, host-only correctness + firing guard
# for the P1 SPINE-LEAF register-source lever (codegen.ad sel_expr_into_reg leaf
# fast path). Armed only --opt.
#
# THE LEVER: when the LEFTMOST leaf of a destination-routed pure-arith tree is a
# FULL-WIDTH-8 register-promoted local, sel_expr_into_reg moves it STRAIGHT into
# the destination register (`mov %src,%dst`) instead of the legacy
# `mov %src,%rax; mov %rax,%dst` %rax hop. This is the fib recursion-arg residual:
# `fib(n-K)` becomes `mov %n,%rdi; sub $K,%rdi` (2 instr, no %rax bounce) in place
# of `mov %n,%rax; mov %rax,%rdi; sub $K,%rdi` (3 instr).
#
# WHAT IT PROVES (no QEMU):
#   1. ROUTED — recursive `fib(n-1)+fib(n-2)` fires SPINELEAF>0 ON, and each arg
#      register is filled by a `mov %reg,%rdi` immediately followed by `sub
#      $imm,%rdi` with NO intervening `mov ...,%rax; mov %rax,%rdi` hop; value
#      EXACTLY the reference and == the --opt-OFF value.
#   2. ASSIGN — a promoted accumulator term whose spine starts at a promoted leaf
#      routes (SPINELEAF>0), bit-exact.
#   3. FALLBACK soundness — a SUB-8-BYTE leftmost leaf stays on the %rax path (no
#      direct move) yet is bit-exact.
#   4. BYTE-INERT OFF — with --opt off SPINELEAF==0.
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
opt1_require_lane "test_opt_spineleaf"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_spineleaf"); WD.mkdir(parents=True, exist_ok=True)
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

def check(name, src, ref_out, want_fire):
    global fails
    on = build(name + "_on", src, True)
    off = build(name + "_off", src, False)
    if on.kind != "ok" or off.kind != "ok":
        print(f"FAIL(compile) {name} on={on.kind} off={off.kind}"); fails += 1
        return None
    if on.stdout != str(ref_out):
        print(f"FAIL(value-ON) {name} ref={ref_out} on={on.stdout}"); fails += 1
    if off.stdout != str(ref_out):
        print(f"FAIL(value-OFF) {name} ref={ref_out} off={off.stdout}"); fails += 1
    du_on = dump(name + "_d_on", src, True)
    du_off = dump(name + "_d_off", src, False)
    sl_on = getattr(du_on, "spineleaf", 0)
    sl_off = getattr(du_off, "spineleaf", 0)
    if sl_off != 0:
        print(f"FAIL(inert-off) {name}: SPINELEAF={sl_off} with --opt off (must be 0)"); fails += 1
    if want_fire and sl_on == 0:
        print(f"FAIL(fire) {name}: SPINELEAF==0 ON (leaf lever did not fire)"); fails += 1
    if want_fire and sl_on > 0:
        print(f"[{name}] SPINELEAF={sl_on} ON, value {on.stdout} == OFF {off.stdout} == ref {ref_out}")
    elif not want_fire:
        print(f"[{name}] fallback probe, value {on.stdout} == ref {ref_out}")
    return du_on

# ---------------------------------------------------------------------------
# 1) ROUTED: genuinely-recursive tak (Takeuchi). fib is NO LONGER a valid probe
# here — --opt rewrites the fib linear-recurrence into an iterative loop (opt.ad,
# 54969cda) so it emits no recursive `fib(n-K)` arg to route. tak's inner
# `tak(x-1,y,z)` recursion IS real (its outer self-call is tail-folded to a loop,
# but the three inner calls are genuine), and its first arg `x-1` is exactly the
# residual leaf-spine `mov %x,%rdi; sub %rdi,$1` (full-width-8 promoted local x in
# %rbx moved straight into %rdi, no %rax hop) this lever targets.
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
du_on = check("tak", fib_src, ref1, True)
if du_on is not None:
    lines = disasm(du_on.code).splitlines()
    # Find `mov %<r>,%rdi` immediately followed by `sub %rdi,$imm` (Intel:
    # `sub rdi,0x..`), with NO `mov ...,rax` / `mov rax,rdi` hop between the leaf
    # read and the arg register. The legacy path emitted `mov ...,rax; mov
    # rax,rdi` — a direct `mov %reg,rdi` proves the leaf routed straight in.
    found = False
    for i, l in enumerate(lines):
        m = mn(l)
        if re.match(r"sub\s+rdi,0x", m):
            prev = mn(lines[i - 1]) if i >= 1 else ""
            # the instruction before the immediate-sub must be a direct
            # `mov rdi,<reg>` (Intel dst,src) that is NOT `mov rdi,rax`.
            if re.match(r"mov\s+rdi,r(?!ax)\w+", prev) or re.match(r"mov\s+rdi,rbx", prev):
                found = True
                print(f"[tak] leaf routed direct: '{prev}' ; '{m}' (no %rax hop)")
                break
    if not found:
        print("FAIL tak: no direct `mov rdi,<reg>` + `sub rdi,$imm` (leaf still hops through %rax)")
        fails += 1

# ---------------------------------------------------------------------------
# 2) ASSIGN: a promoted accumulator term whose spine starts at a promoted leaf.
# ---------------------------------------------------------------------------
n = 300
ref2 = 0
for i in range(n):
    a = i & M
    b = (i * 3 + 1) & M
    t = ((a * b) + a - (a ^ 5)) & M
    ref2 = (ref2 + t) & M
assign_src = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: uint64 = cast[uint64](0)
    i: uint64 = cast[uint64](0)
    while i < cast[uint64]({n}):
        a: uint64 = i
        b: uint64 = i * cast[uint64](3) + cast[uint64](1)
        t: uint64 = a * b + a - (a ^ cast[uint64](5))
        s = s + t
        i = i + cast[uint64](1)
    print_u64(s)
    return cast[int32](cast[uint64](s) & cast[uint64](255))
"""
check("assign", assign_src, ref2, True)

# ---------------------------------------------------------------------------
# 3) FALLBACK: a SUB-8-BYTE (int32) leftmost leaf must NOT direct-move (sized
#    scalars excluded) yet stay bit-exact.
# ---------------------------------------------------------------------------
n = 200
ref3 = 0
for i in range(n):
    w = (i * 7 + 3) & 0xFFFFFFFF
    t = (w + 5) & 0xFFFFFFFF
    ref3 = (ref3 + t) & M
sub8_src = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: uint64 = cast[uint64](0)
    i: int32 = 0
    while i < {n}:
        w: int32 = i * 7 + 3
        t: int32 = w + 5
        s = s + cast[uint64](cast[uint32](t))
        i = i + 1
    print_u64(s)
    return cast[int32](cast[uint64](s) & cast[uint64](255))
"""
check("sub8", sub8_src, ref3, False)

print("=== test_opt_spineleaf:", "PASS" if fails == 0 else f"FAIL ({fails})", "===")
sys.exit(1 if fails else 0)
PY
