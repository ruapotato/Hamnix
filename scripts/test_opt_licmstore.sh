#!/usr/bin/env bash
# scripts/test_opt_licmstore.sh — focused, host-only correctness + firing guard
# for the INDEXED-STORE LICM RELAXATION (opt.ad licm_record_assign_target +
# licm_fn_has_addr / licm_addr_scan_block). Armed only under --opt.
#
# THE LEVER: a loop-invariant PURE scalar subexpression (a BINOP over named
# scalars + constants, NO memory-read leaf — the ir_tree_has_leaf gate) is
# hoisted OUT of a loop even when that loop also performs an INDEXED/MEMBER store
# (`arr[i] = ...`). The old LICM bailed (licm_giveup) on ANY non-ident store
# target, which defeated the whole point of the licm.ad benchmark (`a*a`,
# `a*a+b`, `a*3-7` recomputed every inner iteration because the loop also stores
# to bucket[slot]). The store writes array/aggregate memory, disjoint from a
# scalar candidate's leaves, so — PROVIDED the function takes NO address (`&x`
# nowhere, so no pointer can name a local scalar) — the store cannot change any
# candidate and the hoist is sound.
#
# WHAT IT PROVES (no QEMU):
#   1. ROUTED — an invariant `a*b` accumulated in a loop that ALSO stores to a
#      global array HOISTS (LICM > 0), the value is EXACTLY the reference AND
#      equals the --opt-OFF value, and the lever is byte-INERT OFF (LICM == 0).
#   2. SOUNDNESS GATE — an ADDRESS-TAKEN function whose loop stores THROUGH a
#      pointer that ALIASES a scalar read in the loop must NOT hoist (LICM == 0)
#      and must stay correct. This is the guard that keeps a pointer store from
#      sinking a live value; dropping the gate makes this program miscompile
#      (60 vs 24) — exactly the deliberate-break check the fuzzer corpus asserts.
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
opt1_require_lane "test_opt_licmstore"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_licmstore"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
M = (1 << 64) - 1
fails = 0

# ---------------------------------------------------------------------------
# 1) ROUTED: invariant (a*b) hoisted out of a loop that ALSO stores to a global
#    array. Must fire (LICM>0), be correct, match OFF, and be byte-inert OFF.
# ---------------------------------------------------------------------------
a, b, n = 6, 7, 2000
ref = (a * b * n) & M
routed = PRELUDE + f"""
lg_ls: Array[8, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: uint64 = cast[uint64]({a})
    b: uint64 = cast[uint64]({b})
    i: uint64 = cast[uint64](0)
    while i < cast[uint64]({n}):
        g_accum = g_accum + (a * b)
        lg_ls[cast[int64](i & cast[uint64](7))] = cast[int64](i)
        i = i + cast[uint64](1)
    print_u64(g_accum)
    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))
"""
r_on = h.run_through_codegen_ad("ls_routed_on", routed, WD, opt=True)
r_off = h.run_through_codegen_ad("ls_routed_off", routed, WD, opt=False)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) routed on={r_on.kind}/off={r_off.kind}"); fails += 1
else:
    lc_on = int(getattr(r_on, "licm", 0) or 0)
    lc_off = int(getattr(r_off, "licm", 0) or 0)
    if r_on.stdout != str(ref) or r_off.stdout != str(ref):
        print(f"FAIL routed value ref={ref} on={r_on.stdout} off={r_off.stdout}"); fails += 1
    if lc_on == 0:
        print(f"FAIL routed LICM never fired across the store (lc_on={lc_on})"); fails += 1
    if lc_off != 0:
        print(f"FAIL routed NOT byte-inert OFF (LICM={lc_off})"); fails += 1
    if fails == 0:
        print(f"[routed] LICM={lc_on} value={r_on.stdout}=ref, OFF inert OK")

# ---------------------------------------------------------------------------
# 2) SOUNDNESS GATE: address-taken alias. p = &x; the loop stores through p
#    (aliasing x) and reads x in an invariant. Must NOT hoist (LICM==0) and must
#    be correct. Dropping the licm_fn_has_addr gate would wrongly hoist x*three
#    above the aliasing store (stale x) -> 60 instead of 24.
# ---------------------------------------------------------------------------
x0, three, n = 5, 3, 4
x = x0; acc = 0
for i in range(n):
    acc = (acc + x * three) & M
    x = i
ref2 = acc
alias = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    x: uint64 = cast[uint64]({x0})
    three: uint64 = cast[uint64]({three})
    p: Ptr[uint64] = &x
    i: uint64 = cast[uint64](0)
    while i < cast[uint64]({n}):
        g_accum = g_accum + (x * three)
        p[cast[int64](0)] = i
        i = i + cast[uint64](1)
    print_u64(g_accum)
    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))
"""
a_on = h.run_through_codegen_ad("ls_alias_on", alias, WD, opt=True)
a_off = h.run_through_codegen_ad("ls_alias_off", alias, WD, opt=False)
if a_on.kind != "ok" or a_off.kind != "ok":
    print(f"FAIL(compile) alias on={a_on.kind}/off={a_off.kind}"); fails += 1
else:
    la_on = int(getattr(a_on, "licm", 0) or 0)
    if a_on.stdout != str(ref2) or a_off.stdout != str(ref2):
        print(f"FAIL alias value ref={ref2} on={a_on.stdout} off={a_off.stdout}"); fails += 1
    if la_on != 0:
        print(f"FAIL alias WRONGLY hoisted past an aliasing pointer store "
              f"(LICM={la_on}) — the address-of gate is not holding"); fails += 1
    if fails == 0:
        print(f"[alias gate] LICM={la_on} (no hoist) value={a_on.stdout}=ref OK")

if fails:
    print(f"\n[test_opt_licmstore] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_licmstore] PASS")
PY
