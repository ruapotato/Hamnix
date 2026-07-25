#!/usr/bin/env bash
# scripts/test_opt_liverange.sh — host-only correctness + STRUCTURAL guard for the
# native optimizer's LIVE-RANGE-HOLE (idle-gap) analysis (cfg.ad, the keystone for
# live-range splitting toward gcc-parity codegen).
#
# WHAT THE ANALYSIS IS
#   The single-interval liveness model ([lr_start,lr_end)) says a value occupies
#   its register CONTINUOUSLY from first to last access — over-stating occupancy.
#   A value can be LIVE across a stretch (its value is carried, needed later) yet
#   never ACCESSED there: its register sits idle. matmul's checksum accumulator
#   `acc` (written at the reps-loop top, read in the later p-loop) is idle across
#   the entire 39M-iteration k-loop, pinning %r15 uselessly. lr_build_holes()
#   computes, per promotable name, the maximal ACCESS-FREE runs INTERIOR to its
#   interval (idle-gaps / "live-range holes"), annotated with loop-nesting hotness;
#   a gap hotter than the value's own accesses is a live-range SPLIT CANDIDATE.
#   PURE ANALYSIS — it changes NO allocation today (codegen stays byte-identical);
#   it is the foundation a future codegen splitter + base-hoist pass consumes.
#
# WHAT THIS GUARD PROVES (no QEMU; python3 + as/ld + objdump, x86_64):
#   A. FIRES + CORRECT SHAPE — a matmul-shape value that is dead-in-the-inner-loop
#      but live-after IS reported a split candidate, with a gap at the INNER loop's
#      depth (hotter than its own accesses). The real matmul kernel's `acc`/`reps`
#      are both candidates with a depth-4 gap (the k-loop).
#   B. SAFETY — a value ACCESSED inside the inner loop is NOT a split candidate
#      (splitting a still-accessed value would be a miscompile; the analysis must
#      never flag it). This is the "a LIVE-in-loop value must NOT split" invariant.
#   C. STRUCTURAL SOUNDNESS — over nested-loop + call-crossing shapes the hole
#      validator (lr_validate_holes: gaps interior, disjoint, ascending, and
#      ACCESS-FREE) passes (cfgok).
#   D. DELIBERATE BREAK — arming --holes-break (corrupt a gap to swallow its
#      right-bracket access) is CAUGHT by the validator (cfgfail code=17).
#   E. VALUE CORRECTNESS — every shape compiles+runs through codegen.ad with the
#      optimizer ON and OFF and matches the Python oracle (the analysis, being
#      pure, must not perturb output).
#
# HOST-ONLY. NO QEMU.
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
opt1_require_lane "test_opt_liverange"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_liverange"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = Path("tests/bench/opt/_prelude.ad").read_text()
U64 = (1 << 64) - 1
fails = 0

def fail(msg):
    global fails
    fails += 1
    print(f"  FAIL: {msg}")

def build(name, kernel):
    src = WD / f"{name}.ad"
    src.write_text(PRELUDE + "\n" + kernel)
    return src

def check_correct(name, src, expected):
    """opt ON and OFF both == expected (analysis is pure, must not perturb)."""
    ok = True
    for opt in (False, True):
        r = h.run_through_codegen_ad(name + ("_on" if opt else "_off"),
                                     (WD / f"{name}.ad").read_text(), WD, opt=opt)
        if r.kind != "ok":
            fail(f"{name}: codegen.ad kind={r.kind} opt={opt} ({r.detail[:120]})")
            ok = False; continue
        got = r.stdout.strip()
        if got != str(expected):
            fail(f"{name}: opt={opt} stdout={got!r} expected={expected}")
            ok = False
    if ok:
        print(f"  OK  correctness {name} == {expected} (opt ON+OFF)")
    return ok

