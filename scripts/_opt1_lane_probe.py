#!/usr/bin/env python3
"""scripts/_opt1_lane_probe.py — is the LEGACY opt1 optimizer lane still wired?

BACKGROUND
  Commit ba2e4bcf (2026-07-21) "retire legacy opt1 — SSA pipeline is the only
  optimizer" DELETED adder/compiler/opt.ad and rewired `--opt` to arm the SSA
  pipeline (identical to ADDER_OPT2=1).  As a side effect the host dump driver
  (tests/fuzz/ad_codegen_dump_driver.ad) no longer calls ra_enable() on the
  CODEGEN path — it is called only in the `--dump-regalloc` ANALYSIS lane — so
  regalloc (`ra_enabled`) is 0 during emission and every codegen lever gated on
  it (BASEHOIST / IDXREG / ISEL / DESTSEL / ACCSEL / ALELIDE / ...) is
  structurally inert, as are the opt1 AST-pass counters (DCE / FOLDS / CSE /
  COPYPROP / LICM / ...), which the driver no longer even emits.

  The ~44 scripts/test_opt_*.sh guards were written against that lane.  They
  still verify CORRECTNESS fine (opt == off == reference in every observed
  failure) but their "the pass FIRED" assertions can never hold while the lane
  is retired.  That is a DELIBERATELY-DISABLED feature, not a broken one.

WHAT THIS PROBE DOES
  Compiles one canary program (a saxpy-shaped multi-use global-array loop plus a
  dead local plus a constant-foldable expression — a shape that fired several
  opt1/codegen levers at once before the retirement) through the host dump
  driver with `--opt` ON, and reports whether ANY legacy lever counter moved.

  Prints exactly one word on stdout:
      active   — at least one legacy counter fired; the guards are meaningful
                 and MUST run (a failure then is a REAL bug).
      retired  — no legacy counter can fire; the guards are testing a subsystem
                 that no longer exists on this lane.
  Diagnostics (the counters seen, and their values) go to stderr.

  Result is CACHED under build/opt1_lane/ keyed by the dump driver's content
  inputs-hash, so re-arming the lane (any compiler/driver edit) invalidates it
  automatically and the battery starts running for real again by itself.
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tests" / "fuzz"))

# Every counter that belonged to the opt1 lane: the AST optimizer's own passes
# plus the regalloc-gated codegen levers.  If the lane is live at least one of
# these moves on the canary.
LEGACY_KEYS = [
    # opt.ad AST passes (no longer emitted by the driver at all)
    "FOLDS", "FFOLD", "CSE", "LOADCSE", "LICM", "DCE", "CONSTBRANCH",
    "COPYPROP",
    # regalloc(ra_enabled)-gated codegen levers
    "DESTSEL", "ACCSEL", "IDXSTORE", "IDXSEL", "CALLARG", "SPINELEAF",
    "STRENGTHRED", "ISEL", "VEC", "ALULOAD", "BASEHOIST", "SPLITHOIST",
    "STOREELIM", "PARAMHOME", "ALELIDE", "FPSEL", "IDXREG", "IVSR",
    "RCXCLEAN", "STOREIMM", "IMMFOLD", "IMMALU", "IMULIMM", "CMPJCC",
    "FPMOV", "FPCMP", "CONSTIF", "PARITYMOD",
]

CANARY = """
Y: Array[64, int64]
X: Array[64, int64]

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 24:
        Y[cast[int64](i)] = i * 5 + 1
        X[cast[int64](i)] = i * 3 + 7
        i = i + 1
    a: int64 = 3
    rep: int64 = 0
    while rep < 8:
        i = 0
        while i < 24:
            Y[cast[int64](i)] = Y[cast[int64](i)] + a * X[cast[int64](i)]
            i = i + 1
        rep = rep + 1
    dead: int64 = 12345 * 7 + 11
    s: int64 = 0
    i = 0
    while i < 24:
        s = s + Y[cast[int64](i)]
        i = i + 1
    return cast[int32](s & cast[int64](255))
"""


def probe():
    import ad_codegen_host as h
    import adder_fuzzer as F
    wd = REPO / "build" / "opt1_lane"
    wd.mkdir(parents=True, exist_ok=True)
    src = wd / "canary.ad"
    src.write_text(F.PRELUDE + CANARY)
    # DIFFERENTIAL probe: every opt1 lever documents itself as byte-INERT with
    # --opt off, so the lane is live iff some counter is strictly HIGHER ON than
    # OFF.  Comparing against the OFF baseline (rather than against zero) keeps
    # counters that also tick in plain -O0 codegen from faking an active lane.
    on = h.run_dump(src, opt=True, timeout=120)
    off = h.run_dump(src, opt=False, timeout=120)
    for d, tag in ((on, "on"), (off, "off")):
        if d.status != "ok":
            # A canary that will not even compile tells us nothing about the
            # lane. Report UNKNOWN and fail loudly rather than silently skip.
            print(f"[opt1_lane_probe] canary did not compile ({tag}): "
                  f"{d.status} {getattr(d, 'detail', '')}", file=sys.stderr)
            return None, {}
    # POSITIVE CONTROL.  A probe that only ever observes zeroes could be zero
    # because the canary is degenerate or the manifest parser broke.  The
    # `--dump-regalloc` ANALYSIS lane still calls ra_enable() explicitly, so on
    # this same canary the allocator MUST find promotable locals.  If it does
    # not, the probe is not trustworthy -> return UNKNOWN (tests will NOT skip).
    ra = h.run_regalloc(src, timeout=120)
    if ra.status != "raok" or ra.promotable == 0:
        print("[opt1_lane_probe] POSITIVE CONTROL FAILED: --dump-regalloc "
              f"status={ra.status} promotable={ra.promotable} — probe cannot "
              "distinguish 'lane retired' from 'probe broken'", file=sys.stderr)
        return None, {}
    print(f"[opt1_lane_probe] positive control OK: --dump-regalloc (which does "
          f"call ra_enable) promotes {ra.promotable} locals, {ra.inreg} in "
          f"register — the allocator itself works; it is simply never armed on "
          f"the --opt EMISSION path.", file=sys.stderr)

    fired = {}
    for k in LEGACY_KEYS:
        attr = k.lower()
        v_on = getattr(on, attr, 0)
        v_off = getattr(off, attr, 0)
        if v_on > v_off:
            fired[k] = f"{v_on} (off {v_off})"
    return (len(fired) > 0), fired


def main():
    import ad_codegen_host as h
    h.build_driver()
    key = h._driver_inputs_hash()
    cache = REPO / "build" / "opt1_lane" / f"probe.{key[:16]}.txt"
    if cache.exists():
        sys.stdout.write(cache.read_text().strip() + "\n")
        return 0
    active, fired = probe()
    if active is None:
        return 2
    state = "active" if active else "retired"
    if fired:
        print("[opt1_lane_probe] legacy counters that fired: "
              + ", ".join(f"{k}={v}" for k, v in sorted(fired.items())),
              file=sys.stderr)
    else:
        print("[opt1_lane_probe] no legacy opt1/regalloc counter fired under "
              "--opt (lane retired by ba2e4bcf)", file=sys.stderr)
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(state + "\n")
    print(state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
