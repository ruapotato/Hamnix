#!/usr/bin/env bash
# scripts/test_opt_coalesce.sh — focused, host-only correctness + firing guard
# for the LICM-BOUNDARY COPY COALESCE (opt.ad copy-propagation across an indexed/
# member store). Armed only under --opt; byte-identical to the frozen seed OFF.
#
# THE LEVER: LICM hoists a loop-invariant pure subexpression into a pre-header
# temp `__licm_tmp` and rewrites the body occurrence `t = a*a+b` into a residual
# COPY `t = __licm_tmp`. When `t`'s ONLY consumer is an INDEXED/MEMBER store
# (`bucket[i] = bucket[i] + t + ...`), Phase-9 copy-propagation used to treat the
# store as a hard barrier and bail BEFORE forwarding the reads in its rvalue, so
# `t` kept a live reader, was never dead, and codegen emitted a per-iteration
# register copy of the hoisted invariant (`mov rax,rN; mov rM,rax`, 2 instrs/
# temp). Now copy-prop forwards the reads inside a call/addr-free indexed-store
# rvalue + address FIRST (a value-preserving rename of an unclobbered, provably-
# equal copy root), leaving `t` unread so the following DCE deletes the dead copy
# decl. The store's accumulation then reads the HOISTED register DIRECTLY: 0
# per-iteration copies, and freeing the copy registers lets the array base hoist
# too (lower register pressure).
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECT + MATCHES OFF: the licm-pattern kernel produces EXACTLY the
#      reference value under --opt AND equals the --opt-OFF value.
#   2. THE COPIES ARE GONE (0 copies in the loop body): in the ON disassembly of
#      main's inner loop, each hoisted-invariant accumulation `add rax,rN` reads a
#      register that is written in the PRE-HEADER and NOT re-written inside the
#      inner loop body — i.e. the invariant is read directly, with no surviving
#      per-iteration `mov`-copy of it. (If the copies survived, the adds would
#      read scratch registers written by the copy INSIDE the loop.)
#   3. FIRED + BYTE-INERT OFF: copy-prop forwards fired under --opt (COPYPROP>0)
#      and DCE removed the now-dead copies (DCE>0); OFF is byte-inert (COPYPROP
#      ==0, the opt passes never ran).
#   4. SAFETY (interfering coalesce must NOT forward): a copy whose SOURCE is
#      reassigned before the store, a call inside the store rvalue, and a pointer
#      store that aliases the source all stay CORRECT (the copy is not wrongly
#      forwarded). Covered by the differential corpus (adder_fuzzer
#      _run_coalesce_corpus, whose deliberate-break — dropping the source-clobber
#      kill — miscompiles src_clobber_no_forward, proving the net sees the bug).
#
# HOST-ONLY: python3 + as/ld/gcc + objdump (x86_64). NO QEMU. The cached dump
# driver under build/fuzz_ad_codegen AUTO-INVALIDATES on any compiler change.
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
opt1_require_lane "test_opt_coalesce"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_coalesce"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
M = (1 << 64) - 1
fails = 0

# ---------------------------------------------------------------------------
# The LICM pattern (mirrors tests/bench/opt/licm.ad with small trip counts):
# three inner-loop-invariant temps (a*a+b, a*3-7, a*a) consumed ONLY by the
# indexed store into bucket[slot].
# ---------------------------------------------------------------------------
NB, A, J = 8, 6, 5
bucket = [0] * NB
for a in range(1, A + 1):
    b = a + 13
    for j in range(J):
        t1 = (a * a + b) & M
        t2 = (a * 3 - 7) & M
        t3 = (a * a) & M
        s = j & (NB - 1)
        bucket[s] = (bucket[s] + t1 + t2 + t3 + j) & M
ref = 0
for kk in range(NB):
    ref = (ref + bucket[kk]) & M

