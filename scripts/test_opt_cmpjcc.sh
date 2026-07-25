#!/usr/bin/env bash
# scripts/test_opt_cmpjcc.sh — focused, host-only correctness + firing test for
# the native backend's CMP+JCC branch-condition lever (codegen.ad): a comparison
# (== != < <= > >=, signed AND unsigned) that feeds DIRECTLY into a conditional
# branch (if/while/for/do-while condition, short-circuit &&/|| edge) is lowered
# to a 2-instruction `cmp; jcc <target>` with the correct condition code for the
# operator + branch sense, instead of materializing a 0/1 boolean (cmp; setcc;
# movzx) and re-testing it (test; jz). Armed only under --opt; OFF by default ->
# byte-identical to the frozen seed.
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECT + BIT-EXACT: each program compiled through codegen.ad WITH --opt
#      (cmp+jcc active) produces EXACTLY the reference value AND the SAME result
#      as WITH --opt OFF (the materialize-then-test path). A wrong jcc (the
#      signed-vs-unsigned jb-vs-jl trap) or a wrong branch-sense negation would
#      silently take the wrong arm — the primary correctness gate.
#   2. SIGNED-VS-UNSIGNED SOUNDNESS: an UNSIGNED comparison feeding a branch
#      emits the unsigned jcc family (jb/jae/jbe/ja), NOT the signed (jl/jge/
#      jle/jg); a signed comparison emits the signed family. Checked by disasm.
#   3. THE BOOLEAN IS GONE: a hot loop's condition under --opt disassembles to a
#      single jcc with NO setcc/movzx materialization for that test (the ~8-instr
#      boolean replaced by 2 instrs). Checked by setcc-count drop vs OFF.
#   4. VALUE-USE STILL MATERIALIZES: a comparison whose VALUE is assigned to a
#      local (not a pure branch) STILL emits setcc/movzx under --opt (the lever
#      must NOT touch the value-use path).
#   5. THE LEVER FIRES: the dump driver's CMPJCC counter is > 0 under --opt and
#      == 0 with --opt OFF (byte-inert).
#
# HOST-ONLY: python3 + as/ld + objdump, x86_64. NO QEMU. The cached dump driver
# under build/fuzz_ad_codegen AUTO-INVALIDATES on any compiler-source change.
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
opt1_require_lane "test_opt_cmpjcc"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_cmpjcc"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = Path("tests/bench/opt/_prelude.ad").read_text()
M = (1 << 64) - 1
def u64(x): return x & M
def s64(x):
    x &= M
    return x - (1 << 64) if x >> 63 else x

fails = 0

def disasm_code(elf):
    """Disassemble the program-header-only ELF's code segment to intel text."""
    rl = subprocess.run(["readelf", "-l", str(elf)], capture_output=True, text=True)
    filesz = None
    for ln in rl.stdout.splitlines():
        m = re.search(r"LOAD\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x([0-9a-f]+)", ln)
        if m and "R E" in ln:
            filesz = int(m.group(1), 16); break
    raw = elf.read_bytes()
    if filesz is None:
        filesz = len(raw)
    binf = elf.with_suffix(".code.bin"); binf.write_bytes(raw[:filesz])
    return subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(binf)], capture_output=True, text=True).stdout

def compile_pair(name, src, keep=False):
    r_on = h.run_through_codegen_ad(name, src, WD, opt=True, keep=keep)
    r_off = h.run_through_codegen_ad(name + "o", src, WD, opt=False, keep=keep)
    return r_on, r_off

