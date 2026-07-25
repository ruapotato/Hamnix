#!/usr/bin/env bash
# scripts/test_opt_paramhome.sh — focused, host-only correctness + firing guard
# for the DEAD PARAM-HOME SPILL ELISION lever (codegen.ad, --opt). Armed only
# under --opt; byte-inert OFF.
#
# THE LEVER: a register-promoted, STORE-ELIMINABLE (lr_is_store_elim: address
# never taken, NO slot-bypass read), plain full-width-8 scalar PARAMETER passed
# in a SysV integer arg register is spilled to its home slot at entry then
# immediately reloaded into its promoted register (`mov %argreg,slot` + `mov
# slot,%reg`). Because store_elim proves the slot has no other reader, the init
# reload is the ONLY slot read; replacing it with a direct `mov %argreg,%reg`
# makes the entry spill store fully DEAD and drops it — two memory ops collapse
# to one reg-reg move. RESTRICTED to promotion into a CALLEE-SAVED register
# (%rbx/%r12..%r15), which is never a SysV arg register, so the direct move can
# never clobber another param's still-live incoming arg register.
#
# WHAT IT PROVES (no QEMU):
#   1. ROUTED — recursive fib(n) fires PARAMHOME>0 ON; the fib prologue now moves
#      `mov rbx,rdi` DIRECTLY with NO `mov QWORD PTR [rbp-x],rdi` dead spill,
#      while --opt OFF keeps the spill+reload. Value EXACTLY the reference and ==
#      the --opt-OFF value.
#   2. MULTI-PARAM — a six-int64-param sum (all arg registers) + a call-crossing
#      param + reassigned params all fire and stay bit-exact (guards move-order
#      safety and the callee-saved restriction on the caller-saved extension pool).
#   3. FALLBACK soundness — an ADDRESS-TAKEN param (clobberable, not promoted) and
#      a SUB-8-BYTE (int32) param (not a full-width scalar home) are NOT elided
#      (PARAMHOME==0) yet stay bit-exact — the dead spill is only dropped when
#      provably safe.
#   4. BYTE-INERT OFF — with --opt off PARAMHOME==0 on every shape.
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
opt1_require_lane "test_opt_paramhome"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_paramhome"); WD.mkdir(parents=True, exist_ok=True)
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

# The shared PRELUDE's print_u64(val: uint64) is itself an elidable param
# (val is promoted, store-eliminable), so EVERY program has this baseline
# elision count. Fire cases must exceed it; no-fire cases must equal it.
def prelude_baseline():
    src = PRELUDE + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    print_u64(cast[uint64](7))
    return cast[int32](0)
"""
    du = dump("baseline_d", src, True)
    return getattr(du, "paramhome", 0)

BASE_PH = prelude_baseline()
print(f"[baseline] PRELUDE PARAMHOME = {BASE_PH} (print_u64's val)")

def check(name, src, ref_out, want_fire):
    global fails
    on = build(name + "_on", src, True)
    off = build(name + "_off", src, False)
    if on.kind != "ok" or off.kind != "ok":
        print(f"FAIL(compile) {name} on={on.kind} off={off.kind} "
              f"detail={getattr(on,'detail',None) or getattr(off,'detail',None)}")
        fails += 1
        return None
    if on.stdout != str(ref_out):
        print(f"FAIL(value-ON) {name} ref={ref_out} on={on.stdout}"); fails += 1
    if off.stdout != str(ref_out):
        print(f"FAIL(value-OFF) {name} ref={ref_out} off={off.stdout}"); fails += 1
    du_on = dump(name + "_d_on", src, True)
    du_off = dump(name + "_d_off", src, False)
    ph_on = getattr(du_on, "paramhome", 0)
    ph_off = getattr(du_off, "paramhome", 0)
    if ph_off != 0:
        print(f"FAIL(inert-off) {name}: PARAMHOME={ph_off} with --opt off (must be 0)"); fails += 1
    if want_fire and ph_on <= BASE_PH:
        print(f"FAIL(fire) {name}: PARAMHOME={ph_on} <= baseline {BASE_PH} (lever did not fire on this fn)"); fails += 1
    if not want_fire and ph_on != BASE_PH:
        print(f"FAIL(over-fire) {name}: PARAMHOME={ph_on} != baseline {BASE_PH} (elided a shape it must not)"); fails += 1
    tag = f"PARAMHOME={ph_on}(>base {BASE_PH})" if want_fire else f"no-fire PARAMHOME={ph_on}(==base)"
    print(f"[{name}] {tag} ON, value {on.stdout} == OFF {off.stdout} == ref {ref_out}")
    return du_on, du_off

# ---------------------------------------------------------------------------
# 1) ROUTED: recursive fib summed over a range. `n` (int64 param) is promoted to
#    a callee-saved reg, store-eliminable -> the entry spill collapses to a
#    direct `mov rbx,rdi`.
# ---------------------------------------------------------------------------
def pyfib(n):
    return n if n < 2 else pyfib(n - 1) + pyfib(n - 2)
ref1 = 0
for n in range(22):
    ref1 = (ref1 + pyfib(n)) & M
fib_src = PRELUDE + """
def fib(n: int64) -> int64:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    n: int64 = 0
    while n < 22:
        acc = acc + fib(n)
        n = n + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
