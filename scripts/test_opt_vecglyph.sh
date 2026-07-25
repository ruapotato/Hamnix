#!/usr/bin/env bash
# scripts/test_opt_vecglyph.sh — focused, host-only correctness + firing test for
# the native backend's SSE2 AUTO-VECTORIZER *glyph coverage-mask* path
# (codegen.ad try_vectorize_glyph / vec_emit_glyph_loop). This is the anti-aliased
# TEXT / AA-ink loop: a solid opaque ink colour composited over the destination
# through a PER-PIXEL coverage byte (loaded from a second unit-stride pointer):
#     ia  = 255 - cov
#     out = (chan * cov + dst_chan * ia) / 255   (truncating), alpha forced 255
# Armed only under --opt (vec_enable()); OFF by default the loop is emitted by the
# byte-identical scalar path.
#
# WHAT IT PROVES (no QEMU):
#   1. The pass FIRES: the per-pixel coverage blend loop reports VEC>0 under --opt.
#   2. The pass is BIT-EXACT: the glyph blend compiled WITH the vectorizer (--opt)
#      writes a memory image BYTE-IDENTICAL to the SAME blend WITHOUT the
#      vectorizer (--opt --no-vec) AND to the fully-scalar build (--opt OFF),
#      across every 4-pixel remainder (n mod 4 == 0..3), n=0, many ink colours and
#      coverage/dst patterns, and both promoted and unpromoted loop locals. Any
#      wrong lane / per-pixel broadcast / rounding / epilogue corrupts a byte, so
#      the differential checksum is the correctness gate.
#   3. It is BYTE-INERT with --opt OFF (VEC==0).
#
# HOST-ONLY: python3 + as/ld/gcc (the fuzz host harness), x86_64. NO QEMU.
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
opt1_require_lane "test_opt_vecglyph"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_vecglyph"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE

# Fixed 24-pixel (96-byte) dst buffer + 24-byte coverage buffer; glyphrow
# composites the first `npix`.
NPIX_MAX = 24
NBYTES = NPIX_MAX * 4

def dst_byte(i):
    return (i * 37 + 11) & 0xFF

def cov_byte(i):
    # A spread of coverage values including 0 and 255 edges.
    return (i * 61 + 3) & 0xFF

def prog(npix, cr, cg, cb, unpromoted):
    veto = ""
    guard = ""
    if unpromoted:
        veto = """
    sink: uint64 = cast[uint64](&o)
    sink2: uint64 = cast[uint64](&cp)"""
        guard = """
    if sink == 7 and sink2 == 9:
        print_u64(0)"""
    inits = "\n".join(
        f"    buf[{i}] = cast[uint8]({dst_byte(i)})" for i in range(NBYTES))
    cinits = "\n".join(
        f"    cbuf[{i}] = cast[uint8]({cov_byte(i)})" for i in range(NPIX_MAX))
    return PRELUDE + f"""
def glyphrow(base: uint64, cbase: uint64, n: int64,
             cr: uint32, cg: uint32, cb: uint32):
    o: uint64 = base
    cp: uint64 = cbase
    xc: int64 = 0{veto}
    while xc < n:
        cov: uint32 = cast[uint32](cast[Ptr[uint8]](cp)[0])
        ia: uint32 = 255 - cov
        dr: uint32 = cast[uint32](cast[Ptr[uint8]](o)[0])
        dg: uint32 = cast[uint32](cast[Ptr[uint8]](o + 1)[0])
        db: uint32 = cast[uint32](cast[Ptr[uint8]](o + 2)[0])
        cast[Ptr[uint8]](o)[0] = cast[uint8]((cr * cov + dr * ia) / 255)
        cast[Ptr[uint8]](o + 1)[0] = cast[uint8]((cg * cov + dg * ia) / 255)
        cast[Ptr[uint8]](o + 2)[0] = cast[uint8]((cb * cov + db * ia) / 255)
        cast[Ptr[uint8]](o + 3)[0] = 255
        o = o + 4
        cp = cp + 1
        xc = xc + 1{guard}

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    buf: Array[{NBYTES}, uint8]
    cbuf: Array[{NPIX_MAX}, uint8]
{inits}
{cinits}
    glyphrow(cast[uint64](&buf[0]), cast[uint64](&cbuf[0]), {npix},
             cast[uint32]({cr}), cast[uint32]({cg}), cast[uint32]({cb}))
    s: uint64 = 0
    i: int64 = 0
    while i < {NBYTES}:
        s = s + cast[uint64](buf[i]) * cast[uint64](i + 1)
        i = i + 1
    print_u64(s)
    return cast[int32](0)
"""