# ---------------------------------------------------------------------------
# Shape 1: matmul-shape dead-in-inner-loop-but-live-after.
#   `acc` and `r` are written/read only OUTSIDE the k-loop -> idle across it ->
#   SPLIT CANDIDATES. `s` is accessed INSIDE the k-loop -> NOT a candidate.
# ---------------------------------------------------------------------------
GINIT = """G: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 64:
        G[cast[int64](i)] = i * 3
        i = i + 1
"""
SHAPE1 = GINIT + """    acc: int64 = 0
    r: int64 = 0
    while r < 20:
        s: int64 = 0
        k: int64 = 0
        while k < 64:
            s = s + G[cast[int64](k)]
            k = k + 1
        acc = acc + s
        r = r + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & 255)
"""
# oracle
G = [i * 3 for i in range(64)]
acc = 0
for _ in range(20):
    s = sum(G)
    acc += s
EXP1 = acc & U64
build("lrh_shape1", SHAPE1)
check_correct("lrh_shape1", None, EXP1)
c1 = h.run_holes_over_body("lrh_shape1", (WD / "lrh_shape1.ad").read_text(), WD)
if "acc" not in c1:
    fail(f"shape1: `acc` not a split candidate (cands={list(c1)})")
elif not any(g[2] >= 2 and g[2] > g[3] for g in c1["acc"]):
    fail(f"shape1: `acc` gaps not hotter than accesses: {c1['acc']}")
else:
    print(f"  OK  shape1 `acc` split candidate, gaps={c1['acc']}")
if "r" not in c1:
    fail(f"shape1: reps-counter `r` not a split candidate (cands={list(c1)})")
else:
    print(f"  OK  shape1 `r` split candidate, gaps={c1['r']}")
if "s" in c1:
    fail(f"shape1: `s` (accessed in k-loop) WRONGLY flagged candidate: {c1['s']}")
else:
    print("  OK  shape1 `s` (k-loop-accessed) correctly NOT a candidate")

# ---------------------------------------------------------------------------
# Shape 2 (SAFETY): the accumulator is ACCESSED inside the inner loop, so it has
# NO idle-gap over that loop and MUST NOT be a split candidate.
# ---------------------------------------------------------------------------
SHAPE2 = GINIT + """    tot: int64 = 0
    r: int64 = 0
    while r < 20:
        k: int64 = 0
        while k < 64:
            tot = tot + G[cast[int64](k)]
            k = k + 1
        r = r + 1
    print_u64(cast[uint64](tot))
    return cast[int32](tot & 255)
"""
tot = 0
for _ in range(20):
    for k in range(64):
        tot += G[k]
EXP2 = tot & U64
build("lrh_shape2", SHAPE2)
check_correct("lrh_shape2", None, EXP2)
c2 = h.run_holes_over_body("lrh_shape2", (WD / "lrh_shape2.ad").read_text(), WD)
if "tot" in c2:
    fail(f"shape2: `tot` accessed IN the inner loop WRONGLY a candidate: {c2['tot']}")
else:
    print("  OK  shape2 `tot` (live-in-loop) correctly NOT a split candidate")

# ---------------------------------------------------------------------------
# Shape 3 (call-crossing + nested): a helper call after the inner loop; acc spans
# a call. Just assert structural soundness + correctness.
# ---------------------------------------------------------------------------
SHAPE3 = """G: Array[64, int64]
def bump(x: int64) -> int64:
    return x + 1
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 64:
        G[cast[int64](i)] = i * 2
        i = i + 1
    acc: int64 = 0
    r: int64 = 0
    while r < 15:
        s: int64 = 0
        k: int64 = 0
        while k < 64:
            s = s + G[cast[int64](k)]
            k = k + 1
        acc = acc + bump(s)
        r = r + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & 255)
"""
G2 = [i * 2 for i in range(64)]
acc = 0
for _ in range(15):
    acc += sum(G2) + 1
EXP3 = acc & U64
build("lrh_shape3", SHAPE3)
check_correct("lrh_shape3", None, EXP3)
# structural: the CFG lane (which builds+validates holes) must report cfgok.
r3 = h.run_cfg_over_body("lrh_shape3", (WD / "lrh_shape3.ad").read_text(), WD)
if r3.status != "cfgok":
    fail(f"shape3: CFG/holes validation status={r3.status} ({r3.detail})")