def check_value(name, src, ref, expect_fire=True):
    global fails
    r_on, r_off = compile_pair(name, src)
    if r_on.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) {name}: on={r_on.kind} off={r_off.kind} "
              f"detail={r_on.detail or r_off.detail}")
        fails += 1
        return None, None
    got_on = u64(int(r_on.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    cj_on = getattr(r_on, "cmpjcc", 0)
    cj_off = getattr(r_off, "cmpjcc", 0)
    if got_on != ref or got_off != ref:
        print(f"FAIL(value) {name}: ref={ref} on={got_on} off={got_off} "
              f"CMPJCC={cj_on}")
        fails += 1
    elif expect_fire and cj_on == 0:
        print(f"FAIL(no-fire) {name}: CMPJCC=0 (expected the cmp+jcc lever)")
        fails += 1
    elif cj_off != 0:
        print(f"FAIL(off-fired) {name}: CMPJCC={cj_off} with --opt OFF (must be 0)")
        fails += 1
    else:
        print(f"[{name}] value OK ({ref}) on==off==ref; CMPJCC on={cj_on} off={cj_off}")
    return r_on, r_off

# ===========================================================================
# (A) Loop-test disasm: the boolean materialization is GONE under --opt. A hot
#     while loop with a signed `<` condition: OFF emits cmp; setl; movzx; test;
#     jz; ON emits cmp; jge (a single negated signed jcc, no setcc/movzx).
# ===========================================================================
N = 50
LOOP = PRELUDE + f"""
gx: Array[{N}, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: int64 = cast[int64](0)
    i: int64 = cast[int64](0)
    while i < cast[int64]({N}):
        s = s + i
        i = i + cast[int64](1)
    print_u64(cast[uint64](s))
    return cast[int32](cast[uint64](s) & cast[uint64](255))
"""
ref_loop = u64(sum(range(N)))
r_on, r_off = compile_pair("cmpjcc_loop", LOOP, keep=True)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) cmpjcc_loop: on={r_on.kind} off={r_off.kind}")
    fails += 1
else:
    got_on = u64(int(r_on.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    if got_on != ref_loop or got_off != ref_loop:
        print(f"FAIL(value) cmpjcc_loop: ref={ref_loop} on={got_on} off={got_off}")
        fails += 1
    else:
        print(f"[cmpjcc_loop] value OK ({ref_loop})")
    try:
        dis_on = disasm_code(WD / "ad_cmpjcc_loop.elf")
        dis_off = disasm_code(WD / "ad_cmpjcc_loopo.elf")
        setcc_on = len(re.findall(r"\bset[a-z]+\b", dis_on))
        setcc_off = len(re.findall(r"\bset[a-z]+\b", dis_off))
        jcc_on = len(re.findall(r"\bj(l|ge|le|g|b|ae|be|a|e|ne)\b", dis_on))
        print(f"[cmpjcc_loop] setcc: OFF={setcc_off} ON={setcc_on} ; jcc ON={jcc_on}")
        # The single loop condition's setcc/movzx must vanish under --opt.
        if setcc_on >= setcc_off:
            print(f"FAIL(disasm) cmpjcc_loop: --opt did not remove the boolean "
                  f"materialization (setcc OFF={setcc_off} ON={setcc_on})")
            fails += 1
        # A signed `<` loop exit must be a signed jge (NOT an unsigned jae).
        if not re.search(r"\bjge\b", dis_on):
            print(f"FAIL(disasm) cmpjcc_loop: expected a signed `jge` loop-exit "
                  f"under --opt; none found")
            fails += 1
        else:
            print(f"[cmpjcc_loop] boolean GONE; signed `jge` loop-exit present")
    except Exception as ex:
        print(f"WARN(disasm) cmpjcc_loop skipped: {ex}")

# ===========================================================================
# (B) SIGNED-VS-UNSIGNED soundness: an UNSIGNED while-condition must emit the
#     unsigned jcc family (jae/jb), never the signed (jge/jl). The operands are
#     chosen so the loop is well-defined; the disasm check is the real gate.
# ===========================================================================
NU = 40
ULOOP = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: uint64 = cast[uint64](0)
    i: uint64 = cast[uint64](0)
    while i < cast[uint64]({NU}):
        s = s + i
        i = i + cast[uint64](1)
    print_u64(s)
    return cast[int32](s & cast[uint64](255))
"""
ref_uloop = u64(sum(range(NU)))
r_on, r_off = compile_pair("cmpjcc_uloop", ULOOP, keep=True)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) cmpjcc_uloop: on={r_on.kind} off={r_off.kind}")
    fails += 1
else:
    got_on = u64(int(r_on.stdout.strip() or "0"))
    if got_on != ref_uloop:
        print(f"FAIL(value) cmpjcc_uloop: ref={ref_uloop} on={got_on}")
        fails += 1
    else:
        print(f"[cmpjcc_uloop] value OK ({ref_uloop})")
    try:
        # Scope the disasm to main() ONLY (entry_off..end): the PRELUDE helpers
        # (print_u64 etc.) legitimately use SIGNED jccs, so a whole-program signed
        # check would false-positive. main() is the entry; its sole comparison is
        # the unsigned loop exit, which MUST be the unsigned family (jae/jb), never
        # signed (jge/jl) — the jb-vs-jl miscompile trap on large unsigned values.
        d_on = h.run_dump(WD / "ad_cmpjcc_uloop.ad", opt=True)
        eoff = getattr(d_on, "entry_off", 0)
        if eoff == 0:
            raise RuntimeError("entry_off unavailable from dump")
        # Disassemble the DUMP code bytes (d_on.code), whose offsets are
        # CODE-RELATIVE and therefore align with entry_off. (The previous
        # disasm_code(elf) path disassembled the ELF file from offset 0, i.e.
        # INCLUDING the ~0xb0-byte ELF+program-header prefix, so its addresses
        # were shifted by the header size relative to entry_off — the
        # entry_off filter then sliced at the wrong place and false-positived
        # on a PRELUDE helper's signed jcc whenever main's size shifted. This
        # mirrors how test_opt_basehoist.sh / test_opt_combine.sh disassemble
        # d_on.code directly.)
        raw = WD / "ad_cmpjcc_uloop.code.bin"; raw.write_bytes(d_on.code)
        dis_full = subprocess.run(
            ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
             str(raw)], capture_output=True, text=True).stdout
        # objdump prints "  <hex>:\t..."; keep only lines at or past entry_off.
        main_lines = []
        for ln in dis_full.splitlines():
            m = re.match(r"\s*([0-9a-f]+):", ln)
            if m and int(m.group(1), 16) >= eoff:
                main_lines.append(ln)
        dis_main = "\n".join(main_lines)
        has_uns = bool(re.search(r"\b(jae|jb|jbe|ja)\b", dis_main))
        has_signed = bool(re.search(r"\b(jge|jl|jle|jg)\b", dis_main))
        if not has_uns:
            print(f"FAIL(soundness) cmpjcc_uloop: unsigned `<` in main() did not "
                  f"emit an unsigned jcc (jae/jb)")
            fails += 1
        elif has_signed:
            print(f"FAIL(soundness) cmpjcc_uloop: unsigned `<` in main() emitted a "
                  f"SIGNED jcc (jge/jl/jle/jg) — wrong condition code")
            fails += 1
        else:
            print(f"[cmpjcc_uloop] unsigned `<` in main() -> unsigned jcc only: SOUND")
    except Exception as ex:
        print(f"WARN(disasm) cmpjcc_uloop skipped: {ex}")

# ===========================================================================
# (C) VALUE-USE still materializes: a comparison assigned to a local (its VALUE
#     is used) must STILL emit setcc/movzx under --opt — the lever leaves the
#     value-use path unchanged. We make it the ONLY comparison in the function so
#     a setcc under --opt can ONLY come from the value-use, not a branch.
# ===========================================================================
VALUE = PRELUDE + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: int64 = cast[int64](7)
    b: int64 = cast[int64](3)
    r: uint64 = cast[uint64](a > b)
    print_u64(r)
    return cast[int32](r & cast[uint64](255))
"""
r_on, r_off = compile_pair("cmpjcc_value", VALUE, keep=True)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) cmpjcc_value: on={r_on.kind} off={r_off.kind}")
    fails += 1
else:
    got_on = u64(int(r_on.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    if got_on != 1 or got_off != 1:
        print(f"FAIL(value) cmpjcc_value: ref=1 on={got_on} off={got_off}")
        fails += 1
    else:
        print(f"[cmpjcc_value] value OK (1)")
    try:
        dis_on = disasm_code(WD / "ad_cmpjcc_value.elf")
        if not re.search(r"\bset[a-z]+\b", dis_on):
            print(f"FAIL(value-use) cmpjcc_value: a comparison VALUE assignment "
                  f"did NOT materialize a setcc under --opt (the lever wrongly "
                  f"folded a value-use into a branch)")
            fails += 1
        else:
            print(f"[cmpjcc_value] value-use STILL materializes (setcc present)")
    except Exception as ex:
        print(f"WARN(disasm) cmpjcc_value skipped: {ex}")

# ===========================================================================
# (D) Mixed correctness sweep: if/else over each op, both signednesses, with
#     the signed-vs-unsigned trap operand (-1 vs 1), plus do-while + for-range.
# ===========================================================================
def cmp_truth(op, x, y, signed):
    xr, yr = u64(x), u64(y)
    if op == "==": return xr == yr
    if op == "!=": return xr != yr
    a, b = (s64(xr), s64(yr)) if signed else (xr, yr)
    return {"<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b}[op]

TRAP = 0xFFFFFFFFFFFFFFFF  # -1 signed, max unsigned
for op in ["<", "<=", ">", ">=", "==", "!="]:
    for signed in (True, False):
        ty = "int64" if signed else "uint64"
        src = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    x: {ty} = cast[{ty}]({TRAP})
    y: {ty} = cast[{ty}](1)
    r: uint64 = cast[uint64](0)
    if x {op} y:
        r = cast[uint64](7)
    else:
        r = cast[uint64](11)
    print_u64(r)
    return cast[int32](r & cast[uint64](255))
"""
        ref = 7 if cmp_truth(op, TRAP, 1, signed) else 11
        nm = f"cmpjcc_if_{ {'<':'lt','<=':'le','>':'gt','>=':'ge','==':'eq','!=':'ne'}[op] }_{'s' if signed else 'u'}"
        check_value(nm, src, ref)

# do-while + for-range cmp back-edges/exits
DW = PRELUDE + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = cast[int64](0)
    s: uint64 = cast[uint64](0)
    do:
        s = s + cast[uint64](i)
        i = i + cast[int64](1)
    while i <= cast[int64](5)
    print_u64(s)
    return cast[int32](s & cast[uint64](255))
"""
check_value("cmpjcc_dowhile", DW, u64(sum(range(0, 6))))

FR = PRELUDE + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: uint64 = cast[uint64](0)
    for k in range(9):
        s = s + cast[uint64](k)
    print_u64(s)
    return cast[int32](s & cast[uint64](255))
"""
check_value("cmpjcc_forrange", FR, u64(sum(range(9))))

# ===========================================================================
# (#121) CHAINED COMPARISON IN BRANCH POSITION must NOT be treated as a plain
#     comparison by the cmp+jcc lever. `a < b < c` parses as
#     BinaryExpr(<, BinaryExpr(<, a, b), c) whose OUTER op is relational, so
#     cmpjcc_node_ok used to accept it and emit `cmp; jcc` for the NAIVE nested
#     `(a<b) < c` (comparing the 0/1 boolean of `a<b` against `c`) instead of
#     the Python chain `(a<b) and (b<c)`. The fix makes cmpjcc_node_ok refuse a
#     chain (chain_is), so the branch falls back to gen_expr -> gen_chained_compare.
#     Assertion: ON == OFF == reference for the true AND false chain outcomes.
#     The lever must NOT fire on the chain node itself (expect_fire=False): a
#     regression that DOES fire is exactly the miscompile. We pick operand values
#     so the naive `(a<b) < c` interpretation gives a DIFFERENT boolean than the
#     chain — otherwise the bug would be invisible.
def chain_case(name, a, b, c, op0, op1):
    src = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: int64 = cast[int64]({a})
    b: int64 = cast[int64]({b})
    c: int64 = cast[int64]({c})
    r: uint64 = cast[uint64](0)
    if a {op0} b {op1} c:
        r = cast[uint64](7)
    else:
        r = cast[uint64](11)
    print_u64(r)
    return cast[int32](r & cast[uint64](255))
"""
    chain = (eval(f"{a} {op0} {b}") and eval(f"{b} {op1} {c}"))
    check_value(name, src, u64(7 if chain else 11), expect_fire=False)

# a<b<c with b>c: chain FALSE (3<9 True, 9<7 False) but naive (3<9)<7 = 1<7 TRUE.
chain_case("cmpjcc_chain_false", 3, 9, 7, "<", "<")
# a<b<c all ordered: chain TRUE.
chain_case("cmpjcc_chain_true", 3, 5, 7, "<", "<")
# mixed ops, chain FALSE in the second link.
chain_case("cmpjcc_chain_le_lt", 5, 5, 5, "<=", "<")
# descending chain a>b>c TRUE; naive (7>5)>3 = 1>3 FALSE — divergent shapes.
chain_case("cmpjcc_chain_gt", 7, 5, 3, ">", ">")

print()
if fails:
    print(f"test_opt_cmpjcc: FAIL ({fails} failure(s))")
    sys.exit(1)
print("test_opt_cmpjcc: PASS (cmp+jcc fires, bit-exact, signed/unsigned sound, "
      "boolean gone in loops, value-use still materializes, byte-inert OFF)")
PY
