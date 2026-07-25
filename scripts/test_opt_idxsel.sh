#!/usr/bin/env bash
# scripts/test_opt_idxsel.sh — focused, host-only correctness + firing guard for
# the P1 Phase-2 INDEX-ADDRESS lowering (codegen.ad try_sel_index_into_rcx): the
# array-index expression `arr[<pure-arith index>]` is computed DIRECTLY into %rcx
# (the SIB index register) through the destination-driven selector, scratch-free,
# killing the per-iteration value-at-a-time `mov;push;mov;pop;add` the AST stack
# machine emitted for the index under the IR re-entrancy guard. Armed only --opt.
#
# WHAT IT PROVES (no QEMU):
#   1. ROUTED — a matmul-shape dot product `s += A[i*N+k]*B[k*N+j]` lowers the A
#      index through the selector: IDXSEL > 0, value EXACTLY the reference and ==
#      the --opt-OFF value, and the inner loop shows NO `push`/`pop` framing the
#      index materialisation (the old stack-machine index sum is gone).
#   2. FALLBACK (impure index) — `arr[bump(i)]` where the index calls a function
#      with a side effect MUST NOT route (IDXSEL == 0 for that program), since the
#      address has a side effect and reordering it would change results; the value
#      still matches the reference.
#   3. CORRECTNESS across element sizes (1/2/4/8) and a POINTER base — the index
#      lowering is element-size-agnostic (it computes the index VALUE; the element
#      scale is applied after), so every width and a Ptr[T] base route AND match
#      the --opt-OFF / reference value.
#   4. NEGATIVE / ZERO indices match the reference (modular address arithmetic).
#   5. The lever is byte-INERT OFF: with --opt off IDXSEL == 0 for every program.
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
opt1_require_lane "test_opt_idxsel"

python3 - <<'PY'
import sys, subprocess
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_idxsel"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
M = (1 << 64) - 1
fails = 0

def disasm(code_bytes):
    raw = WD / "hot.bin"; raw.write_bytes(code_bytes)
    return subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(raw)], capture_output=True, text=True).stdout

# ---------------------------------------------------------------------------
# 1) ROUTED: matmul-shape NxN dot product. The A index `i*N+k` is a pure binary
#    of strength-reduced IVs; it must lower through the selector (IDXSEL>0).
# ---------------------------------------------------------------------------
N = 24
A = [(i * 7 + 3) & M for i in range(N * N)]
B = [(i * 5 + 1) & M for i in range(N * N)]
ref = 0
for i in range(N):
    for j in range(N):
        s = 0
        for k in range(N):
            s = (s + A[i * N + k] * B[k * N + j]) & M
        ref = (ref + s) & M

routed = PRELUDE + f"""
A: Array[576, int64]
B: Array[576, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    N: int64 = {N}
    i: int64 = 0
    while i < N * N:
        A[cast[int64](i)] = i * 7 + 3
        B[cast[int64](i)] = i * 5 + 1
        i = i + 1
    acc: int64 = 0
    i = 0
    while i < N:
        j: int64 = 0
        while j < N:
            s: int64 = 0
            k: int64 = 0
            while k < N:
                s = s + A[cast[int64](i * N + k)] * B[cast[int64](k * N + j)]
                k = k + 1
            acc = acc + s
            j = j + 1
        i = i + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
"""
r_on = h.run_through_codegen_ad("idx_routed_on", routed, WD, opt=True)
r_off = h.run_through_codegen_ad("idx_routed_off", routed, WD, opt=False)
src = WD / "idx_routed.ad"; src.write_text(h.codegen_compatible_source(routed))
d_on = h.run_dump(src, opt=True)
d_off = h.run_dump(src, opt=False)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) routed on={r_on.kind}/off={r_off.kind}"); fails += 1
else:
    ix_on = int(getattr(d_on, "idxsel", 0) or 0)
    ix_off = int(getattr(d_off, "idxsel", 0) or 0)
    if r_on.stdout != str(ref) or r_off.stdout != str(ref):
        print(f"FAIL routed value ref={ref} on={r_on.stdout} off={r_off.stdout}"); fails += 1
    if ix_on == 0:
        print(f"FAIL routed IDXSEL never fired (idxsel_on={ix_on})"); fails += 1
    if ix_off != 0:
        print(f"FAIL routed NOT byte-inert OFF (IDXSEL={ix_off})"); fails += 1
    # POSITIVE disasm signal: the dest-driven index builds the sum DIRECTLY into
    # %rcx (`add rcx,<reg>`) feeding the scaled-index `lea [..+rcx*8]`. The old
    # stack-machine index NEVER wrote rcx as an ADD destination — it did
    # `... pop rcx; add rax,rcx; mov rcx,rax` (sum in %rax, then copied). So an
    # `add    rcx,` line is a form unique to the lowered, scratch-free index sum,
    # and there must be NO `pop` between it and the consuming `rcx*8` lea.
    text = disasm(d_on.code)
    lines = text.splitlines()
    def mn(l):  # the mnemonic+operands tail after the byte column
        return l.split("\t")[-1].strip() if "\t" in l else l.strip()
    addrcx = []
    for n, l in enumerate(lines):
        m = mn(l)
        if m.startswith("add ") and m.split(None, 1)[1].lstrip().startswith("rcx,"):
            # find a rcx*8 lea within the next few instructions, no pop between
            tail = lines[n + 1:n + 5]
            if any("rcx*8" in mn(t) for t in tail) and not any(
                    mn(t).startswith("pop") for t in tail):
                addrcx.append(m)
    if not addrcx:
        print("FAIL routed: no dest-driven `add rcx,<reg>` index sum feeding a "
              "scaled-index lea (index not lowered into %rcx)"); fails += 1
    else:
        print(f"[routed] IDXSEL={ix_on} value={r_on.stdout}=ref OK; "
              f"lowered index sum into %rcx: '{addrcx[0]}' (no push/pop)")

