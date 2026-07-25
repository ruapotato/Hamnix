#!/usr/bin/env bash
# scripts/test_opt_immalu.sh — focused, host-only correctness + firing guard for
# the ALU-BY-IMMEDIATE peephole (codegen.ad gen_expr_ir scratch path, counter
# opt_immalu_count / manifest IMMALU). Armed only under --opt; byte-identical to
# the frozen seed OFF.
#
# THE LEVER: a two-operand integer binop `x OP C` where OP has a one-operand
# immediate form (ADD/SUB/AND/OR/XOR) and C is a non-negative imm32 constant. The
# legacy IR scratch-register fast path materialises C into a callee-saved scratch
# register and does a reg-reg combine:
#     mov $C,%rax ; mov %rax,%scratch ; <eval x> ; op %scratch,%rax
# The fold evaluates the non-constant operand into %rax and applies the constant in
# place, dropping BOTH the materialise-into-rax and the scratch copy:
#     <eval x> ; op $C,%rax
# Two fewer instructions and one fewer live scratch register per constant-operand
# binop that would otherwise take the scratch path (e.g. `acc & 255`, `v + 48`,
# `n - 1` in the reduction spine). COMMUTATIVE ops fold C on either side; SUB folds
# only C on the RIGHT (`x - C`).
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECT + MATCHES OFF: a loop mixing `& mask`, `+ C`, `- C`, `| C`, `^ C`
#      against register-resident scalars produces EXACTLY the reference value under
#      --opt AND equals the --opt-OFF value.
#   2. FIRED + BYTE-INERT OFF: IMMALU>0 under --opt; IMMALU==0 with --opt off.
#   3. THE SCRATCH COPY IS GONE: in the ON disassembly at least one `op $imm,%rax`
#      (and/or/xor/add/sub with an immediate into rax) exists, and ON has strictly
#      fewer `mov $imm,%rax` instructions than OFF (the folded constants no longer
#      route through %rax + a scratch).
#   4. SMALLER: the ON code for the fixture is strictly shorter than OFF.
#
# HOST-ONLY: python3 + as/ld/gcc + objdump (x86_64). NO QEMU. The cached dump driver
# under build/fuzz_ad_codegen AUTO-INVALIDATES on any compiler change.
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
opt1_require_lane "test_opt_immalu"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_immalu"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
M = (1 << 64) - 1
fails = 0

# A loop mixing every immediate-form op against register-resident store-eliminable
# scalars: AND mask, ADD/SUB constants, OR/XOR constants. Pure integer arithmetic
# with constant right operands — exactly the ALU-by-immediate shape.
def pyref():
    acc = 0
    reps = 0
    while reps < 16:
        s = 0
        i = 0
        while i < 200:
            t = (i + 7) & M
            t = (t - 3) & M
            t = (t & 1023) & M
            t = (t | 4) & M
            t = (t ^ 21) & M
            s = (s + t) & M
            i = i + 1
        acc = (acc + (s & 65535)) & M
        reps = reps + 1
    return acc & M

ref = pyref()

SRC = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    reps: int64 = 0
    while reps < 16:
        s: int64 = 0
        i: int64 = 0
        while i < 200:
            t: int64 = (i + 7) & cast[int64](18446744073709551615)
            t = (t - 3) & cast[int64](18446744073709551615)
            t = (t & 1023) & cast[int64](18446744073709551615)
            t = (t | 4) & cast[int64](18446744073709551615)
            t = (t ^ 21) & cast[int64](18446744073709551615)
            s = (s + t) & cast[int64](18446744073709551615)
            i = i + 1
        acc = (acc + (s & 65535)) & cast[int64](18446744073709551615)
        reps = reps + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