SRC = PRELUDE + f"""
cbk: Array[{NB}, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: int64 = 1
    while a < {A + 1}:
        b: int64 = a + 13
        j: int64 = 0
        while j < {J}:
            t1: int64 = a * a + b
            t2: int64 = a * 3 - 7
            t3: int64 = a * a
            slot: int64 = j & {NB - 1}
            cbk[cast[int64](slot)] = (cbk[cast[int64](slot)] + t1 + t2 + t3 + j)
            j = j + 1
        a = a + 1
    acc: int64 = 0
    k: int64 = 0
    while k < {NB}:
        acc = acc + cbk[cast[int64](k)]
        k = k + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & 255)
"""

r_on = h.run_through_codegen_ad("coal_licm_on", SRC, WD, opt=True, keep=True)
r_off = h.run_through_codegen_ad("coal_licm_off", SRC, WD, opt=False, keep=True)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) on={r_on.kind}/off={r_off.kind} "
          f"{(r_on.detail or r_off.detail)[:160]}")
    sys.exit(1)

# (1) correctness ON==OFF==ref
if r_on.stdout != str(ref) or r_off.stdout != str(ref):
    print(f"FAIL(value) ref={ref} on={r_on.stdout} off={r_off.stdout}"); fails += 1
else:
    print(f"[value] on==off==ref ({ref}) OK")

# (3) forwards fired + DCE removed dead copies + byte-inert OFF
cp_on = int(getattr(r_on, "copyprop", 0) or 0)
cp_off = int(getattr(r_off, "copyprop", 0) or 0)
dce_on = int(getattr(r_on, "dce", 0) or 0)
if cp_on < 3:
    print(f"FAIL(no-fire) copyprop_on={cp_on} (<3: the store-rvalue forward did "
          f"not fire for all three hoisted invariants)"); fails += 1
elif dce_on < 3:
    print(f"FAIL(no-dce) dce_on={dce_on} (<3: the forwarded copies were not DCE'd)")
    fails += 1
elif cp_off != 0:
    print(f"FAIL(off-fired) copyprop_off={cp_off} (must be 0 — byte-inert OFF)")
    fails += 1
else:
    print(f"[fire] copyprop_on={cp_on} dce_on={dce_on} copyprop_off=0 OK")

# (2) DISASM: 0 surviving copies of the hoisted invariants in the inner loop.
#     The three accumulation `add rax,rN` must read registers written in the
#     PRE-HEADER (loop-invariant) and NOT written inside the inner loop body.
def disasm_main(dump):
    raw = WD / "coal_licm.code.bin"; raw.write_bytes(dump.code)
    txt = subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(raw)], capture_output=True, text=True).stdout
    rows = []
    for ln in txt.splitlines():
        mm = re.match(r"\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(.*)$", ln)
        if mm:
            rows.append((int(mm.group(1), 16), mm.group(2).strip()))
    return rows

