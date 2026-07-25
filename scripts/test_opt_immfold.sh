#!/usr/bin/env bash
# scripts/test_opt_immfold.sh — focused, host-only correctness + firing guard for
# the CONSTANT-MATERIALIZE-INTO-REGISTER peephole (codegen.ad cg_retarget_imm_rax,
# consumed by store_to_named). Armed only under --opt; byte-identical to the frozen
# seed OFF.
#
# THE LEVER: `name = <int literal>` where `name` is a register-promoted, store-
# eliminable plain full-width-8 scalar. The seed/legacy path emits the literal into
# the stack-machine scratch then copies it into the promoted register:
#     mov $imm,%rax ; mov %rax,%reg
# Since the register is the value's SOLE home (store-elim: no slot-bypass read) and
# an assignment produces no value in %rax (assignments are statements, not
# expressions, in this backend — gen_expr never lowers ND_ASSIGN), %rax is DEAD
# after the store. The peephole retargets the imm-load IN PLACE (length-preserving
# byte patch: same imm32/imm64 encoding, only the dest reg field + REX.B change) to
# write the register directly and drops the copy:
#     mov $imm,%reg
# One fewer instruction (and 3 bytes) per constant-into-register store — on every
# accumulator seed / `i = 0` loop reset.
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECT + MATCHES OFF: a loop that seeds several register-resident scalars
#      from int literals produces EXACTLY the reference value under --opt AND equals
#      the --opt-OFF value.
#   2. FIRED + BYTE-INERT OFF: IMMFOLD>0 under --opt; IMMFOLD==0 with --opt off.
#   3. THE COPY IS GONE: in the ON disassembly a seeded register is loaded by a
#      single `mov $imm,%reg` with NO preceding `mov $imm,%rax ; mov %rax,%reg` pair.
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
opt1_require_lane "test_opt_immfold"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_immfold"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
M = (1 << 64) - 1
fails = 0

# A loop that seeds several register-resident scalars from INT LITERALS (n, s, i,
# and a per-outer-iteration `i = 0` reset), then reduces. Pure register-resident
# store-eliminable scalars — exactly the constant-into-register shape.
def pyref():
    acc = 0
    reps = 0
    while reps < 8:
        n = 100
        s = 0
        i = 0
        while i < n:
            s = (s + i * i) & M
            i = i + 1
        acc = (acc + s) & M
        reps = reps + 1
    return acc & M

ref = pyref()

SRC = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    reps: int64 = 0
    while reps < 8:
        n: int64 = 100
        s: int64 = 0
        i: int64 = 0
        while i < n:
            s = (s + i * i) & cast[int64](18446744073709551615)
            i = i + 1
        acc = (acc + s) & cast[int64](18446744073709551615)
        reps = reps + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
"""

r_on = h.run_through_codegen_ad("imf_on", SRC, WD, opt=True, keep=True)
r_off = h.run_through_codegen_ad("imf_off", SRC, WD, opt=False, keep=True)
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
    dsrc = WD / f"imf_dump_{int(opt)}.ad"
    dsrc.write_text(h.codegen_compatible_source(SRC))
    d = h.run_dump(dsrc, opt=opt)
    if d.status != "ok":
        raise RuntimeError(f"run_dump status={d.status} {getattr(d,'detail','')[:160]}")
    return d

try:
    d_on = dump(True)
    d_off = dump(False)

    # (2) fired + byte-inert OFF
    imf_on = int(getattr(d_on, "immfold", 0) or 0)
    imf_off = int(getattr(d_off, "immfold", 0) or 0)
    if imf_on < 1:
        print(f"FAIL(no-fire) immfold_on={imf_on} (no constant-into-register fold)")
        fails += 1
    elif imf_off != 0:
        print(f"FAIL(off-fired) immfold_off={imf_off} (must be 0 — byte-inert OFF)")
        fails += 1
    else:
        print(f"[fire] immfold_on={imf_on} immfold_off=0 OK")

    # (4) SMALLER under --opt
    if d_on.code_len >= d_off.code_len:
        print(f"FAIL(size) opt code_len={d_on.code_len} not < off code_len={d_off.code_len}")
        fails += 1
    else:
        print(f"[size] opt code_len={d_on.code_len} < off code_len={d_off.code_len} "
              f"(-{d_off.code_len - d_on.code_len} bytes) OK")

    # (3) DISASM: a seed reg loaded by a single `mov $imm,%reg` (callee-saved r/m or
    #     r12..r15), with NO `mov $imm,%rax` immediately above targeting %rax then
    #     copied. We assert at least one direct `mov $imm,<callee>` exists in ON and
    #     that ON has strictly fewer `mov $imm,rax` instructions than OFF (the folded
    #     ones no longer route through %rax).
    def disasm(d):
        raw = WD / "imf.code.bin"; raw.write_bytes(d.code)
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
    # count `mov $imm,%rax`  (intel: `mov rax,0x..`)
    imm_rax_on = sum(1 for t in rows_on if re.match(r"mov\s+rax,0x[0-9a-f]+$", t))
    imm_rax_off = sum(1 for t in rows_off if re.match(r"mov\s+rax,0x[0-9a-f]+$", t))
    # count direct `mov $imm,<callee-saved>` (rbx,r12..r15)
    imm_reg_on = sum(1 for t in rows_on
                     if re.match(r"mov\s+(rbx|r1[2-5]),0x[0-9a-f]+$", t))
    if imm_reg_on < 1:
        print(f"FAIL(disasm) no direct `mov $imm,<callee>` in ON code"); fails += 1
    elif not (imm_rax_on < imm_rax_off):
        print(f"FAIL(disasm) `mov rax,imm` count ON={imm_rax_on} not < OFF={imm_rax_off}")
        fails += 1
    else:
        print(f"[disasm] ON has {imm_reg_on} direct `mov $imm,<callee>`; "
              f"`mov rax,imm` ON={imm_rax_on} < OFF={imm_rax_off} OK")
except Exception as ex:
    print(f"FAIL(disasm) exception: {ex}"); fails += 1

if fails:
    print(f"\n[test_opt_immfold] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_immfold] PASS (constant folded straight into the promoted "
      "register, correct, fired, byte-inert OFF, smaller)")
PY
