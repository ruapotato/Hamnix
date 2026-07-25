#!/usr/bin/env bash
# scripts/test_opt_loadcse.sh — focused host-only correctness + firing test for
# the cross-statement LOAD-CSE broadening (opt.ad xcse pass, --opt only): a
# redundant integer ARRAY element load `arr[idx]` reuses the value of an earlier
# identical load via a hoisted temp, UNLESS an intervening store / call / name-
# write could alias it. Default-OFF stays byte-identical (this is a --opt arm).
#
# WHAT IT PROVES (no QEMU):
#   1. FIRES: with --opt ON the LOADCSE counter is > 0 on a redundant-load corpus.
#   2. CORRECT + BIT-EXACT: each program's --opt output equals both the reference
#      value AND the --opt-OFF output. A wrong reuse (stale value) would diverge.
#   3. STORE-KILL SOUNDNESS: a load followed by an aliasing store to the SAME
#      array, then a re-load, must NOT be CSE'd (the second load sees the new
#      value). LOADCSE must NOT fire AND the value must be correct. This is the
#      primary soundness gate — a wrong reuse here silently returns stale data.
#   4. FLOAT DECLINE: a float-element array load is NEVER load-CSE'd (the untyped
#      int temp would mis-type the SSE value); value stays correct, LOADCSE quiet.
#
# HOST-ONLY: python3 + as/ld/gcc, x86_64. NO QEMU.
# BUILD HYGIENE: the cached dump driver under build/fuzz_ad_codegen now
# AUTO-INVALIDATES via ad_codegen_host.build_driver()'s inputs-hash stamp, so it
# rebuilds automatically when opt.ad / any compiler source changes. No manual
# `rm -rf build/fuzz_ad_codegen` is needed for correctness.
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
opt1_require_lane "test_opt_loadcse"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

PRELUDE = F.PRELUDE
WD = Path("build/opt_loadcse"); WD.mkdir(parents=True, exist_ok=True)

fails = 0
fired_total = 0
checked = 0

def run_case(name, src, ref, expect_fire):
    global fails, fired_total, checked
    checked += 1
    r_on = h.run_through_codegen_ad(f"lcse_{name}", src, WD, opt=True)
    r_off = h.run_through_codegen_ad(f"lcse_{name}o", src, WD, opt=False)
    if r_on.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) {name} on={r_on.kind}/{r_off.kind} "
              f"detail={r_on.detail or r_off.detail}")
        fails += 1
        return
    on_v = r_on.stdout.strip()
    off_v = r_off.stdout.strip()
    fired = int(getattr(r_on, "loadcse", 0))
    fired_total += fired
    ok = True
    # ref=None: don't assert an absolute value (e.g. float->int cast semantics are
    # a separate confound); the OFF backend defines the oracle and we only require
    # ON==OFF + the firing expectation. The store-kill / decline soundness is
    # proven by ON==OFF (a wrong reuse would diverge) AND the LOADCSE counter.
    if ref is not None and on_v != str(ref):
        print(f"FAIL(value --opt) {name}: got {on_v!r} want {ref!r}")
        ok = False
    if ref is not None and off_v != str(ref):
        print(f"FAIL(value off) {name}: got {off_v!r} want {ref!r}")
        ok = False
    if on_v != off_v:
        print(f"FAIL(on!=off) {name}: on={on_v!r} off={off_v!r}")
        ok = False
    if expect_fire and fired == 0:
        print(f"FAIL(no-fire) {name}: LOADCSE=0, expected the load to be CSE'd")
        ok = False
    if not expect_fire and fired != 0:
        print(f"FAIL(WRONG-FIRE soundness) {name}: LOADCSE={fired}, "
              f"a load that MUST NOT be reused was eliminated")
        ok = False
    if ok:
        print(f"ok {name}: out={on_v} LOADCSE={fired} "
              f"({'fired' if fired else 'quiet'})")
    else:
        fails += 1