else:
    print(f"  OK  shape3 CFG+holes validate (holes={r3.holes}, "
          f"cands={r3.split_cands}, maxdepth={r3.hole_maxdepth})")

# ---------------------------------------------------------------------------
# D. DELIBERATE BREAK: arm --holes-break so a gap swallows its right-bracket
# access; the hole validator (access-free invariant) MUST catch it -> cfgfail 17.
# ---------------------------------------------------------------------------
rb = h.run_cfg_over_body("lrh_shape1", (WD / "lrh_shape1.ad").read_text(), WD,
                         holes_break=True)
if rb.status == "cfgfail" and "code=17" in rb.detail:
    print(f"  OK  deliberate break CAUGHT: {rb.detail}")
else:
    fail(f"deliberate break NOT caught: status={rb.status} detail={rb.detail!r}")

# ---------------------------------------------------------------------------
# A(real): the ACTUAL matmul bench kernel — `acc` and `reps` are split candidates
# with a depth-4 gap (the k-loop), exactly the register-pressure relief a splitter
# would exploit to hoist the &A/&B bases.
# ---------------------------------------------------------------------------
MM = Path("tests/bench/opt/matmul.ad").read_text()
mm_src = WD / "lrh_matmul.ad"
mm_src.write_text(PRELUDE + "\n" + MM)
cmm = h.run_holes(mm_src)
have = set(cmm)
need = {"acc", "reps"}
if not need.issubset(have):
    fail(f"matmul: missing split candidates {need - have} (have {have})")
else:
    maxd = max(g[2] for n in need for g in cmm[n])
    if maxd < 4:
        fail(f"matmul: candidate gap max depth {maxd} < 4 (k-loop nesting)")
    else:
        print(f"  OK  matmul acc={cmm['acc']} reps={cmm['reps']} (k-loop depth 4)")

# A(real, TWO splits): with the IVSR bare-ident stride-temp dedup (`k*N+j` no
# longer mints a duplicate `r11=N` register), `reps` becomes register-resident
# alongside `acc` — so BOTH are split candidates whose k-loop-covering holes the
# splitter borrows, hoisting BOTH the `&A` AND the `&B` base out of the 39M-iter
# k-loop. Lock in splithoist>=2 (a regression to 1 = the 2nd base recompute
# returned). Correctness (ON==OFF==oracle) is asserted by the bench + fuzzer.
mm_body = (WD / "lrh_matmul.ad").read_text()
r_mm_on = h.run_through_codegen_ad("lrh_matmul_on", mm_body, WD, opt=True)
r_mm_off = h.run_through_codegen_ad("lrh_matmul_off", mm_body, WD, opt=False)
if r_mm_on.kind != "ok" or r_mm_off.kind != "ok":
    fail(f"matmul: codegen kind on={r_mm_on.kind} off={r_mm_off.kind}")
elif r_mm_on.stdout.strip() != r_mm_off.stdout.strip():
    fail(f"matmul: ON={r_mm_on.stdout.strip()} != OFF={r_mm_off.stdout.strip()}")
elif getattr(r_mm_on, "splithoist", 0) < 2:
    fail(f"matmul: expected splithoist>=2 (both &A+&B), got "
         f"{getattr(r_mm_on,'splithoist',0)} — r11=N dedup / 2nd split regressed")
else:
    print(f"  OK  matmul TWO-base split (splithoist={r_mm_on.splithoist}) "
          f"ON==OFF=={r_mm_on.stdout.strip()}")

