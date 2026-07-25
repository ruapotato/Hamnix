#!/usr/bin/env bash
# scripts/test_opt_alelide.sh — focused, host-only correctness + firing guard for
# the VARIADIC AL-ZEROING ELISION lever (codegen.ad, --opt). Armed only under
# --opt; byte-inert OFF.
#
# THE LEVER: codegen emits `xorl %eax,%eax` before every `call` to satisfy the
# SysV AMD64 requirement that AL hold the number of vector registers used — a
# value a callee reads ONLY when it is VARIADIC. An Adder `def` has a FIXED,
# fully-typed parameter list and is never variadic, so a DIRECT call to an in-unit
# PROGRAM FUNCTION (is_program_function) ignores AL entirely and the zeroing is a
# dead uop. This lever drops it (gcc likewise omits it for a direct non-variadic
# call), removing one whole front-end uop per call on the hottest call-bound
# kernel (fib: 2 per invocation). EXTERN callees (possibly variadic C, e.g.
# printf) and INDIRECT calls (unknown prototype) keep the xor.
#
# WHAT IT PROVES (no QEMU):
#   1. FIRES + VALUE-EXACT — recursive fib and a six-arg + call-crossing suite
#      elide the xor (ALELIDE>0) and stay bit-exact to the reference AND to the
#      --opt-OFF value (the elision is value-neutral by construction: a
#      non-variadic callee never reads AL).
#   2. MACHINE-CODE — the ON image has EXACTLY ALELIDE fewer `xor eax,eax`-before-
#      `call` sequences than the OFF image (each elision drops one, and one only).
#   3. INDIRECT NOT ELIDED — a call through a function-POINTER value keeps its xor
#      (its prototype is unknown), so ALELIDE counts only the direct in-unit sites.
#   4. BYTE-INERT OFF — ALELIDE==0 with --opt off on every shape.
#   5. GATE IS LOAD-BEARING — arming the deliberate break (--alelide-break) makes
#      the elision fire on the --opt-OFF build too (ALELIDE_off>0), which the
#      byte-inertness assertion CATCHES — proving the cg_ra_active gate is what
#      keeps the default image byte-identical to the frozen seed.
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
opt1_require_lane "test_opt_alelide"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_alelide"); WD.mkdir(parents=True, exist_ok=True)
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

def xor_before_call(txt):
    """Count `xor eax,eax` immediately followed by a `call` in the disasm."""
    lines = [mn(l) for l in txt.splitlines() if "\t" in l]
    c = 0
    for i in range(len(lines) - 1):
        if re.match(r"xor\s+eax,eax$", lines[i]) and lines[i + 1].startswith("call"):
            c += 1
    return c

def build(name, src, opt):
    return h.run_through_codegen_ad(name, src, WD, opt=opt)

def dump(name, src, opt, brk=False):
    p = WD / f"{name}.ad"; p.write_text(h.codegen_compatible_source(src))
    return h.run_dump(p, opt=opt, alelide_break=brk)

def check(name, src, ref_out, want_fire, check_mc=False):
    global fails
    on = build(name + "_on", src, True)
    off = build(name + "_off", src, False)
    if on.kind != "ok" or off.kind != "ok":
        print(f"FAIL(compile) {name} on={on.kind} off={off.kind} "
              f"detail={getattr(on,'detail',None) or getattr(off,'detail',None)}")
        fails += 1
        return
    if on.stdout != str(ref_out):
        print(f"FAIL(value-ON) {name} ref={ref_out} on={on.stdout}"); fails += 1
    if off.stdout != str(ref_out):
        print(f"FAIL(value-OFF) {name} ref={ref_out} off={off.stdout}"); fails += 1
    du_on = dump(name + "_d_on", src, True)
    du_off = dump(name + "_d_off", src, False)
    al_on = getattr(du_on, "alelide", 0)
    al_off = getattr(du_off, "alelide", 0)
    if al_off != 0:
        print(f"FAIL(inert-off) {name}: ALELIDE={al_off} with --opt off (must be 0)"); fails += 1
    if want_fire and al_on == 0:
        print(f"FAIL(fire) {name}: ALELIDE=0 ON (lever did not fire)"); fails += 1
    if (not want_fire) and al_on != 0:
        print(f"FAIL(over-fire) {name}: ALELIDE={al_on} ON (elided a shape it must not)"); fails += 1
    if check_mc and want_fire and al_on > 0:
        on_txt = disasm(du_on.code); off_txt = disasm(du_off.code)
        xc_on = xor_before_call(on_txt); xc_off = xor_before_call(off_txt)
        if xc_off - xc_on != al_on:
            print(f"FAIL(machine-code) {name}: OFF xor-before-call={xc_off} "
                  f"ON={xc_on} delta={xc_off-xc_on} != ALELIDE={al_on}"); fails += 1
        else:
            print(f"[{name}] machine-code: OFF {xc_off} xor-before-call, "
                  f"ON {xc_on} (dropped {al_on})")
    tag = f"ALELIDE={al_on}" if want_fire else f"no-fire ALELIDE={al_on}"
    print(f"[{name}] {tag} ON, value {on.stdout} == OFF {off.stdout} == ref {ref_out}")

