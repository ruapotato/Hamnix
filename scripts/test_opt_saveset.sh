#!/usr/bin/env bash
# scripts/test_opt_saveset.sh — host-only correctness + TIGHTNESS guard for the
# native optimizer's callee-saved PROLOGUE SAVE-SET (regalloc promotion veto +
# IR-scratch reservation, --opt). Complements test_opt_methodsave.sh: that one
# locks the SAFETY direction (push-set ⊇ body callee-saved writes — never UNDER-
# push a live value); this one locks the TIGHTNESS direction (push-set == body
# callee-saved writes for the fib-shaped call/branch kernels — never park a DEAD
# callee-saved register the body never writes) AND the latent-miscompile these
# tightenings exposed.
#
# THE TWO DEAD-PUSH SOURCES THIS FIXES + GUARDS (fib's biggest prologue residual):
#   1. PHANTOM PROMOTION. cfg/liveness reason over name STRINGS and cannot tell a
#      materialisable local scalar from a name the backend never holds in a register
#      — a module GLOBAL (loaded RIP-relative), a DIRECT-CALL callee/function name
#      (`call <sym>`, never loaded), an array/pointer base, a sub-8-byte scalar.
#      Linear scan would park such a phantom in a callee-saved register that the
#      body NEVER writes; the dest-driven selector's later leaf read reads that
#      UNINITIALISED register — a MISCOMPILE that only appears once register
#      pressure is low enough for the phantom to win a register. The veto
#      (codegen cg_veto_nonlocal_names: promote only param_is_plain_scalar names)
#      makes the promotion set == the materialisation set. fib pushed %r12 for the
#      callee name `fib`, run on EVERY recursive call.
#   2. IR-SCRATCH OVER-RESERVATION. The scratch prescan reserved a callee-saved reg
#      for every scratch-eligible binop, INCLUDING an if/while CONDITION compare
#      (emitted branch-only via cmp+jcc, no scratch) and a DIRECT-call register
#      argument (routed scratch-free into its ABI register). fib pushed %r13 for
#      such a scratch it never used. The prescan now mirrors cmpjcc_node_ok /
#      the CALLARG routing exactly, so it reserves only what the body acquires.
#
# WHAT IT PROVES (no QEMU):
#   A. VALUE CORRECTNESS — every program == --opt-OFF (byte-identical seed) == the
#      python oracle. The GLOBAL-IN-ARITH case is the phantom-promotion miscompile
#      repro: a module global summed into a register-pressured expression lands the
#      WRONG value if promoted to an unwritten register.
#   B. SAFETY (⊇) — every emitted function's callee-saved push-set is a SUPERSET of
#      the callee-saved registers its body WRITES (a dropped needed push = a
#      caller-register clobber). A deliberate under-push regression trips this.
#   C. TIGHTNESS (==) — the RECURSIVE fib-shaped function (detected by its self
#      call) pushes EXACTLY the callee-saved registers its body writes, and in
#      particular pushes NO %r12/%r13/%r14/%r15 (only %rbx for `n`). A regression of
#      either dead-push source re-introduces a spurious push and trips this.
#   D. GENUINE NEED — a register-pressured function that really writes several
#      callee-saved registers STILL pushes them all (the veto/tightening does not
#      strip a genuinely-needed save).
#
# HOST-ONLY: python3 + as/ld + objdump, x86_64. NO QEMU.
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
opt1_require_lane "test_opt_saveset"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_saveset"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = Path("tests/bench/opt/_prelude.ad").read_text()
U64 = (1 << 64) - 1
def u64(x): return x & U64
fails = 0
CALLEE = {"rbx", "r12", "r13", "r14", "r15"}

def disasm_functions(elf_path):
    """Split the code segment at each endbr64; return [{start, insns:[(addr,txt)]}]."""
    rl = subprocess.run(["readelf", "-l", str(elf_path)], capture_output=True, text=True).stdout
    filesz = None
    for ln in rl.splitlines():
        m = re.search(r"LOAD\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x([0-9a-f]+)\s+0x[0-9a-f]+\s+R E", ln)
        if m:
            filesz = int(m.group(1), 16); break
    raw = elf_path.read_bytes()[:filesz] if filesz else elf_path.read_bytes()
    binf = elf_path.with_suffix(".code.bin"); binf.write_bytes(raw)
    dis = subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         "--adjust-vma=0x10000", str(binf)], capture_output=True, text=True).stdout
    funcs = []; cur = None
    for ln in dis.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(.*)", ln)
        if not m:
            continue
        addr = int(m.group(1), 16); txt = m.group(2).strip()
        if "endbr64" in txt:
            cur = {"start": addr, "insns": []}; funcs.append(cur)
        if cur is not None:
            cur["insns"].append((addr, txt))
    return funcs

