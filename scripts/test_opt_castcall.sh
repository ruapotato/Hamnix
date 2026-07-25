#!/usr/bin/env bash
# scripts/test_opt_castcall.sh — focused, host-only correctness + firing guard for
# the IR_AST_HAS_CALL CAST CONSERVATISM FIX (adder/compiler/ir.ad ir_ast_has_call).
# Armed only under --opt; byte-identical to the frozen seed OFF.
#
# THE FIX: ir_ast_has_call recursed a cast's nd_a (a TYPE node, ND_TYPE/ND_PTR_TYPE),
# hit the conservative "unknown kind -> has-call" branch, and wrongly flagged EVERY
# `cast[T](e)`-containing pure tree as call-bearing. ir_tree_has_call gates the
# CALLER-SAVED IR scratch pool (only a call-free tree may park an operand in a
# caller-saved register). So a cast-indexed store RHS under callee-saved exhaustion
# (saxpy's `ys[i]=(ys[i]+a*xs[i])&mask`, `cast[int64](i)` indices) could not use
# caller-saved scratch and fell all the way back to the AST stack machine (3 push /
# 3 pop per iteration). The fix skips the type operand — only nd_b (the VALUE
# operand) can hold a call — so the store RHS now routes DEST-DRIVEN
# (try_sel_assign_index), and its per-loop 32B offset flips 0->16 (the SAXPY dense-
# store arm in emit_loop_align) to BANK the uop cut.
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECT + MATCHES OFF: the saxpy-shaped cast-indexed pressured store and a
#      cast-wrapped-SIDE-EFFECTING-CALL store both produce EXACTLY the reference
#      value under --opt AND equal the --opt-OFF value.
#   2. FIRED + BYTE-INERT OFF: the cast-indexed store routes dest-driven
#      (IDXSTORE>0) under --opt; IDXSTORE==0 with --opt off.
#   3. THE STACK ROUND-TRIP IS GONE: in the ON disassembly the saxpy hot loop has
#      NO push/pop (the mask/`a` are combined straight from their home registers).
#   4. SAFETY (the cast value-operand recursion is load-bearing): the deliberate
#      break (--castcall-break, which skips a cast's VALUE operand) miscompiles the
#      cast-wrapped-call store (a caller-saved scratch held across the call is
#      clobbered) — the differential corpus catches it.
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
opt1_require_lane "test_opt_castcall"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_castcall"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
M = (1 << 64) - 1
fails = 0

# ---------------------------------------------------------------------------
# A saxpy-shaped self-referential store over CAST indices, under enough register
# pressure (mask/n/a/reps live) that the store RHS must use caller-saved scratch.
# ---------------------------------------------------------------------------
n = 256
ys = [(i * 5 + 1) % 97 for i in range(n)]
xs = [(i * 3 + 7) % 101 for i in range(n)]
a = 3
for _ in range(6):
    for i in range(n):
        ys[i] = (ys[i] + a * xs[i]) & M
ref = 0
for i in range(n):
    ref = (ref + ys[i]) & M

SRC = PRELUDE + f"""
ysA: Array[{n}, int64]
xsA: Array[{n}, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    mask: int64 = 18446744073709551615
    n: int64 = {n}
    i: int64 = 0
    while i < n:
        ysA[cast[int64](i)] = (i * 5 + 1) % 97
        xsA[cast[int64](i)] = (i * 3 + 7) % 101
        i = i + 1
    a: int64 = 3
    reps: int64 = 0
    while reps < 6:
        i = 0
        while i < n:
            ysA[cast[int64](i)] = (ysA[cast[int64](i)] + a * xsA[cast[int64](i)]) & mask
            i = i + 1
        reps = reps + 1
    acc: int64 = 0
    i = 0
    while i < n:
        acc = (acc + ysA[cast[int64](i)]) & mask
        i = i + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
"""

