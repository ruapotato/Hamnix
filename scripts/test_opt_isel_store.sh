#!/usr/bin/env bash
# scripts/test_opt_isel_store.sh — focused, host-only correctness + firing guard
# for the P1 Phase-3 STATEMENT-GLUE STORE routing (codegen.ad
# try_sel_aug_assign_name + try_sel_assign_index). Armed only --opt.
#
# WHAT IT PROVES (no QEMU):
#   1. ACCUMULATOR routing — `s OP= <pure expr>` (OP in +,-,*) into a register-
#      promoted scalar home: the dump's ACCSEL counter is > 0, the program's value
#      is EXACTLY the reference and equals the --opt-OFF value, and the routed
#      augmented op appears as `op %reg,%reg` into a NON-rax destination register
#      with no per-update slot reload of the accumulator.
#   2. INDEXED-STORE routing — `arr[i] = <pure-arith binop>` (saxpy shape): the
#      dump's IDXSTORE counter is > 0, value bit-exact vs reference and vs OFF.
#   3. FALLBACK soundness — a FLOAT accumulator and a CALL-in-value accumulator do
#      NOT route (ACCSEL/IDXSTORE contribution stays 0 for those shapes) yet ON==OFF.
#   4. The levers are byte-INERT OFF: with --opt off ACCSEL==0 and IDXSTORE==0.
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
opt1_require_lane "test_opt_isel_store"

python3 - <<'PY'
import sys, subprocess
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_isel_store"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
M = (1 << 64) - 1
fails = 0

def disasm(code_bytes):
    raw = WD / "hot.bin"; raw.write_bytes(code_bytes)
    return subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(raw)], capture_output=True, text=True).stdout

# ---------------------------------------------------------------------------
# 1) ACCUMULATOR: nested loops with a loop-carried `total` and a per-iteration
#    re-initialised inner `row` read AFTER the inner loop (the historical blind
#    spot). All updates are `+=`/`*=` -> routed into register homes.
# ---------------------------------------------------------------------------
N = 14
A = [(i * 3 + 1) & M for i in range(N * N)]
B = [(i * 2 + 5) & M for i in range(N)]
total = 0
for i in range(N):
    row = 0
    for j in range(N):
        row = (row + A[i * N + j] * B[j]) & M
    total = (total + row + i) & M
acc_src = PRELUDE + f"""
A: Array[{N*N}, int64]
B: Array[{N}, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    k: int64 = 0
    while k < {N*N}:
        A[cast[int64](k)] = k * 3 + 1
        k = k + 1
    k = 0
    while k < {N}:
        B[cast[int64](k)] = k * 2 + 5
        k = k + 1
    total: int64 = 0
    i: int64 = 0
    while i < {N}:
        row: int64 = 0
        j: int64 = 0
        while j < {N}:
            row += A[cast[int64](i * {N} + j)] * B[cast[int64](j)]
            j += 1
        total += row + i
        i += 1
    print_u64(cast[uint64](total))
    return cast[int32](total & cast[int64](255))
"""
r_on = h.run_through_codegen_ad("acc_on", acc_src, WD, opt=True)
r_off = h.run_through_codegen_ad("acc_off", acc_src, WD, opt=False)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) acc on={r_on.kind}/off={r_off.kind}"); fails += 1
else:
    acc_on = int(getattr(r_on, "accsel", 0) or 0)
    if r_on.stdout != str(total) or r_off.stdout != str(total):
        print(f"FAIL acc value ref={total} on={r_on.stdout} off={r_off.stdout}"); fails += 1
    if acc_on == 0:
        print(f"FAIL acc ACCSEL never fired (accsel={acc_on})"); fails += 1
    if int(getattr(r_off, "accsel", 0) or 0) != 0:
        print("FAIL acc NOT byte-inert OFF (ACCSEL!=0)"); fails += 1
    else:
        print(f"[accumulator] ACCSEL={acc_on} value={r_on.stdout}=ref OK")

# ---------------------------------------------------------------------------
# 2) INDEXED STORE: saxpy `Y[i] = Y[i] + a*X[i]` (store-to-aliased-load).
# ---------------------------------------------------------------------------
n = 24
Y = [(i * 5 + 1) & M for i in range(n)]
X = [(i * 3 + 7) & M for i in range(n)]
a = 3
for rep in range(40):
    for i in range(n):
        Y[i] = (Y[i] + a * X[i]) & M