def ref(npix, cr, cg, cb):
    buf = [dst_byte(i) for i in range(NBYTES)]
    n = max(0, npix)
    for p in range(n):
        o = p * 4
        if o + 3 >= NBYTES:
            break
        cov = cov_byte(p)
        ia = (255 - cov) & 0xFFFFFFFF
        dr, dg, db = buf[o], buf[o + 1], buf[o + 2]
        buf[o] = ((cr * cov + dr * ia) // 255) & 0xFF
        buf[o + 1] = ((cg * cov + dg * ia) // 255) & 0xFF
        buf[o + 2] = ((cb * cov + db * ia) // 255) & 0xFF
        buf[o + 3] = 255
    return sum(buf[i] * (i + 1) for i in range(NBYTES))

# Ink colours (opaque ink — a_eff == cov), include black/white/edge channels.
COLORS = [
    (0xDD, 0xCC, 0xBB), (0xFF, 0xFF, 0xFF), (0x00, 0x00, 0x00),
    (0x12, 0x34, 0x56), (0xA0, 0x50, 0x10), (0x7F, 0x80, 0x01),
]
fails = 0
fired = 0
total = 0
for unpromoted in (False, True):
    for (cr, cg, cb) in COLORS:
        for npix in range(0, 25):
            total += 1
            src = prog(npix, cr, cg, cb, unpromoted)
            tag = f"{npix}_{cr}_{cg}_{cb}_{int(unpromoted)}"
            r_vec = h.run_through_codegen_ad("gv" + tag, src, WD, opt=True)
            r_nov = h.run_through_codegen_ad("gn" + tag, src, WD, opt=True,
                                             no_vec=True)
            r_off = h.run_through_codegen_ad("go" + tag, src, WD, opt=False)
            if r_vec.kind != "ok" or r_nov.kind != "ok" or r_off.kind != "ok":
                print(f"FAIL(compile) {tag} vec={r_vec.kind} nov={r_nov.kind} "
                      f"off={r_off.kind} "
                      f"detail={r_vec.detail or r_nov.detail or r_off.detail}")
                fails += 1
                continue
            exp = str(ref(npix, cr, cg, cb))
            gv = r_vec.stdout.strip()
            gn = r_nov.stdout.strip()
            go = r_off.stdout.strip()
            vc = getattr(r_vec, "vec", 0)
            voff = getattr(r_off, "vec", 0)
            if not (gv == gn == go == exp):
                print(f"FAIL {tag} vec={gv} nov={gn} off={go} exp={exp} VEC={vc}")
                fails += 1
                continue
            if voff != 0:
                print(f"FAIL(byte-inert) {tag} --opt OFF VEC={voff}")
                fails += 1
                continue
            if npix >= 4:
                if vc < 1:
                    print(f"FAIL(no-fire) {tag} VEC=0")
                    fails += 1
                    continue
                fired += 1

print("=" * 62)
print(f"[opt_vecglyph] programs checked: {total}  vectorized (VEC>0): {fired}")
if fails == 0:
    print("[opt_vecglyph] PASS — SSE2 glyph coverage-mask vectorizer fires and is "
          "bit-exact vs --no-vec and scalar (all remainders, many ink colours, "
          "per-pixel coverage, promoted + unpromoted locals), byte-inert --opt OFF")
    sys.exit(0)
print(f"[opt_vecglyph] FAIL — {fails} problem(s)")
sys.exit(1)
PY