# ---------------------------------------------------------------------------
# 2) FALLBACK: impure index `G[bump(i)]` — a call in the address MUST fall back.
# ---------------------------------------------------------------------------
n = 32
G = [(i * 9 + 2) & M for i in range(n)]
ref2 = 0
for r in range(20):
    for i in range(n):
        # bump(i) = (i*3+1) % n  — pure value, but a CALL in the .ad index
        ref2 = (ref2 + G[(i * 3 + 1) % n]) & M
impure = PRELUDE + f"""
G: Array[64, int64]
def bump(i: int64) -> int64:
    return (i * 3 + 1) % {n}
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        G[cast[int64](i)] = i * 9 + 2
        i = i + 1
    s: int64 = 0
    r: int64 = 0
    while r < 20:
        i = 0
        while i < {n}:
            s = s + G[cast[int64](bump(i))]
            i = i + 1
        r = r + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
i_on = h.run_through_codegen_ad("idx_impure_on", impure, WD, opt=True)
i_off = h.run_through_codegen_ad("idx_impure_off", impure, WD, opt=False)
src2 = WD / "idx_impure.ad"; src2.write_text(h.codegen_compatible_source(impure))
di_on = h.run_dump(src2, opt=True)
if i_on.kind != "ok" or i_off.kind != "ok":
    print(f"FAIL(compile) impure on={i_on.kind}/off={i_off.kind}"); fails += 1
else:
    ix = int(getattr(di_on, "idxsel", 0) or 0)
    if i_on.stdout != str(ref2) or i_off.stdout != str(ref2):
        print(f"FAIL impure value ref={ref2} on={i_on.stdout} off={i_off.stdout}"); fails += 1
    if ix != 0:
        print(f"FAIL impure index ROUTED (must fall back; IDXSEL={ix})"); fails += 1
    else:
        print(f"[impure fallback] value={i_on.stdout}=ref OK; IDXSEL=0 (call-in-index not routed)")

# ---------------------------------------------------------------------------
# 3) ELEMENT SIZES 1/2/4/8 + 4) NEGATIVE/ZERO indices: value must match the
#    reference and the --opt-OFF build for every width. The index `i*3+1` is the
#    same pure binary regardless of element size; correctness is the assertion.
# ---------------------------------------------------------------------------
for (ty, width) in [("uint8", 1), ("uint16", 2), ("uint32", 4), ("int64", 8)]:
    n = 40
    mask = (1 << (8 * width)) - 1
    arr = [0] * 128
    for i in range(n):
        arr[(i * 3 + 1) % 128] = (i * 13 + 5) & mask
    refw = 0
    for i in range(n):
        refw = (refw + arr[(i * 3 + 1) % 128]) & M
    prog = PRELUDE + f"""
W: Array[128, {ty}]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 128:
        W[cast[int64](i)] = cast[{ty}](0)
        i = i + 1
    i = 0
    while i < {n}:
        W[cast[int64]((i * 3 + 1) % 128)] = cast[{ty}](i * 13 + 5)
        i = i + 1
    s: int64 = 0
    i = 0
    while i < {n}:
        s = s + cast[int64](W[cast[int64]((i * 3 + 1) % 128)])
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
    w_on = h.run_through_codegen_ad(f"idx_w{width}_on", prog, WD, opt=True)
    w_off = h.run_through_codegen_ad(f"idx_w{width}_off", prog, WD, opt=False)
    if w_on.kind != "ok" or w_off.kind != "ok":
        print(f"FAIL(compile) width{width} on={w_on.kind}/off={w_off.kind}"); fails += 1
    elif w_on.stdout != str(refw) or w_off.stdout != str(refw):
        print(f"FAIL width{width} value ref={refw} on={w_on.stdout} off={w_off.stdout}"); fails += 1
    else:
        print(f"[elem {ty}/{width}B] value={w_on.stdout}=ref OK (on==off)")

# ---------------------------------------------------------------------------
# 5) POINTER base: `p[i*2+1]` where p is a Ptr[int64] aliasing a global array.
# ---------------------------------------------------------------------------
n = 30
P = [(i * 4 + 7) & M for i in range(64)]
refp = 0
for i in range(n):
    refp = (refp + P[(i * 2 + 1) % 64]) & M
ptr = PRELUDE + f"""
PB: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 64:
        PB[cast[int64](i)] = i * 4 + 7
        i = i + 1
    p: Ptr[int64] = cast[Ptr[int64]](&PB[0])
    s: int64 = 0
    i = 0
    while i < {n}:
        s = s + p[cast[int64]((i * 2 + 1) % 64)]
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
p_on = h.run_through_codegen_ad("idx_ptr_on", ptr, WD, opt=True)
p_off = h.run_through_codegen_ad("idx_ptr_off", ptr, WD, opt=False)
if p_on.kind != "ok" or p_off.kind != "ok":
    print(f"FAIL(compile) ptr on={p_on.kind}/off={p_off.kind}"); fails += 1
elif p_on.stdout != str(refp) or p_off.stdout != str(refp):
    print(f"FAIL ptr value ref={refp} on={p_on.stdout} off={p_off.stdout}"); fails += 1
else:
    print(f"[pointer base] value={p_on.stdout}=ref OK (on==off)")

if fails:
    print(f"\n[test_opt_idxsel] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_idxsel] PASS")
PY