"""

r_on = h.run_through_codegen_ad("ima_on", SRC, WD, opt=True, keep=True)
r_off = h.run_through_codegen_ad("ima_off", SRC, WD, opt=False, keep=True)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) on={r_on.kind}/off={r_off.kind} "
          f"{(r_on.detail or r_off.detail)[:160]}")
    sys.exit(1)

# (1) correctness ON==OFF==ref
if r_on.stdout != str(ref) or r_off.stdout != str(ref):
    print(f"FAIL(value) ref={ref} on={r_on.stdout} off={r_off.stdout}"); fails += 1
else:
    print(f"[value] on==off==ref ({ref}) OK")

# (2/3/4) dump ON + OFF for firing count, byte-inertness, disasm and size.
def dump(opt):
    dsrc = WD / f"ima_dump_{int(opt)}.ad"
    dsrc.write_text(h.codegen_compatible_source(SRC))
    d = h.run_dump(dsrc, opt=opt)
    if d.status != "ok":
        raise RuntimeError(f"run_dump status={d.status} {getattr(d,'detail','')[:160]}")
    return d

try:
    d_on = dump(True)
    d_off = dump(False)

    # (2) fired + byte-inert OFF
    ima_on = int(getattr(d_on, "immalu", 0) or 0)
    ima_off = int(getattr(d_off, "immalu", 0) or 0)
    if ima_on < 1:
        print(f"FAIL(no-fire) immalu_on={ima_on} (no ALU-by-immediate fold)")
        fails += 1
    elif ima_off != 0:
        print(f"FAIL(off-fired) immalu_off={ima_off} (must be 0 — byte-inert OFF)")
        fails += 1
    else:
        print(f"[fire] immalu_on={ima_on} immalu_off=0 OK")

    # (4) SMALLER under --opt
    if d_on.code_len >= d_off.code_len:
        print(f"FAIL(size) opt code_len={d_on.code_len} not < off code_len={d_off.code_len}")
        fails += 1
    else:
        print(f"[size] opt code_len={d_on.code_len} < off code_len={d_off.code_len} "
              f"(-{d_off.code_len - d_on.code_len} bytes) OK")

    # (3) DISASM: an `op $imm,%rax` (and/or/xor/add/sub rax,0x..) exists in ON, and
    #     ON has strictly fewer `mov $imm,%rax` than OFF (the folded constants no
    #     longer route through %rax + a scratch copy).
    def disasm(d):
        raw = WD / "ima.code.bin"; raw.write_bytes(d.code)
        txt = subprocess.run(
            ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
             str(raw)], capture_output=True, text=True).stdout
        rows = []
        for ln in txt.splitlines():
            mm = re.match(r"\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(.*)$", ln)
            if mm:
                rows.append(mm.group(2).strip())
        return rows

    rows_on = disasm(d_on)
    rows_off = disasm(d_off)
    imm_rax_on = sum(1 for t in rows_on if re.match(r"mov\s+rax,0x[0-9a-f]+$", t))
    imm_rax_off = sum(1 for t in rows_off if re.match(r"mov\s+rax,0x[0-9a-f]+$", t))
    imm_alu_on = sum(1 for t in rows_on
                     if re.match(r"(and|or|xor|add|sub)\s+rax,0x[0-9a-f]+$", t))
    if imm_alu_on < 1:
        print(f"FAIL(disasm) no `op $imm,%rax` in ON code"); fails += 1
    elif not (imm_rax_on < imm_rax_off):
        print(f"FAIL(disasm) `mov rax,imm` count ON={imm_rax_on} not < OFF={imm_rax_off}")
        fails += 1
    else:
        print(f"[disasm] ON has {imm_alu_on} `op $imm,%rax`; "
              f"`mov rax,imm` ON={imm_rax_on} < OFF={imm_rax_off} OK")
except Exception as ex:
    print(f"FAIL(disasm) exception: {ex}"); fails += 1

if fails:
    print(f"\n[test_opt_immalu] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_immalu] PASS (constant operand folded into an immediate ALU op, "
      "correct, fired, byte-inert OFF, smaller)")
PY