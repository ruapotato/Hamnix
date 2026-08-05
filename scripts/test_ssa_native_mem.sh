#!/usr/bin/env bash
# scripts/test_ssa_native_mem.sh — the NATIVE --opt lane must both EMIT and
# CORRECTLY emit the local-memory constructs (address-taken scalars and the
# pointer/array/string shapes they drag in with them).
#
# WHY THIS GATE EXISTS (2026-08-05):
#   `--opt` / ADDER_OPT2 compiles a function through SSA only if ssa_build_function
#   accepts it; anything else silently falls back to gen_function.  Falling back
#   is CORRECT but unoptimized, so a subset gap is invisible to every
#   correctness gate in the tree — the answers stay right and the optimizer just
#   never runs.  The whole-tree census (scripts/ssa_subset_census.py) measured
#   the largest single gap as bail site 66, "address-taken scalar local, native
#   path (no alloca lowering)", at 36.9% of all fallbacks.
#
#   That number was an UPPER BOUND, not a gain.  The per-site histogram records
#   only the FIRST gate each function trips, so closing site 66 alone moved the
#   accepted subset 36.65% -> 36.78% (+27 functions of 21281): the same functions
#   immediately re-bailed at `*p`, `p[i]`, a local array or a string literal.
#   Every one of those reduces to the SAME three opcodes the x86 emitter now
#   lowers (SVO_ALLOCA / SVO_LOAD / SVO_STORE, plus integer BINOP address
#   arithmetic and SVO_GLOBALADDR), so they are opened together, guarded by
#   se_op_lowerable — an emitter-side WHITELIST that falls a function back if a
#   single value carries an opcode ssa_emit_value cannot emit.
#
# WHAT IT PROVES (host-only, no QEMU), per fixture:
#   1. EMITTED: the function goes through the SSA lane (SSAEMIT_EMITTED >= 1 and
#      SSAEMIT_FALLBACK == 0).  RED on main, where every fixture falls back.
#   2. CORRECT: --opt and -O0 print the SAME answer.  A subset widening that
#      changed an answer would be a silent miscompile, which is the only way this
#      work can be worse than the bail it replaces.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import subprocess, sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

h.build_driver()
DRV = str(h.DRIVER_ELF)
WD = Path("build/ssa_native_mem"); WD.mkdir(parents=True, exist_ok=True)

