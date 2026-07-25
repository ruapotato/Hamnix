#!/usr/bin/env bash
# scripts/test_opt_combine.sh — focused, host-only correctness + firing guard for
# the P1 SCRATCH-FREE 2-OPERAND COMBINE lever (codegen.ad sel_combine_into_home /
# emit_alu_imm_reg). This is the in-expression / statement-glue PLUMBING lever:
# the accumulator + IV-update combine `home = home OP value` is emitted as a
# single 2-operand x86 instruction — `op $imm,%home` for a constant step,
# `op %src,%home` for a register-resident value, else value->%rax then
# `op %rax,%home` — needing NO scratch register, so it stays tight even when the
# whole register pool is held by inner-loop induction variables (the matmul/saxpy
# register-pressure relief that previously forced a fall-back to the AST push/pop
# accumulate). Armed only --opt.
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECTNESS — imm-step boundary (imm8/imm32/>imm32 + add/sub/mul) and a
#      register-resident-ident accumulate under high pressure produce EXACTLY the
#      reference value, equal to the --opt-OFF value.
#   2. FIRING — the accumulator routing fires (ACCSEL>0).
#   3. PLUMBING REMOVED — the matmul-shape inner k-loop accumulate emits the
#      compact `add %rdi-ish,%rax`/`add $imm` IV forms with NO per-combine
#      push/pop: the hot k-loop body has ZERO `push`/`pop` (the seed/legacy path
#      round-trips every IV update + the accumulate through push/pop/%rax).
#   4. BYTE-INERT OFF — with --opt off ACCSEL==0.
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
opt1_require_lane "test_opt_combine"

python3 - <<'PY'
import sys, subprocess
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_combine"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
M = (1 << 64) - 1
fails = 0

def disasm(code_bytes):
    raw = WD / "hot.bin"; raw.write_bytes(code_bytes)
    return subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(raw)], capture_output=True, text=True).stdout

# ---------------------------------------------------------------------------
# 1+2+4) CORRECTNESS + FIRING + OFF-inert, reusing the wired p3store corpus
#        entries that target this lever.
# ---------------------------------------------------------------------------
progs = {n: (b, o, e, wf) for (n, b, o, e, wf) in F._p3store_corpus()}
for name in ["imm_step_boundary", "regident_pressure_acc"]:
    body, exp_out, exp_exit, wf = progs[name]
    r_on = h.run_through_codegen_ad(f"cmb_{name}", body, WD, opt=True)
    r_off = h.run_through_codegen_ad(f"cmb_{name}o", body, WD, opt=False)
    if r_on.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) {name} on={r_on.kind} off={r_off.kind}"); fails += 1; continue
    if r_on.stdout != exp_out or r_off.stdout != exp_out:
        print(f"FAIL {name} value ref={exp_out} on={r_on.stdout} off={r_off.stdout}"); fails += 1
    acc_on = int(getattr(r_on, "accsel", 0) or 0)
    if acc_on == 0:
        print(f"FAIL {name} ACCSEL never fired"); fails += 1
    src = WD / f"cmb_{name}.ad"; src.write_text(h.codegen_compatible_source(body))
    d_off = h.run_dump(src, opt=False)
    if d_off.status == "ok" and int(getattr(d_off, "accsel", 0) or 0) != 0:
        print(f"FAIL {name} NOT byte-inert OFF (ACCSEL={d_off.accsel})"); fails += 1
    if fails == 0 or r_on.stdout == exp_out:
        print(f"[{name}] value={r_on.stdout}=ref OK ACCSEL={acc_on} inert-OFF OK")

# ---------------------------------------------------------------------------
# 3) PLUMBING REMOVED — matmul-shape dot-product: the hot k-loop accumulate +
#    both IV updates must be push/pop-FREE. We isolate the innermost loop body
#    (the only basic block that contains `imul ...,QWORD PTR`) and assert it has
#    no `push`/`pop`.
# ---------------------------------------------------------------------------
N = 48
A = [(i * 7 + 3) & M for i in range(N * N)]
B = [(i * 5 + 11) & M for i in range(N * N)]
C = [0] * (N * N)
for i in range(N):
    for j in range(N):
        s = 0
        for k in range(N):
            s = (s + A[i * N + k] * B[k * N + j]) & M
        C[i * N + j] = s