def push_and_writes(f):
    """Return (pushed_callee_set, written_callee_set) for one function."""
    pushed, writes = set(), set()
    in_prologue = True
    for addr, txt in f["insns"]:
        pm = re.match(r"push\s+(\w+)$", txt)
        if in_prologue and pm and pm.group(1) in CALLEE:
            pushed.add(pm.group(1)); continue
        if re.match(r"mov\s+rbp,rsp$", txt):
            in_prologue = False; continue
        wm = re.match(r"(?:mov|add|sub|imul|and|or|xor|lea|sar|shl|shr|neg|not|inc|dec)\s+(\w+)\b", txt)
        if (not in_prologue) and wm and wm.group(1) in CALLEE:
            writes.add(wm.group(1))
        pp = re.match(r"pop\s+(\w+)$", txt)
        if (not in_prologue) and pp and pp.group(1) in CALLEE:
            writes.add(pp.group(1))
    return pushed, writes

def self_recursive(f):
    """True iff the function contains a `call 0x<its own start>` (recursion).
    Parses the call target as an int and compares EXACTLY (a substring test would
    false-match 0x102c1 inside 0x102c10)."""
    for _, txt in f["insns"]:
        m = re.match(r"call\s+0x([0-9a-f]+)\b", txt)
        if m and int(m.group(1), 16) == f["start"]:
            return True
    return False

def run(name, src):
    on = h.run_through_codegen_ad(name + "_on", src, WD, opt=True, keep=True)
    off = h.run_through_codegen_ad(name + "_off", src, WD, opt=False)
    return on, off

# ---------------------------------------------------------------------------
# CASE 1 — genuinely-recursive tak (Takeuchi). fib is NO LONGER a valid recursive
# probe: --opt now rewrites the fib linear-recurrence shape into an iterative
# loop (opt.ad, 54969cda) so fib emits NO self-call and this tightness assertion
# would false-match main/_start. tak stays irreducibly tree-recursive: its OUTER
# self-call is tail-folded to a loop (a96ab53c) but its THREE inner
# tak(x-1,y,z)/tak(y-1,z,x)/tak(z-1,x,y) calls are real recursion (arguments to
# the outer call, NOT in tail position). tak holds x,y,z across those calls in
# the three callee-saved registers rbx/r12/r13, so the TIGHT expectation is a
# push-set of EXACTLY {rbx,r12,r13} — its callee-saved writes, no dead scratch or
# callee-name push (the phantom-promotion / over-reservation residual this guards).
# ---------------------------------------------------------------------------
from functools import lru_cache
@lru_cache(maxsize=None)
def pytak(x, y, z):
    if x <= y: return z
    return pytak(pytak(x-1, y, z), pytak(y-1, z, x), pytak(z-1, x, y))
FIB = PRELUDE + """
def tak(x: int64, y: int64, z: int64) -> int64:
    if x <= y:
        return z
    return tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y))
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = cast[int64](0)
    z: int64 = cast[int64](0)
    while z < cast[int64](8):
        acc = acc + tak(cast[int64](18), cast[int64](12), z)
        z = z + cast[int64](1)
    print_u64(cast[uint64](acc))
    return cast[int32](0)
"""
fibref = 0
for z in range(8): fibref = u64(fibref + pytak(18, 12, z))
TIGHT_PUSHSET = {"rbx", "r12", "r13"}

# ---------------------------------------------------------------------------
# CASE 2 — GLOBAL summed into a register-pressured expression (phantom-promotion
# miscompile repro). The global g must be read from MEMORY, not a promoted
# register; a wrong (0/garbage) contribution lands a wrong value.
# ---------------------------------------------------------------------------
GLOB = PRELUDE + """
g: int64
def bump(x: int64) -> int64:
    g = g + x
    return x
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: int64 = bump(cast[int64](3))
    b: int64 = bump(cast[int64](5))
    c: int64 = bump(cast[int64](7))
    tot: int64 = a + b + c + g + g
    print_u64(cast[uint64](tot))
    return cast[int32](0)
"""
# semantics: g accumulates 3,8,15; tot = 3+5+7 + 15 + 15 = 45
globref = u64(3 + 5 + 7 + 15 + 15)

