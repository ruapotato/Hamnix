#!/usr/bin/env bash
# scripts/test_opt_idxreg.sh — focused, host-only correctness + firing guard for
# the DIRECT-SIB-INDEX-REGISTER coalesce (codegen.ad gen_index_addr). Armed only
# under --opt; byte-identical to the frozen seed OFF.
#
# THE LEVER: `arr[i]` computes the element address as one scaled-index `lea`. The
# legacy path materialises the index into %rcx first: gen_expr(index) leaves it in
# %rax, then `mov %rax,%rcx`, so a bare register-promoted local index `i` costs
# `mov %i,%rax; mov %rax,%rcx` (2 movs/iter) before the address lea. When the
# (cast-peeled) index is a single register-resident full-width-8 local, that
# promoted register goes STRAIGHT into the SIB index slot
# (`lea (base,%ireg,s),%rax`) — 0 index copies. Value-identical: the SIB index
# uses the full 64-bit register content, exactly what gen_expr(ident) would leave.
# Hot in sieve's clear/mark/count loops (`flags[z] / flags[j] / flags[i]`) and
# matmul's C[p] checksum fold.
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECT + MATCHES OFF: a sieve-shaped kernel produces EXACTLY the reference
#      value under --opt AND equals the --opt-OFF value.
#   2. THE COPIES ARE GONE: in the ON disassembly the element-address lea reads the
#      promoted index register DIRECTLY (`lea rax,[base+<reg>*s]`) with NO preceding
#      `mov rax,<reg>; mov rcx,rax` copy pair for that access.
#   3. FIRED + BYTE-INERT OFF: IDXREG>0 under --opt; IDXREG==0 with --opt off.
#   4. SAFETY (fallback shapes stay correct): a NARROWING cast index
#      `g[cast[uint8](j)]` (truncation must run), an IMPURE index `g[f()]`, and a
#      BINARY index `g[i+1]` all stay CORRECT (the direct path is refused). Covered
#      by the differential corpus (adder_fuzzer _run_idxreg_corpus, whose
#      deliberate-break — peeling the direct path THROUGH a narrowing cast —
#      miscompiles narrowing_cast_fallback, proving the net sees the bug).
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
opt1_require_lane "test_opt_idxreg"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_idxreg"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
M = (1 << 64) - 1
fails = 0

# ---------------------------------------------------------------------------
# A sieve-shaped kernel: a global uint8 array cleared then counted, both loops
# indexing with a bare register-promoted local (the direct-SIB coalesce target).
# ---------------------------------------------------------------------------
N = 400
flg = [0] * N
for z in range(N):
    flg[z] = (z * 13 + 7) & 0xFF
ref = 0
for i in range(N):
    ref = (ref + flg[i]) & M

SRC = PRELUDE + f"""
flags: Array[512, uint8]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    z: int64 = 0
    while z < {N}:
        flags[cast[int64](z)] = cast[uint8](z * 13 + 7)
        z = z + 1
    acc: int64 = 0
    i: int64 = 0
    while i < {N}:
        acc = acc + cast[int64](flags[cast[int64](i)])
        i = i + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
"""

r_on = h.run_through_codegen_ad("ixr_on", SRC, WD, opt=True, keep=True)
r_off = h.run_through_codegen_ad("ixr_off", SRC, WD, opt=False, keep=True)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) on={r_on.kind}/off={r_off.kind} "
          f"{(r_on.detail or r_off.detail)[:160]}")
    sys.exit(1)

# (1) correctness ON==OFF==ref
if r_on.stdout != str(ref) or r_off.stdout != str(ref):
    print(f"FAIL(value) ref={ref} on={r_on.stdout} off={r_off.stdout}"); fails += 1
else:
    print(f"[value] on==off==ref ({ref}) OK")

# (3) fired + byte-inert OFF
ix_on = int(getattr(r_on, "idxreg", 0) or 0)
ix_off = int(getattr(r_off, "idxreg", 0) or 0)
if ix_on < 2:
    print(f"FAIL(no-fire) idxreg_on={ix_on} (<2: the two bare-index loops did not "
          f"both route the index register into the SIB)"); fails += 1