# ===========================================================================
# THE SPLITTER (codegen consumes lr_is_split_candidate) — the measured win.
# ===========================================================================
# A matmul-shape kernel over a GLOBAL array: `acc` is idle across the doubly-nested
# i/k loop that reads Gx (its register sits idle over the hottest loop). The codegen
# splitter SPILLS acc before the nest, BORROWS its freed callee-saved register to
# hold Gx's loop-invariant base (removing the per-inner-iteration `lea Gx(%rip)`),
# and RELOADS acc after. A leading FILL loop (also a nested-loop + global-array
# shape, but OUTSIDE acc's live interval, where acc's register is reused by a fill
# temp) is the exact case the hole-COVERAGE gate must reject — the deliberate break
# removes that gate and MUST miscompile.
SPLIT = """Gx: Array[64, int64]
Cx: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    f: int64 = 0
    while f < 8:
        g: int64 = 0
        while g < 8:
            Gx[cast[int64](f * 8 + g)] = (f * 7 + g * 3)
            g = g + 1
        f = f + 1
    acc: int64 = 0
    reps: int64 = 0
    while reps < 5:
        i: int64 = 0
        while i < 8:
            s: int64 = 0
            k: int64 = 0
            while k < 8:
                s = s + Gx[cast[int64](k)]
                k = k + 1
            Cx[cast[int64](i)] = s
            i = i + 1
        p: int64 = 0
        while p < 8:
            acc = acc + Cx[cast[int64](p)]
            p = p + 1
        reps = reps + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & 255)
"""
_arr = [0]*64
for f in range(8):
    for g in range(8):
        _arr[f*8+g] = f*7+g*3
_cx = [0]*8
_acc = 0
for _r in range(5):
    for _i in range(8):
        _cx[_i] = sum(_arr[k] for k in range(8))
    for _p in range(8):
        _acc += _cx[_p]
EXP_SPLIT = _acc & U64
build("lrh_split", SPLIT)
# F. SPLITTER FIRES + is CORRECT. run opt ON and read SPLITHOIST; also ON==OFF==oracle.
r_off = h.run_through_codegen_ad("lrh_split_off", (WD/"lrh_split.ad").read_text(), WD, opt=False)
r_on  = h.run_through_codegen_ad("lrh_split_on",  (WD/"lrh_split.ad").read_text(), WD, opt=True)
if r_off.kind != "ok" or r_on.kind != "ok":
    fail(f"split: codegen kind off={r_off.kind} on={r_on.kind}")
else:
    if r_off.stdout.strip() != str(EXP_SPLIT) or r_on.stdout.strip() != str(EXP_SPLIT):
        fail(f"split: value off={r_off.stdout.strip()} on={r_on.stdout.strip()} exp={EXP_SPLIT}")
    elif getattr(r_on, "splithoist", 0) < 1:
        fail(f"split: SPLITTER DID NOT FIRE (splithoist={getattr(r_on,'splithoist',0)})")
    else:
        print(f"  OK  splitter fires (splithoist={r_on.splithoist}) + correct "
              f"ON==OFF==oracle=={EXP_SPLIT}")

# G. DELIBERATE BREAK — arm --split-break so the splitter SKIPS the hole-coverage
# soundness gate: it borrows acc's register for the FILL loop (outside acc's gap,
# where the register holds a live fill temp) -> the value is clobbered -> the result
# MUST diverge (wrong checksum or a crash). Proves the coverage gate is what makes
# the splitter sound (mirrors the analysis's --holes-break above, at codegen level).
r_brk = h.run_through_codegen_ad("lrh_split_brk", (WD/"lrh_split.ad").read_text(),
                                 WD, opt=True, split_break=True)
if r_brk.kind == "ok" and r_brk.stdout.strip() == str(EXP_SPLIT):
    fail(f"split: DELIBERATE BREAK NOT caught — still correct ({r_brk.stdout.strip()})")
else:
    detail = r_brk.stdout.strip() if r_brk.kind == "ok" else f"kind={r_brk.kind}"
    print(f"  OK  deliberate split-break CAUGHT (diverged: {detail} != {EXP_SPLIT})")

print()
if fails:
    print(f"test_opt_liverange: FAIL ({fails} failure(s))")
    sys.exit(1)
print("test_opt_liverange: PASS")
PY