try:
    dsrc = WD / "coal_licm_dump.ad"
    dsrc.write_text(h.codegen_compatible_source(SRC))
    d_on = h.run_dump(dsrc, opt=True)
    if d_on.status != "ok":
        raise RuntimeError(f"run_dump status={d_on.status} "
                           f"{getattr(d_on, 'detail', '')[:160]}")
    rows = disasm_main(d_on)
    # The inner loop is the SECOND `cmp <reg>,0x5` (J=5) .. its backward jmp. Find
    # all cmp-with-imm 0x5 that head a loop; the inner one is the one whose body
    # contains the indexed store (a `mov QWORD PTR [reg],reg`). Identify the loop
    # body as the instruction window between an inner-loop-head cmp and the next
    # backward `jmp` to it.
    # Locate the accumulation: a run of >=3 consecutive `add <ACC>,<srcreg>` that
    # sum the loaded slot with the hoisted invariants. NOTE the accumulator is NOT
    # hardcoded to %rax anymore — as the register allocator matured the store RHS is
    # accumulated in a CALLEE-SAVED scratch (here %r9) so that %rax stays free for
    # the two element-address leas (the array base itself now hoists into %r8). Match
    # a run into any single accumulator register.
    add_all = [(i, mm.group(1), mm.group(2))
               for i, (_, t) in enumerate(rows)
               if (mm := re.match(r"add\s+(r\w+),(r\w+)$", t))]
    # Group maximal consecutive runs that share one accumulator (dst) register.
    best = []
    run = []
    prev_i = None
    prev_acc = None
    for i, acc, _src in add_all:
        if prev_i is not None and i == prev_i + 1 and acc == prev_acc:
            run.append(i)
        else:
            if len(run) > len(best):
                best = run
            run = [i]
        prev_i, prev_acc = i, acc
    if len(run) > len(best):
        best = run
    if len(best) < 3:
        print(f"FAIL(disasm) could not locate the >=3 accumulation add run "
              f"(found run len {len(best)})"); fails += 1
    else:
        # Registers read by the accumulation adds.
        add_srcs = []
        for i in best:
            mm = re.match(r"add\s+r\w+,(r\w+)", rows[i][1])
            add_srcs.append(mm.group(1))
        # Delimit the inner loop body: from the nearest preceding loop-head cmp/jge
        # backwards is the pre-header; the body is between the inner-loop head and
        # the backward jmp AFTER the adds. Find the backward jmp after the run.
        body_start = best[0]
        # walk back to the inner-loop top: the last `cmp rXX,0x5`+`jge` before the run
        top = 0
        for i in range(best[0], -1, -1):
            if re.match(r"cmp\s+r\w+,0x5\b", rows[i][1]):
                top = i; break
        # find backward jmp after the run (end of loop body)
        end = len(rows) - 1
        for i in range(best[-1], len(rows)):
            if rows[i][1].startswith("jmp") and int(rows[i][1].split()[-1], 16) <= rows[top][0]:
                end = i; break
        body_regs_written = set()
        for i in range(top, end + 1):
            t = rows[i][1]
            # any instr whose destination is a register: `mov rDST,..`, `add rDST,..`,
            # `and rDST,..`, `imul rDST,..`, `sub rDST,..`, `lea rDST,..`, `movzx ..`
            mm = re.match(r"(?:mov|add|sub|and|or|xor|imul|lea|movzx|movabs)\s+"
                          r"(r\w+),", t)
            if mm:
                body_regs_written.add(mm.group(1))
        # The accumulation must read >=3 DISTINCT registers, NONE of which is
        # written inside the inner loop body (they are the pre-header hoisted
        # invariants read directly — 0 surviving copies).
        distinct = set(add_srcs)
        # The accumulator register (written each add) is itself in body_regs_written,
        # so it is naturally excluded from the "must be invariant" set below; the
        # hoisted-invariant sources are the operands NOT written in the body. The
        # induction var (j -> the last add in the run) IS written in the loop, so it
        # is excluded too — hence we require at least 3 invariant (non-loop-written)
        # sources among the run.
        invariant_srcs = [s for s in distinct if s not in body_regs_written]
        if len(invariant_srcs) < 3:
            surviving = [s for s in distinct if s in body_regs_written and s != "rax"]
            print(f"FAIL(copies-survive) the inner-loop accumulation reads only "
                  f"{len(invariant_srcs)} pre-header-invariant register(s); "
                  f"sources={add_srcs} written-in-body={sorted(surviving)} — the "
                  f"hoisted-invariant copies were NOT coalesced away"); fails += 1
        else:
            print(f"[disasm] inner-loop accumulation reads {len(invariant_srcs)} "
                  f"hoisted-invariant regs DIRECTLY ({sorted(invariant_srcs)}); "
                  f"0 surviving per-iteration copies OK")
except Exception as ex:
    print(f"FAIL(disasm) exception: {ex}"); fails += 1

# (4) SAFETY: run the differential corpus (correct forward where legal, NO
#     forward across clobbered source / call / aliasing store).
coal_ok, coal_fwd = F._run_coalesce_corpus()
if not coal_ok:
    print(f"FAIL(corpus) copy-coalesce differential corpus miscompiled / inert")
    fails += 1
else:
    print(f"[corpus] copy-coalesce corpus OK ({coal_fwd} forwards, safety shapes "
          f"correct)")

if fails:
    print(f"\n[test_opt_coalesce] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_coalesce] PASS (LICM-boundary copies coalesced away, 0 copies "
      "in the loop body, correct, fired, byte-inert OFF, safety shapes sound)")
PY
