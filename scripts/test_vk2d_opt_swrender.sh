#!/usr/bin/env bash
# scripts/test_vk2d_opt_swrender.sh — QEMU-free investigation gate proving the
# SSE2 auto-vectorizer (codegen.ad try_vectorize_{fill,blend,glyph}) FIRES on the
# REAL, canonicalized lib/vk/vk_2d.ad SW-rasterizer hot loops and is BYTE-EXACT.
#
# Unlike test_opt_vec{fill,blend,glyph}.sh (which use hand-copied canonical loop
# snippets), this compiles the ACTUAL lib/vk/vk_2d.ad source through the codegen
# host and drives fill_rect / fill_rect_alpha / cov_mask, proving:
#   1. The three hot loops are in the canonical branch-free form the vectorizer
#      matches — VEC>0 fires under --opt on the shipped source.
#   2. --opt is BYTE-IDENTICAL to --opt --no-vec and to the no-opt production
#      build (the SW-render path is NOT miscompiled under --opt): the vk2d SW
#      oracle checksum matches across all three.
#   3. RGB output is byte-identical across dst-alpha={255, varied} (the cov==0
#      alpha-write of the canonical glyph form only touches the alpha byte, which
#      the real scanout target always holds at 255).
# HOST-ONLY: python3 + as/ld, x86_64. NO QEMU.
#
# 2026-07-31 — VERDICT ON A RED: GATE ROT, not a broken optimization.
# Claim 1 (VEC>=3) failed with VEC=0. lib/vk/vk_2d.ad has not been touched since
# this gate landed (3b9cc5b2 is the SAME commit), and try_vectorize_{fill,blend,
# glyph} are still wired into gen_while. What changed is underneath both: commit
# ba2e4bcf (2026-07-21) retired the legacy opt1 lane, so `--opt` arms the SSA
# pipeline and NO opt1 counter can move. Its three sibling gates
# (test_opt_vec{torfill,blend,glyph}.sh) were taught to skip through
# scripts/lib_opt1_lane.sh on 2026-07-25; this one was missed because its name
# does not match `test_opt_vec*`, and it then sat red in a denominator nobody
# was sweeping.
#
# It is NOT skipped wholesale. Claims 2 and 3 are pure CORRECTNESS (the shipped
# SW rasterizer is not miscompiled under --opt, and RGB is inert on cov==0
# cells) — they observe something real whether or not the lane is armed, and
# they still FAIL the gate. Only the "the vectorizer fired" counter assertion is
# conditional, and it re-arms itself the moment the probe reports the lane
# active again (the probe is content-hash cached against the dump driver, so any
# compiler edit re-probes).
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

source "$(dirname "${BASH_SOURCE[0]}")/lib_opt1_lane.sh"
OPT1_LANE="$(opt1_lane_state)"
if [ "$OPT1_LANE" = "retired" ]; then
    echo "SKIPPED-PARTIAL: --opt legacy opt1 lane is RETIRED (ba2e4bcf, 2026-07-21) — the VEC-fired assertion cannot move"
    echo "SKIPPED-REASON: feature intentionally OFF pending the SSA optimizer rewrite; NOT a broken optimization"
    echo "SKIPPED-EVIDENCE: scripts/_opt1_lane_probe.py — no legacy counter is higher with --opt ON than OFF"
    echo "SKIPPED-TRACKING: $OPT1_TRACKING_DOC (docs/adder_ssa_optimizer_design.md)"
    echo "STILL ASSERTED: --opt == --opt --no-vec == no-opt byte-identity, and the cov==0 RGB invariant"
fi
export OPT1_LANE

python3 - <<'PY'
import os, sys
sys.path.insert(0, "tests/fuzz")
# "retired" => the opt1 counters cannot move; the VEC-fired claim is reported
# but not failed. Any other value (active / unknown) asserts it for real, so an
# inconclusive probe never silences the assertion.
LANE = os.environ.get("OPT1_LANE", "unknown")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/vk2d_opt_swrender"); WD.mkdir(parents=True, exist_ok=True)
VK = Path("lib/vk/vk_2d.ad").read_text()
W, Hh, CW, CH = 40, 24, 12, 9
NPX = W * Hh

def driver(alpha255):
    a = "cast[uint8](255)" if alpha255 else "cast[uint8]((i * 17 + 1) & 255)"
    return f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    img: Array[{NPX*4}, uint8]
    cov: Array[{CW*CH}, uint8]
    i: int64 = 0
    while i < {NPX}:
        img[i*4]   = cast[uint8]((i * 37 + 11) & 255)
        img[i*4+1] = cast[uint8]((i * 53 + 7) & 255)
        img[i*4+2] = cast[uint8]((i * 29 + 3) & 255)
        img[i*4+3] = {a}
        i = i + 1
    i = 0
    while i < {CW*CH}:
        cov[i] = cast[uint8]((i * 61 + 3) & 255)
        i = i + 1
    base: uint64 = cast[uint64](&img[0])
    cb: uint64 = cast[uint64](&cov[0])
    vk2d_raster_fill_rect(base, {W}, {Hh}, 2, 1, 20, 10, cast[uint32](0x3366CCFF))
    vk2d_raster_fill_rect_alpha(base, {W}, {Hh}, 5, 3, 22, 12, cast[uint32](0xCC338880))
    vk2d_raster_cov_mask(base, {W}, {Hh}, cb, {CW}, {CH}, 4, 2, cast[uint32](0xE0A040FF))
    vk2d_raster_cov_mask(base, {W}, {Hh}, cb, {CW}, {CH}, -3, -2, cast[uint32](0xFFFFFFFF))
    vk2d_raster_cov_mask(base, {W}, {Hh}, cb, {CW}, {CH}, 33, 18, cast[uint32](0x102030FF))
    s: uint64 = 0
    i = 0
    while i < {NPX*4}:
        s = s + cast[uint64](img[i]) * cast[uint64](i + 1)
        i = i + 1
    print_u64(s)
    return cast[int32](0)