# ---------------------------------------------------------------------------
# 1) FIRES: a genuinely-recursive, call-heavy kernel. fib is NO LONGER usable for
#    the machine-code delta: --opt now folds the fib linear-recurrence into an
#    iterative loop (opt.ad, 54969cda) — so the ON build has FEWER `call` sites
#    than OFF and the xor-before-call delta no longer equals ALELIDE. This probe
#    `rec(n-1)+rec(n-2)+n` keeps two DIRECT self-calls that are neither the exact
#    fib shape (the trailing `+ n` defeats the linear-recurrence matcher) nor in
#    tail position (so a96ab53c's tail->loop does not fire either): ON and OFF
#    have the SAME call set and differ only by the elided xor. Both call sites are
#    direct in-unit -> both xor's elided.
# ---------------------------------------------------------------------------
def pyrec(n):
    return n if n < 2 else pyrec(n - 1) + pyrec(n - 2) + n
ref1 = 0
for n in range(24):
    ref1 = (ref1 + pyrec(n)) & M
fib_src = PRELUDE + """
def rec(n: int64) -> int64:
    if n < 2:
        return n
    return rec(n - 1) + rec(n - 2) + n

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    n: int64 = 0
    while n < 24:
        acc = acc + rec(n)
        n = n + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
"""
check("rec", fib_src, ref1, True, check_mc=True)

# ---------------------------------------------------------------------------
# 2) MULTI-ARG + CALL-CROSSING: six-int64-param sum (all arg regs) and a
#    call-crossing intermediate. Every call is direct in-unit -> elided, value
#    exact (guards that eliding the xor never disturbs arg marshalling).
# ---------------------------------------------------------------------------
def i64(v): return v - (1 << 64) if (v & M) >> 63 else (v & M)
va = [11, -22, 33, -44, 55, -66]
def a64(v): return f"cast[int64](0 - {(-v)})" if v < 0 else f"cast[int64]({v})"
s6 = i64(sum(va))
a, b = 7, -19
chain = i64((a) + (b))
ref2 = (s6 + chain) & M
multi_src = PRELUDE + f"""
def al_sum6(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64) -> int64:
    return a + b + c + d + e + f

def al_id(x: int64) -> int64:
    return x

def al_chain(a: int64, b: int64) -> int64:
    t: int64 = al_id(a)
    return t + b

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: int64 = 0
    s = s + al_sum6({a64(va[0])}, {a64(va[1])}, {a64(va[2])}, {a64(va[3])}, {a64(va[4])}, {a64(va[5])})
    s = s + al_chain({a64(a)}, {a64(b)})
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
check("multi", multi_src, ref2 & M, True)

# ---------------------------------------------------------------------------
# 3) INDIRECT NOT ELIDED: a call through a function-POINTER value keeps its xor
#    (unknown prototype). ALELIDE must count only the direct print_u64 sites, not
#    the indirect one -> assert value-exact and that ALELIDE does NOT over-count
#    (structurally: the indirect call still carries its xor in the ON image).
# ---------------------------------------------------------------------------
ind_src = PRELUDE + """
def dbl(x: int64) -> int64:
    return x + x

def apply(fn: Fn[int64, int64], v: int64) -> int64:
    return fn(v)

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    r: int64 = apply(dbl, cast[int64](21))
    print_u64(cast[uint64](r))
    return cast[int32](r & cast[int64](255))
"""
on = build("ind_on", ind_src, True)
off = build("ind_off", ind_src, False)
if on.kind != "ok" or off.kind != "ok":
    print(f"FAIL(compile) ind on={on.kind} off={off.kind} "
          f"detail={getattr(on,'detail',None) or getattr(off,'detail',None)}"); fails += 1
elif on.stdout != "42" or off.stdout != "42":
    print(f"FAIL(value) ind on={on.stdout} off={off.stdout} ref=42"); fails += 1
else:
    du_on = dump("ind_d_on", ind_src, True)
    on_txt = disasm(du_on.code)
    # The indirect `call *r11` must still be preceded by its xor eax,eax (kept).
    lines = [mn(l) for l in on_txt.splitlines() if "\t" in l]
    kept = any(re.match(r"xor\s+eax,eax$", lines[i]) and lines[i+1].startswith("call")
               and "r11" in lines[i+1] for i in range(len(lines)-1))
    if not kept:
        print("FAIL(ind) indirect call lost its xor eax,eax (elided an unknown prototype)"); fails += 1
    else:
        print(f"[ind] indirect call keeps xor eax,eax (ALELIDE={getattr(du_on,'alelide',0)}), value 42")

# ---------------------------------------------------------------------------
# 4) DELIBERATE BREAK: arming --alelide-break makes the elision fire on the
#    --opt-OFF build too (ALELIDE_off>0) -> breaks the self-hosting byte-inertness
#    invariant. The guard must CATCH it (the gate is load-bearing).
# ---------------------------------------------------------------------------
du_off_brk = dump("fib_brk", fib_src, False, brk=True)
al_off_brk = getattr(du_off_brk, "alelide", 0)
if al_off_brk == 0:
    print("FAIL(break) --alelide-break did NOT defeat the --opt gate "
          "(ALELIDE_off still 0) — the deliberate break is inert, gate not proven"); fails += 1
else:
    print(f"[break] --alelide-break defeats the --opt gate on OFF "
          f"(ALELIDE_off={al_off_brk}>0) — caught; the cg_ra_active gate is load-bearing")

print("=== test_opt_alelide:", "PASS" if fails == 0 else f"FAIL ({fails})", "===")
sys.exit(1 if fails else 0)
PY