"""
res = check("fib", fib_src, ref1, True)
if res is not None:
    du_on, du_off = res
    on_txt = disasm(du_on.code)
    off_txt = disasm(du_off.code)
    # The only full-width int64 register param0 in this program is fib's `n`
    # (main's argc is int32 -> edi, argv -> rsi). So the ON code must contain a
    # direct `mov rbx,rdi` and NO `mov QWORD PTR [rbp-x],rdi` param spill, while
    # OFF must contain that spill.
    def has_direct_move(txt):
        return any(re.match(r"mov\s+rbx,rdi$", mn(l)) for l in txt.splitlines())
    def spill_count(txt):
        return sum(1 for l in txt.splitlines()
                   if re.match(r"mov\s+QWORD PTR \[rbp-0x[0-9a-f]+\],rdi$", mn(l)))
    if not has_direct_move(on_txt):
        print("FAIL fib: ON has no direct `mov rbx,rdi` (param not routed straight in)"); fails += 1
    if spill_count(on_txt) != 0:
        print(f"FAIL fib: ON still spills rdi to a slot ({spill_count(on_txt)}x) — dead store not dropped"); fails += 1
    if spill_count(off_txt) == 0:
        print("FAIL fib: OFF unexpectedly has no rdi param spill (baseline sanity)"); fails += 1
    if has_direct_move(on_txt) and spill_count(on_txt) == 0 and spill_count(off_txt) > 0:
        print("[fib] dead param-home spill dropped: ON `mov rbx,rdi` (0 rdi slot spills) vs OFF spill+reload")

# ---------------------------------------------------------------------------
# 2) MULTI-PARAM: six-int64-param sum (all arg regs), a call-crossing param, and
#    reassigned params. Value-exact under the elision; guards move-order safety.
# ---------------------------------------------------------------------------
va = [11, -22, 33, -44, 55, -66]
ref2 = 0
# ph_sum6(a..f) called; ph_chain(a,b)=a+b with b live across a call; ph_mut:
#   a=a+b; b=a*2; return a+b
def i64(v): return v - (1 << 64) if (v & M) >> 63 else (v & M)
s6 = i64(sum(va))
a, b = 7, -19
chain = i64(a + b)
aa = i64((a) + (b)); bb = i64(aa * 2); mut = i64(aa + bb)
ref2 = (s6 + chain + mut) & M
def a64(v): return f"cast[int64](0 - {(-v)})" if v < 0 else f"cast[int64]({v})"
multi_src = PRELUDE + f"""
def ph_sum6(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64) -> int64:
    return a + b + c + d + e + f

def ph_id(x: int64) -> int64:
    return x

def ph_chain(a: int64, b: int64) -> int64:
    t: int64 = ph_id(a)
    return t + b

def ph_mut(a: int64, b: int64) -> int64:
    a = a + b
    b = a * cast[int64](2)
    return a + b

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: int64 = 0
    s = s + ph_sum6({a64(va[0])}, {a64(va[1])}, {a64(va[2])}, {a64(va[3])}, {a64(va[4])}, {a64(va[5])})
    s = s + ph_chain({a64(a)}, {a64(b)})
    s = s + ph_mut({a64(a)}, {a64(b)})
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
check("multi", multi_src, ref2 & M, True)

# ---------------------------------------------------------------------------
# 3a) FALLBACK (dump-only): an ADDRESS-TAKEN param is clobberable -> NOT promoted
#     -> NOT store-eliminable, so it must NOT be elided (its home slot stays
#     authoritative for the `&x` alias). PARAMHOME must equal the prelude baseline
#     (ph_addr contributes NO elision). Asserted at the DUMP layer only: `&param`
#     under --opt hits a PRE-EXISTING (lever-independent) run limitation on this
#     backend, so we verify the static safety property (not-elided) without
#     executing.
# ---------------------------------------------------------------------------
addr_src = PRELUDE + """
def ph_addr(x: int64) -> int64:
    p: Ptr[int64] = &x
    p[0] = x * cast[int64](3)
    return p[0] + cast[int64](5)

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: int64 = 0
    k: int64 = 0
    while k < 40:
        s = s + ph_addr(k)
        k = k + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
du_addr = dump("addr_d", addr_src, True)
ph_addr_cnt = getattr(du_addr, "paramhome", 0)
if ph_addr_cnt != BASE_PH:
    print(f"FAIL(addr): PARAMHOME={ph_addr_cnt} != baseline {BASE_PH} "
          f"(address-taken param must NOT be elided)"); fails += 1
else:
    print(f"[addr] address-taken param NOT elided (PARAMHOME={ph_addr_cnt} == baseline)")

# ---------------------------------------------------------------------------
# 3b) FALLBACK: SUB-8-BYTE (int32) param is not a full-width scalar home -> not
#     elided. PARAMHOME==0, value-exact (sized spill path preserved).
# ---------------------------------------------------------------------------
ref4 = 0
for k in range(50):
    w = (k * 7 + 3) & 0xFFFFFFFF
    ref4 = (ref4 + ((w + 5) & 0xFFFFFFFF)) & M
sub8_src = PRELUDE + """
def ph_w(x: int32) -> int32:
    return x + 5

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: uint64 = cast[uint64](0)
    k: int32 = 0
    while k < 50:
        w: int32 = k * 7 + 3
        s = s + cast[uint64](cast[uint32](ph_w(w)))
        k = k + 1
    print_u64(s)
    return cast[int32](cast[uint64](s) & cast[uint64](255))
"""
check("sub8", sub8_src, ref4 & M, False)

print("=== test_opt_paramhome:", "PASS" if fails == 0 else f"FAIL ({fails})", "===")
sys.exit(1 if fails else 0)
PY