r_on = h.run_through_codegen_ad("cc_on", SRC, WD, opt=True, keep=True)
r_off = h.run_through_codegen_ad("cc_off", SRC, WD, opt=False, keep=True)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) on={r_on.kind}/off={r_off.kind} "
          f"{(r_on.detail or r_off.detail)[:160]}")
    sys.exit(1)

# (1) correctness ON==OFF==ref
if r_on.stdout != str(ref) or r_off.stdout != str(ref):
    print(f"FAIL(value) ref={ref} on={r_on.stdout} off={r_off.stdout}"); fails += 1
else:
    print(f"[value] on==off==ref ({ref}) OK")

# (2) fired + byte-inert OFF
ix_on = int(getattr(r_on, "idxstore", 0) or 0)
ix_off = int(getattr(r_off, "idxstore", 0) or 0)
if ix_on < 1:
    print(f"FAIL(no-fire) idxstore_on={ix_on} (the cast-indexed store RHS did not "
          f"route dest-driven — the cast fix did not free caller-saved scratch)")
    fails += 1
elif ix_off != 0:
    print(f"FAIL(off-fired) idxstore_off={ix_off} (must be 0 — byte-inert OFF)")
    fails += 1
else:
    print(f"[fire] idxstore_on={ix_on} idxstore_off=0 OK")

# (3) DISASM: the saxpy hot loop has NO push/pop.
def disasm(dump):
    raw = WD / "cc.code.bin"; raw.write_bytes(dump.code)
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
    dsrc = WD / "cc_dump.ad"
    dsrc.write_text(h.codegen_compatible_source(SRC))
    d_on = h.run_dump(dsrc, opt=True)
    if d_on.status != "ok":
        raise RuntimeError(f"run_dump status={d_on.status} "
                           f"{getattr(d_on, 'detail', '')[:160]}")
    rows = disasm(d_on)
    # Find the innermost 'and r*,rbx' (mask fold) — its enclosing hot loop must
    # contain NO push/pop. Approximate: no push/pop anywhere between two adjacent
    # backward-branch targets that contains an 'imul r*,[' (the a*xs[i] fold).
    andmask = [k for k, (_, t) in enumerate(rows)
               if re.match(r"and\s+r\d+,rbx", t)]
    ok_nopushpop = False
    for k in andmask:
        lo = max(0, k - 20); hi = min(len(rows), k + 8)
        win = [t for _, t in rows[lo:hi]]
        if any(re.match(r"imul\s+r\d+,(?:QWORD PTR )?\[", w) for w in win) and \
           not any(re.match(r"(push|pop)\b", w) for w in win):
            ok_nopushpop = True
            break
    if not ok_nopushpop:
        print("FAIL(disasm) saxpy hot loop still has a push/pop round-trip "
              "(the mask/`a` were not combined from their home registers)")
        fails += 1
    else:
        print("[disasm] saxpy hot loop folds mask/`a` from registers with NO "
              "stack push/pop round-trip OK")
except Exception as ex:
    print(f"FAIL(disasm) exception: {ex}"); fails += 1

# (4) SAFETY: the differential corpus (cast-indexed fire + correct, cast-wrapped
#     side-effecting call correct, and the --castcall-break deliberate break CAUGHT).
cc_ok, cc_total, cc_brk = F._run_castcall_corpus()
if not cc_ok:
    print("FAIL(corpus) castcall differential corpus miscompiled / inert")
    fails += 1
elif not cc_brk:
    print("FAIL(break) the --castcall-break deliberate break was NOT caught "
          "(the cast value-operand recursion is not proven load-bearing)")
    fails += 1
else:
    print(f"[corpus] castcall corpus OK ({cc_total} routed store(s), side-effecting "
          f"call correct, deliberate break caught)")

if fails:
    print(f"\n[test_opt_castcall] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_castcall] PASS (cast-indexed store routes dest-driven, correct, "
      "fired, byte-inert OFF, no stack round-trip, break caught)")
PY