# ---------------------------------------------------------------------------
# CASE 3 — register-pressured NON-recursive function that genuinely writes several
# callee-saved registers across an internal call (they MUST still be pushed).
# ---------------------------------------------------------------------------
PRESS = PRELUDE + """
def ext(x: int64) -> int64:
    return x + cast[int64](1)
def work(a: int64, b: int64, c: int64) -> int64:
    p: int64 = a + b
    q: int64 = b + c
    r: int64 = a * c
    s: int64 = ext(a)
    t: int64 = p + q + r + s
    return t + p + q + r
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = cast[int64](0)
    k: int64 = cast[int64](0)
    while k < cast[int64](12):
        acc = acc + work(k, k + cast[int64](1), k + cast[int64](2))
        k = k + cast[int64](1)
    print_u64(cast[uint64](acc))
    return cast[int32](0)
"""
def pywork(a,b,c):
    p=a+b; q=b+c; r=a*c; s=a+1; t=p+q+r+s
    return u64(t+p+q+r)
pressref = 0
for k in range(12): pressref = u64(pressref + pywork(k,k+1,k+2))

CASES = [("tak", FIB, fibref, "tight"),
         ("glob", GLOB, globref, "value"),
         ("press", PRESS, pressref, "press")]

for name, src, ref, mode in CASES:
    on, off = run(name, src)
    if on.kind != "ok" or off.kind != "ok":
        print(f"[{name}] FAIL(compile) on={on.kind} off={off.kind} "
              f"detail={on.detail or off.detail}"); fails += 1; continue
    go = u64(int(on.stdout.strip() or "0")); gf = u64(int(off.stdout.strip() or "0"))
    ok = (go == ref and gf == ref)
    if not ok:
        print(f"[{name}] FAIL(value ref={ref} on={go} off={gf})"); fails += 1
    funcs = disasm_functions(WD / f"ad_{name}_on.elf")
    # B. SAFETY: every function push-set ⊇ writes.
    for f in funcs:
        pushed, writes = push_and_writes(f)
        missing = writes - pushed
        if missing:
            print(f"[{name}] FAIL(under-push) fn@0x{f['start']:x} writes {sorted(writes)} "
                  f"pushes {sorted(pushed)} MISSING {sorted(missing)}"); fails += 1
    if mode == "tight":
        # C. TIGHTNESS. Every recursive function must push NO DEAD callee-saved reg
        # (pushed ⊆ writes), and tak specifically must be de-bloated to EXACTLY
        # {rbx,r12,r13} (its only callee-saved writes, holding x/y/z across the
        # inner recursion) — no phantom-promotion push (a callee-name reg) and no
        # dead scratch reservation (%r14/%r15 for a branch-compare / recursion-arg).
        # NOTE: the disassembler lumps the trailing `_start` stub (which does
        # `call main`) into `main`, so `main` can also look self-recursive; the
        # dead-push check still holds for it (its callee-saved regs hold acc/z,
        # genuinely written).
        rec = [f for f in funcs if self_recursive(f)]
        if not rec:
            print(f"[{name}] FAIL(no recursive fn found)"); fails += 1
        for f in rec:
            pushed, writes = push_and_writes(f)
            dead = pushed - writes
            if dead:
                print(f"[{name}] FAIL(dead-push) recursive fn@0x{f['start']:x} pushes "
                      f"{sorted(pushed)} but body writes only {sorted(writes)} "
                      f"— DEAD {sorted(dead)}"); fails += 1
        tak_fns = [f for f in rec if push_and_writes(f)[0] == TIGHT_PUSHSET]
        if not tak_fns:
            got = {f["start"]: sorted(push_and_writes(f)[0]) for f in rec}
            print(f"[{name}] FAIL(tak-not-tight) no recursive fn pushes exactly "
                  f"{sorted(TIGHT_PUSHSET)} — got {got} (a dead callee-saved push "
                  f"regressed)"); fails += 1
        else:
            print(f"[{name}] TIGHT OK — recursive tak pushes exactly "
                  f"{sorted(TIGHT_PUSHSET)} (no dead callee-saved), value={go}")
    elif mode == "press":
        # D. GENUINE NEED: the pressured `work` (has a self-less internal call and
        # writes multiple callee-saved regs) must actually push them.
        pressured = [f for f in funcs if len(push_and_writes(f)[1]) >= 2]
        if not pressured:
            print(f"[{name}] FAIL(no pressured fn writes >=2 callee-saved)"); fails += 1
        else:
            print(f"[{name}] GENUINE-NEED OK — pressured fn pushes "
                  f"{sorted(push_and_writes(pressured[0])[0])} (writes "
                  f"{sorted(push_and_writes(pressured[0])[1])}), value={go}")
    else:
        print(f"[{name}] VALUE OK (global read from memory, not a phantom register) value={go}")

print("=" * 60)
if fails == 0:
    print("[opt_saveset] PASS — save-set is tight (no dead callee-saved push on the "
          "recursive tak kernel) AND safe (push-set ⊇ body writes) AND the global-"
          "promotion miscompile is closed")
    sys.exit(0)
else:
    print(f"[opt_saveset] FAIL — {fails} problem(s)")
    sys.exit(1)
PY
