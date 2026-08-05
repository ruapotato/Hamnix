#!/usr/bin/env bash
# scripts/test_ssa_bailsite_66_split.sh — the SBR_NONPROMOTABLE "site 66" bucket
# must stay SPLIT into its two unrelated causes.
#
# WHY THIS GATE EXISTS (2026-08-04):
#   ssa_name_promotable() returns 0 for two things that have nothing to do with
#   each other, and the old blended site 66 reported them as one number:
#
#     * cl_set[nid]      -- the address genuinely escaped (`&x`, or a store
#                           through an index/member/deref lvalue based on x).
#                           This local really would need a stack slot.  => 104
#     * nm_slotread[nid] -- a legacy REGISTER-ALLOCATOR write-through hint set by
#                           cfg.ad's sr_mark when a name is the BASE of an index
#                           `p[i]` or the callee of an indirect call.  Nothing
#                           takes an address here; it only ever meant "the -O0
#                           emitter re-loads this slot".  => 105
#
#   Blended, site 66 was 36.9% of all whole-tree bails — the single largest
#   bucket — and was briefed as "address-taken scalar locals; fix = give the
#   native backend alloca lowering".  Split, it is 13.7% address-taken (104) and
#   23.1% legacy-hint (105), so nearly two thirds of the "alloca gap" was never
#   an alloca problem at all.
#
#   The counterfactual then retired the target outright: lifting EITHER half
#   (measured separately, whole tree, 21278 functions) admitted exactly ZERO
#   additional functions — 7798 accepted / 36.65% before and after — because
#   those functions all fail an index/deref/memory gate a few lines later.  A
#   bail-site histogram counts which gate fires FIRST, not what would unlock a
#   function.  See the header of scripts/ssa_subset_census.py.
#
# WHY IT RUNS WITH --ssa-no-memnative (2026-08-05):
#   The native local-memory model has since LANDED (ssa_mem_native, commit
#   1c6f6db9), and it MODELS both halves instead of bailing — so on the shipped
#   subset sites 104 and 105 are near-empty and this gate would be vacuous.  The
#   sub-attribution is still the evidence that site 66 was one name for two
#   unrelated constructs, and it is still live code (it fires for any lane that
#   arms neither memory model), so the gate pins it in the configuration where
#   it is observable: the census lift lever --ssa-no-memnative, which turns the
#   native memory model back off.  Re-blending 104/105 into one site would make
#   this gate RED.
#
# WHAT IT PROVES (host-only, no QEMU, seconds):
#   1. With the memory model OFF, an address-taken scalar local bails at 104,
#      never at the blended 66.
#   2. A pointer used only as an INDEX BASE bails at 105 — it is not
#      address-taken, and must not be reported as such.
#   3. Site 66 is retired: nothing bails there any more.
#   4. Both still fall back cleanly (STATUS ssaok, counted as fallback), never
#      hard-fail.
#   5. CENSUS-FIDELITY COROLLARY: the SAME fixtures, run WITHOUT the lever (the
#      default = the shipped --opt subset), are ACCEPTED.  That is the direct
#      check that the analysis lane arms ssa_mem_native exactly as
#      ssa_emit_program does — if the census lane ever drifts back to
#      mem_native=0 it would silently understate the subset by ~24 points, the
#      same class of measuring bug as the glob_count one.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import sys, subprocess
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

h.build_driver()
DRV = str(h.DRIVER_ELF)
WD = Path("build/ssa_bailsite66_split"); WD.mkdir(parents=True, exist_ok=True)

def run(name, src, args=("--ssa-no-memnative",)):
    p = WD / (name + ".ad")
    p.write_text(src)
    r = subprocess.run([DRV, "--dump-ssa", *args, str(p)], capture_output=True,
                       text=True, timeout=300)
    if "AC_DUMP_END" not in r.stdout:
        raise SystemExit(f"FAIL {name}: driver produced no dump\n"
                         f"{r.stdout}\n{r.stderr}")
    sites, acc, fb = {}, 0, 0
    for line in r.stdout.splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "SSA_ACCEPTED":
            acc = int(f[1])
        elif f[0] == "SSA_FALLBACK":
            fb = int(f[1])
        elif f[0] == "SSA_BAILSITE":
            sites[int(f[1])] = int(f[2])
    return acc, fb, sites, r.stdout

fails = []

FIXTURES = []


def expect(name, src, want_site):
    FIXTURES.append((name, src))
    acc, fb, sites, out = run(name, src)
    if sites.get(want_site, 0) < 1:
        fails.append(f"{name}: wanted a bail at site {want_site}, "
                     f"got sites={sites} (accepted={acc} fallback={fb})")
        return
    if sites.get(66, 0) != 0:
        fails.append(f"{name}: site 66 is RETIRED but got {sites[66]} bails "
                     f"there — the split was reverted or bypassed")
        return
    # an SSA bail must be a clean fallback, never a hard failure
    if "STATUS ssaok" not in out:
        fails.append(f"{name}: bail did not fall back cleanly:\n{out}")
        return
    print(f"  ok {name}: sites={sites} accepted={acc} fallback={fb}")

# 1. genuinely address-taken scalar local -> 104
expect("addr_taken", """
def sink(p: Ptr[uint64]) -> uint64:
    return 1


def f(x: uint64) -> uint64:
    t: uint64 = x + 5
    return sink(&t)
""", 104)

# 2. pointer used ONLY as an index base -> 105.  `p` is a plain param; its
#    address is never taken.  Reporting this as "address-taken" is what made the
#    site-66 bucket unactionable.
expect("index_base", """
def f(p: Ptr[uint64], i: uint64) -> uint64:
    return p[i] + 1
""", 105)

# 3. a store THROUGH a deref lvalue escapes the base -> 104, not 105.
expect("store_through_ptr", """
def f(p: Ptr[uint64], v: uint64) -> uint64:
    p[0] = v
    return 1
""", 104)

# 4. CENSUS FIDELITY: without the lever (i.e. the shipped --opt subset, where
#    ssa_mem_native is armed) every one of those fixtures is ACCEPTED -- the
#    landed memory model models exactly what 104/105 used to bail on.  This is
#    what makes the whole-tree census read 61% and not 37%; if the analysis lane
#    ever stops mirroring ssa_emit_program, this assertion goes RED.
for name, src in FIXTURES:
    acc, fb, sites, out = run(name + "_shipped", src, args=())
    if fb != 0 or sites:
        fails.append(f"{name}: with the SHIPPED subset (ssa_mem_native armed) "
                     f"expected 0 fallbacks and no bails, got fallback={fb} "
                     f"sites={sites} -- the census lane no longer mirrors "
                     f"ssa_emit_program")
    else:
        print(f"  ok {name} (shipped subset): accepted={acc} fallback=0")

if fails:
    print("FAIL test_ssa_bailsite_66_split:")
    for x in fails:
        print("  " + x)
    sys.exit(1)
print("PASS test_ssa_bailsite_66_split")
PY