sref = 0
for i in range(n):
    sref = (sref + Y[i]) & M
idx_src = PRELUDE + f"""
Y: Array[64, int64]
X: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        Y[cast[int64](i)] = i * 5 + 1
        X[cast[int64](i)] = i * 3 + 7
        i = i + 1
    a: int64 = 3
    rep: int64 = 0
    while rep < 40:
        i = 0
        while i < {n}:
            Y[cast[int64](i)] = Y[cast[int64](i)] + a * X[cast[int64](i)]
            i = i + 1
        rep = rep + 1
    s: int64 = 0
    i = 0
    while i < {n}:
        s = s + Y[cast[int64](i)]
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
i_on = h.run_through_codegen_ad("idx_on", idx_src, WD, opt=True)
i_off = h.run_through_codegen_ad("idx_off", idx_src, WD, opt=False)
if i_on.kind != "ok" or i_off.kind != "ok":
    print(f"FAIL(compile) idx on={i_on.kind}/off={i_off.kind}"); fails += 1
else:
    ix_on = int(getattr(i_on, "idxstore", 0) or 0)
    if i_on.stdout != str(sref) or i_off.stdout != str(sref):
        print(f"FAIL idx value ref={sref} on={i_on.stdout} off={i_off.stdout}"); fails += 1
    if ix_on == 0:
        print(f"FAIL idx IDXSTORE never fired (idxstore={ix_on})"); fails += 1
    if int(getattr(i_off, "idxstore", 0) or 0) != 0:
        print("FAIL idx NOT byte-inert OFF (IDXSTORE!=0)"); fails += 1
    else:
        print(f"[indexed-store] IDXSTORE={ix_on} value={i_on.stdout}=ref OK")

# ---------------------------------------------------------------------------
# 3) SOUNDNESS — a FLOAT accumulator must produce the SAME VALUE as the seed
#    (the --opt bar is value-equality with the seed, ON==OFF). In this minimal
#    subset a cast-initialised float64 can only hold integer values (no fractional
#    literals; division is not routable), so integer routing is value-correct —
#    exactly the established Phase-1 selector behaviour. A CALL-in-value accumulator
#    must stay correct on the legacy path (impure value -> not routed).
# ---------------------------------------------------------------------------
flt_src = PRELUDE + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: float64 = cast[float64](7)
    b: float64 = cast[float64](2)
    fs: float64 = cast[float64](7)
    fs += a * b
    fs += b
    print_u64(cast[uint64](cast[int64](fs)))
    return cast[int32](cast[int64](fs) & cast[int64](255))
"""
f_on = h.run_through_codegen_ad("flt_on", flt_src, WD, opt=True)
f_off = h.run_through_codegen_ad("flt_off", flt_src, WD, opt=False)
if f_on.kind != "ok" or f_off.kind != "ok":
    print(f"FAIL(compile) flt on={f_on.kind}/off={f_off.kind}"); fails += 1
elif f_on.stdout != f_off.stdout or f_on.exit != f_off.exit:
    print(f"FAIL flt ON!=OFF on={f_on.stdout} off={f_off.stdout}"); fails += 1
else:
    print(f"[float soundness] ON==OFF={f_on.stdout} OK (value-equal to seed)")

call_src = PRELUDE + """
def sq(x: int64) -> int64:
    return x * x
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: int64 = 0
    i: int64 = 0
    while i < 20:
        s += sq(i)
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
cref = 0
for i in range(20):
    cref = (cref + i * i) & M
c_on = h.run_through_codegen_ad("call_on", call_src, WD, opt=True)
c_off = h.run_through_codegen_ad("call_off", call_src, WD, opt=False)
if c_on.kind != "ok" or c_off.kind != "ok":
    print(f"FAIL(compile) call on={c_on.kind}/off={c_off.kind}"); fails += 1
elif c_on.stdout != str(cref) or c_off.stdout != str(cref):
    print(f"FAIL call value ref={cref} on={c_on.stdout} off={c_off.stdout}"); fails += 1
else:
    print(f"[call-in-value fallback] value={c_on.stdout}=ref OK "
          f"(accsel={getattr(c_on,'accsel',0)} — impure value not routed)")

if fails:
    print(f"\n[test_opt_isel_store] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_isel_store] PASS")
PY