def emit_stats(name, src):
    """SSAEMIT_* counters for `src` compiled with --opt."""
    p = WD / (name + ".ad")
    p.write_text(src)
    r = subprocess.run([DRV, "--opt", str(p)], capture_output=True, text=True,
                       timeout=300)
    st = {}
    for line in r.stdout.splitlines():
        f = line.split()
        if len(f) == 2 and f[0].startswith("SSAEMIT_"):
            st[f[0]] = int(f[1])
    if "AC_DUMP_END" not in r.stdout:
        raise SystemExit(f"FAIL {name}: driver produced no dump\n"
                         f"{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    return st


PRELUDE = """
extern def sys_write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64

_ch:   Array[1, uint8]
_digs: Array[32, uint8]


def _putc(c: uint8) -> int32:
    _ch[0] = c
    sys_write(cast[int32](1), &_ch[0], cast[uint64](1))
    return 0


def print_u64(val: uint64) -> int32:
    nd: int64 = 0
    v: uint64 = val
    if v == cast[uint64](0):
        _digs[0] = cast[uint8](48)
        nd = 1
    while v > cast[uint64](0):
        q: uint64 = v / cast[uint64](10)
        d: uint64 = v - q * cast[uint64](10)
        _digs[cast[int64](nd)] = cast[uint8](d + cast[uint64](48))
        nd = nd + 1
        v = q
    k: int64 = nd - 1
    while k >= 0:
        _putc(_digs[cast[int64](k)])
        k = k - 1
    _putc(cast[uint8](10))
    return 0
"""

fails = []

def check(name, body, want, min_emitted):
    src = PRELUDE + body
    # --- 1. correctness: --opt must agree with -O0 -------------------------
    off = h.run_through_codegen_ad(name + "_off", src, WD, opt=False)
    on = h.run_through_codegen_ad(name + "_on", src, WD, opt=True)
    if off.kind != "ok" or on.kind != "ok" or off.stdout != on.stdout \
            or off.stdout != str(want):
        fails.append(f"{name}: MISCOMPILE off={off.kind}:{off.stdout} "
                     f"on={on.kind}:{on.stdout} (want {want})")
        return
    # --- 2. subset: the SSA lane must EMIT it, not fall back ---------------
    st = emit_stats(name, src)
    if st.get("SSAEMIT_EMITTED", 0) < min_emitted \
            or st.get("SSAEMIT_FALLBACK", 1) != 0:
        fails.append(f"{name}: SSA lane emitted {st.get('SSAEMIT_EMITTED')} of "
                     f"{st.get('SSAEMIT_FUNCS')} functions, wanted >= "
                     f"{min_emitted}: {st}")
        return
    print(f"  ok {name}: answer={off.stdout} {st.get('SSAEMIT_EMITTED')} emitted, "
          f"{st.get('SSAEMIT_FALLBACK')} fallback")


# 1. THE TARGET: an address-taken scalar local.  `&n` forces n into a frame
#    slot (SVO_ALLOCA); the callee writes through the pointer, so the slot must
#    live INSIDE the frame `sub $N, %rsp` reserves — below %rsp it would be
#    scratch the callee is free to clobber.
check("addr_taken_scalar", """
def bump(p: Ptr[uint64]):
    p[0] = p[0] + 7


def main(argc: int32, argv: Ptr[uint64]) -> int32:
    n: uint64 = 35
    bump(&n)
    print_u64(n)
    return 0
""", 42, 4)

# 2. An address-taken PARAMETER: the incoming argument register is spilled to
#    the param's slot in the entry block, and every read loads it back.
check("addr_taken_param", """
def twiddle(p: Ptr[uint64]):
    p[0] = p[0] * 3


def f(a: uint64) -> uint64:
    twiddle(&a)
    return a + 1


def main(argc: int32, argv: Ptr[uint64]) -> int32:
    print_u64(f(11))
    return 0
""", 34, 5)

# 3. NARROW address-taken scalars: the slot is sized to the declaration and
#    every store truncates / every load re-extends at that width.  A slot sized
#    from the wrong declaration is the zlib-inflate corruption shape.
check("addr_taken_narrow", """
def setb(p: Ptr[uint8]):
    p[0] = cast[uint8](200)


def main(argc: int32, argv: Ptr[uint64]) -> int32:
    b: uint8 = 1
    w: uint32 = 70000
    setb(&b)
    print_u64(cast[uint64](b) + cast[uint64](w))
    return 0
""", 70200, 4)

# 4. Pointer deref + pointer indexing (`*p`, `p[i]`, `p[i] = e`) — the shapes
#    an address-taken local drags in, all base+idx*scale over a LOAD/STORE.
check("ptr_deref_index", """
def sum3(p: Ptr[uint64]) -> uint64:
    t: uint64 = p[0] + p[1]
    t = t + p[2]
    p[0] = t
    return *p


def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: Array[3, uint64]
    a[0] = 1
    a[1] = 20
    a[2] = 300
    print_u64(sum3(&a[0]))
    return 0
""", 321, 4)

# 5. A local ARRAY: one flat frame slot, indexed with base+i*esz.
check("local_array", """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: Array[8, uint32]
    i: uint32 = 0
    while i < 8:
        a[i] = i * i
        i = i + 1
    t: uint32 = 0
    i = 0
    while i < 8:
        t = t + a[i]
        i = i + 1
    print_u64(cast[uint64](t))
    return 0
""", 140, 3)

# 6. A string literal: interned into the SAME gdata blob legacy codegen uses,
#    reached by a RIP-relative lea (SVO_GLOBALADDR).
check("string_literal", """
def blen(s: Ptr[uint8]) -> uint64:
    n: uint64 = 0
    while s[n] != 0:
        n = n + 1
    return n


def main(argc: int32, argv: Ptr[uint64]) -> int32:
    print_u64(blen("hamnix"))
    return 0
""", 6, 4)

if fails:
    print("FAIL test_ssa_native_mem:")
    for x in fails:
        print("  " + x)
    sys.exit(1)
print("PASS test_ssa_native_mem")
PY