ref = 0
for p in range(N * N):
    ref = (ref + C[p]) & M

mm = PRELUDE + f"""
A: Array[{N*N}, int64]
B: Array[{N*N}, int64]
C: Array[{N*N}, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    Nn: int64 = {N}
    k: int64 = 0
    while k < {N*N}:
        A[cast[int64](k)] = k * 7 + 3
        B[cast[int64](k)] = k * 5 + 11
        k = k + 1
    i: int64 = 0
    while i < Nn:
        j: int64 = 0
        while j < Nn:
            s: int64 = 0
            kk: int64 = 0
            while kk < Nn:
                s = s + A[cast[int64](i * Nn + kk)] * B[cast[int64](kk * Nn + j)]
                kk = kk + 1
            C[cast[int64](i * Nn + j)] = s
            j = j + 1
        i = i + 1
    acc: int64 = 0
    p: int64 = 0
    while p < Nn * Nn:
        acc = acc + C[cast[int64](p)]
        p = p + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
"""
r_on = h.run_through_codegen_ad("cmb_mm", mm, WD, opt=True)
if r_on.kind != "ok" or r_on.stdout != str(ref):
    print(f"FAIL matmul-shape value ref={ref} on={r_on.kind}/{r_on.stdout}"); fails += 1
else:
    src = WD / "cmb_mm.ad"; src.write_text(h.codegen_compatible_source(mm))
    d_on = h.run_dump(src, opt=True)
    text = disasm(d_on.code).splitlines()
    # Find the innermost k-loop body: the block ending at the `jmp` that follows
    # the `imul ...,QWORD PTR [..]` accumulate. Walk back to the previous label-ish
    # branch target boundary by scanning the surrounding ~24 instrs.
    imul_idx = next((n for n, l in enumerate(text)
                     if "imul" in l and "QWORD PTR" in l), None)
    if imul_idx is None:
        print("FAIL matmul-shape: no alu-load imul accumulate found"); fails += 1
    else:
        # The ACCUMULATE + IV-UPDATE region this lever targets runs from the
        # alu-load `imul` (the product) through the loop back-edge `jmp`: it must
        # be `imul; add %acc,%rax; add $1,%kreg; add %Nreg,%idxreg; jmp` — i.e.
        # ZERO push/pop (the seed/legacy path round-trips the s+=prod accumulate
        # AND both IV updates through push/pop/%rax). The cmp-setup + index-address
        # arithmetic BEFORE the imul are separate (later-phase) residuals and are
        # deliberately outside this window.
        hi = imul_idx
        while hi < len(text) - 1 and "jmp" not in text[hi]:
            hi += 1
        region = text[imul_idx:hi + 1]
        pushpops = [l for l in region if "\tpush" in l or "\tpop" in l]
        # the accumulate `add %acc,%rax`/`add %rax,%acc` and the immediate/reg IV
        # updates `add $1,%r`/`add %r,%r` must be present as 2-operand forms.
        twoop = [l for l in region if "\tadd " in l]
        if pushpops:
            print("FAIL matmul-shape accumulate+IV region STILL has push/pop:")
            for l in pushpops:
                print("   ", l.split("\t")[-1].strip())
            fails += 1
        elif len(twoop) < 3:
            print(f"FAIL matmul-shape: accumulate+IV not 2-operand "
                  f"(only {len(twoop)} add forms in region)"); fails += 1
        else:
            print(f"[matmul-shape] value={r_on.stdout}=ref OK; accumulate+IV "
                  f"region push/pop-FREE, {len(twoop)} 2-operand adds: "
                  + "; ".join(l.split("\t")[-1].strip() for l in twoop))

if fails:
    print(f"\n[test_opt_combine] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_combine] PASS")
PY