elif ix_off != 0:
    print(f"FAIL(off-fired) idxreg_off={ix_off} (must be 0 — byte-inert OFF)")
    fails += 1
else:
    print(f"[fire] idxreg_on={ix_on} idxreg_off=0 OK")

# (2) DISASM: the element-address lea reads the promoted index register DIRECTLY,
#     with NO `mov rax,<reg>; mov rcx,rax` index copy pair preceding it.
def disasm(dump):
    raw = WD / "ixr.code.bin"; raw.write_bytes(dump.code)
    txt = subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(raw)], capture_output=True, text=True).stdout
    rows = []
    for ln in txt.splitlines():
        mm = re.match(r"\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(.*)$", ln)
        if mm:
            rows.append(mm.group(2).strip())
    return rows

try:
    dsrc = WD / "ixr_dump.ad"
    dsrc.write_text(h.codegen_compatible_source(SRC))
    d_on = h.run_dump(dsrc, opt=True)
    if d_on.status != "ok":
        raise RuntimeError(f"run_dump status={d_on.status} "
                           f"{getattr(d_on, 'detail', '')[:160]}")
    rows = disasm(d_on)
    # Find scaled-index leas whose index is NOT rcx/rax: `lea rax,[<base>+<reg>*1]`
    # where <reg> is a promoted (rbx/r12-r15) register — the direct-SIB coalesce.
    # The legacy path would instead materialise the index into %rcx and emit
    # `lea rax,[<base>+rcx*1]`, so a promoted-register SIB index is ITSELF the proof
    # that the index copy is gone; if the coalesce is reverted this count drops to 0
    # (the leas become rcx-indexed, which the group(2) filter excludes).
    direct = 0
    index_copy_before_sib = 0
    for k, t in enumerate(rows):
        mm = re.match(r"lea\s+rax,\[(\w+)\+(\w+)\*1\]", t)
        if mm and mm.group(2) not in ("rcx", "rax"):
            direct += 1
            # A GENUINE surviving index copy would materialise THIS lea's index
            # register from %rax right before the address computation, i.e.
            # `mov <idxreg>,rax`. Assert none such precedes it. (The earlier version
            # flagged any `mov rcx,rax` here, but that misfires: for a STORE
            # `arr[i]=v` the store VALUE is staged into %rcx — `mov rcx,rax` then
            # `mov [rax],cl` — which is NOT an index copy; the index is already in
            # the promoted SIB register, %rcx is untouched by the address path.)
            idxreg = mm.group(2)
            prev2 = rows[max(0, k - 2):k]
            if any(re.match(rf"mov\s+{idxreg},rax\b", p) for p in prev2):
                index_copy_before_sib += 1
    if direct < 2:
        print(f"FAIL(disasm) found only {direct} direct-SIB-index leas "
              f"(expected >=2, one per bare-index loop)"); fails += 1
    elif index_copy_before_sib != 0:
        print(f"FAIL(disasm) {index_copy_before_sib} direct-SIB leas still had a "
              f"per-access `mov <idx>,rax` index copy before them"); fails += 1
    else:
        print(f"[disasm] {direct} element-address leas read the promoted index "
              f"register DIRECTLY (0 per-access index copies) OK")
except Exception as ex:
    print(f"FAIL(disasm) exception: {ex}"); fails += 1

# (4) SAFETY: the differential corpus (all base flavours + element sizes correct,
#     narrowing-cast / impure-index / binary-index fallbacks byte-correct).
ix_ok, ix_total = F._run_idxreg_corpus()
if not ix_ok:
    print(f"FAIL(corpus) idxreg differential corpus miscompiled / inert")
    fails += 1
else:
    print(f"[corpus] idxreg corpus OK ({ix_total} coalesces, fallback shapes "
          f"correct)")

if fails:
    print(f"\n[test_opt_idxreg] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_idxreg] PASS (bare-index register routed into SIB, 0 index "
      "copies, correct, fired, byte-inert OFF, fallback shapes sound)")
PY