# ---- CASE 1: redundant load across statements (MUST fire) ----------------
# g[i] read into two locals in adjacent statements with no intervening store
# to g and no write to i: the second load reuses the first.
G = "g: Array[16, int64]\n"
run_case("redundant_adjacent", PRELUDE + G + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 3
    g[cast[int64](0)] = 10
    g[cast[int64](1)] = 20
    g[cast[int64](2)] = 30
    g[cast[int64](3)] = 40
    a: int64 = g[cast[int64](i)] + 1
    b: int64 = g[cast[int64](i)] + 2
    c: int64 = g[cast[int64](i)] * 2
    print_u64(cast[uint64](a + b + c))
    return 0
""", (40+1)+(40+2)+(40*2), expect_fire=True)

# ---- CASE 2: STORE-KILL soundness (MUST NOT fire) ------------------------
# Load g[i], then an OPAQUE store to g[k] (an index store = hard barrier),
# then re-load g[i]. The reload must NOT reuse the stale value: g[i] may have
# been overwritten (here k==i, so it WAS). Correct answer uses the NEW value.
run_case("store_kill_alias", PRELUDE + G + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 2
    g[cast[int64](2)] = 5
    a: int64 = g[cast[int64](i)] + 100
    g[cast[int64](i)] = 999
    b: int64 = g[cast[int64](i)] + 100
    print_u64(cast[uint64](a + b))
    return 0
""", (5+100)+(999+100), expect_fire=False)

# ---- CASE 3: name-write kill (MUST NOT fire) -----------------------------
# Load g[i], then reassign i, then load g[i]: the address changed, so the
# second load is a DIFFERENT element — no reuse. (ir_uses_name kills the
# available load when i is written.)
run_case("index_name_kill", PRELUDE + G + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    g[cast[int64](0)] = 7
    g[cast[int64](1)] = 11
    a: int64 = g[cast[int64](i)] + 0
    i = 1
    b: int64 = g[cast[int64](i)] + 0
    print_u64(cast[uint64](a + b))
    return 0
""", 7+11, expect_fire=False)

# ---- CASE 4: float-element DECLINE (MUST NOT fire, value correct) --------
# A float64 array element load must never be load-CSE'd (untyped int temp would
# mis-type the SSE value). The transform declines; the value stays correct. We
# reduce the float reads to an INTEGER comparison count so the printed value is a
# clean int (a float->int cast is a separate confound). The two `gf[i] > t`
# compares each read gf[i]; without the float-decline gate a wrong int temp
# would corrupt the second compare.
GF = "gf: Array[16, float64]\n"
run_case("float_elem_decline", PRELUDE + GF + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 1
    gf[cast[int64](1)] = 2.5
    n: int64 = 0
    if gf[cast[int64](i)] > 1.0:
        n = n + 1
    if gf[cast[int64](i)] > 2.0:
        n = n + 10
    if gf[cast[int64](i)] > 9.0:
        n = n + 100
    print_u64(cast[uint64](n))
    return 0
""", None, expect_fire=False)

# ---- CASE 5: nested index in the index expression (MUST fire, correct) ---
# g[ idx[0] ] read twice with idx[0] a load too; outer load shares. Validates
# the load-inside-index descent + kill bookkeeping.
GI = "g: Array[16, int64]\nidx: Array[4, int64]\n"
run_case("nested_index_load", PRELUDE + GI + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    idx[cast[int64](0)] = 4
    g[cast[int64](4)] = 77
    a: int64 = g[cast[int64](idx[cast[int64](0)])] + 1
    b: int64 = g[cast[int64](idx[cast[int64](0)])] + 3
    print_u64(cast[uint64](a + b))
    return 0
""", (77+1)+(77+3), expect_fire=True)

print(f"\n[test_opt_loadcse] cases={checked} fails={fails} "
      f"LOADCSE-fired-total={fired_total}")
sys.exit(1 if fails else 0)
PY
rc=$?
if [ "$rc" = "0" ]; then
    echo "[test_opt_loadcse] PASS"
else
    echo "[test_opt_loadcse] FAIL"
fi
exit "$rc"