"""

def rgb_only():
    # Sum only RGB bytes (skip byte%4==3) — the alpha byte is deliberately excluded
    # so the framebuffer-agnostic RGB invariant is asserted independent of the
    # canonical glyph form's cov==0 alpha write.
    return f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    img: Array[{NPX*4}, uint8]
    cov: Array[{CW*CH}, uint8]
    i: int64 = 0
    while i < {NPX}:
        img[i*4]   = cast[uint8]((i * 37 + 11) & 255)
        img[i*4+1] = cast[uint8]((i * 53 + 7) & 255)
        img[i*4+2] = cast[uint8]((i * 29 + 3) & 255)
        img[i*4+3] = cast[uint8]((i * 17 + 1) & 255)
        i = i + 1
    i = 0
    while i < {CW*CH}:
        cov[i] = cast[uint8](0)
        if (i % 3) != 0:
            cov[i] = cast[uint8]((i * 61 + 40) & 255)
        i = i + 1
    base: uint64 = cast[uint64](&img[0])
    cb: uint64 = cast[uint64](&cov[0])
    vk2d_raster_cov_mask(base, {W}, {Hh}, cb, {CW}, {CH}, 4, 2, cast[uint32](0xE0A040FF))
    s: uint64 = 0
    i = 0
    while i < {NPX*4}:
        if (i % 4) != 3:
            s = s + cast[uint64](img[i]) * cast[uint64](i + 1)
        i = i + 1
    print_u64(s)
    return cast[int32](0)
"""

def build(seed, body, **kw):
    return h.run_through_codegen_ad(seed, F.PRELUDE + "\n" + VK + "\n" + body, WD, **kw)

fails = 0
for a255 in (True, False):
    tag = "op" if a255 else "va"
    d = driver(a255)
    r_off = build(f"off_{tag}", d, opt=False)
    r_vec = build(f"vec_{tag}", d, opt=True)
    r_nov = build(f"nov_{tag}", d, opt=True, no_vec=True)
    for nm, r in [("no-opt", r_off), ("opt", r_vec), ("opt-no-vec", r_nov)]:
        if r.kind != "ok":
            print(f"FAIL(compile) [{tag}] {nm}: {r.kind} {r.detail}"); fails += 1
    if any(r.kind != "ok" for r in (r_off, r_vec, r_nov)):
        continue
    o, v, n = r_off.stdout.strip(), r_vec.stdout.strip(), r_nov.stdout.strip()
    vc, voff = getattr(r_vec, "vec", 0), getattr(r_off, "vec", 0)
    print(f"[{tag}] dst-alpha={'255' if a255 else 'varied'}: "
          f"no-opt={o} opt={v} opt-no-vec={n} VEC={vc} VEC(off)={voff}")
    if not (o == v == n):
        print(f"  FAIL: --opt diverged from scalar (SW-render miscompile)"); fails += 1
    if vc < 3:
        if LANE == "retired":
            print(f"  NOTE(lane-retired): vectorizer fired on {vc} loops "
                  f"(want >=3 once the lane is re-armed) — not failed")
        else:
            print(f"  FAIL: vectorizer fired on only {vc} loops (want >=3: fill+blend+glyph)"); fails += 1
    if voff != 0:
        print(f"  FAIL: vectorizer not byte-inert with --opt OFF (VEC={voff})"); fails += 1

# RGB-only invariant with forced cov==0 cells over varied dst alpha: RGB must be
# identical scalar-vs-vector (the alpha byte is the only cov==0 difference).
rr = rgb_only()
g_off = build("rgb_off", rr, opt=False)
g_vec = build("rgb_vec", rr, opt=True)
if g_off.kind == "ok" and g_vec.kind == "ok":
    if g_off.stdout.strip() != g_vec.stdout.strip():
        print(f"  FAIL: RGB diverged under --opt (rgb-only, cov==0 cells)"); fails += 1
    else:
        print(f"[rgb] cov==0 cells, RGB-only byte-match scalar==vector: OK")
else:
    print(f"FAIL(compile rgb) off={g_off.kind} vec={g_vec.kind}"); fails += 1

print("=" * 60)
if fails == 0:
    if LANE == "retired":
        print("[vk2d_opt_swrender] PASS (PARTIAL) — real vk_2d SW-render source is "
              "byte-identical under --opt / --opt --no-vec / no-opt and RGB-inert "
              "on cov==0; the VEC-fired claim is dormant while the opt1 lane is "
              "retired")
    else:
        print("[vk2d_opt_swrender] PASS — real vk_2d SW-render loops vectorize under "
              "--opt (fill+blend+glyph fire), byte-identical to scalar, RGB-inert on "
              "cov==0, byte-inert --opt OFF")
    sys.exit(0)
print(f"[vk2d_opt_swrender] FAIL — {fails} problem(s)")
sys.exit(1)
PY
