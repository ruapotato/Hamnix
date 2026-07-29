#!/usr/bin/env python3
"""wpt_reftest_score.py -- score / ratchet the WPT REFTEST lane.

    python3 scripts/wpt_reftest_score.py run.jsonl                       # report
    python3 scripts/wpt_reftest_score.py run.jsonl --baseline B.txt      # regen
    python3 scripts/wpt_reftest_score.py run.jsonl --check-baseline B.txt # gate

THE RATCHET, AND WHY IT GUARDS AN ABSOLUTE COUNT
------------------------------------------------
Same shape as scripts/wpt_baseline.txt: a shrink-only record of what the engine
does NOT pass, plus `#!PASS_FLOOR n` guarding the ABSOLUTE number of PASSes.

The absolute count is load-bearing, and this lane makes the reason especially
concrete. The reported ratio is PASS / (PASS + FAIL) -- NONDISCRIMINATING pairs
are excluded from the denominator on purpose (a pair a null engine would also
pass is not evidence). So the denominator MOVES:

  * teach the engine to honour a property, and a pair that used to be
    NONDISCRIMINATING becomes discriminating. It enters the denominator, very
    likely as a FAIL at first, and the RATIO DROPS while the engine got better.
  * lift the .xht exclusion and ~1,000 tests arrive at once.

A ratio floor would fail on both. An absolute PASS floor cannot: it only ever
asks "are we still passing at least as many real tests as before".

ROW KINDS (TAB-separated)
  <test>\t<verdict>     did NOT pass at baseline (FAIL / NONDISCRIMINATING /
                        ERROR, recorded so the CAUSE is visible in the diff)
  +<test>\tPASS         DID pass at baseline -- the regression set

Recording the passes is what makes a regression decidable. A newly appearing
FAIL row is ambiguous on its own: the test may have regressed, or it may be new
to the manifest. Only a test that was in the pass set and no longer passes
counts as a regression -- and #!PASS_FLOOR catches any genuine loss a second
time regardless.

A pass turning into NONDISCRIMINATING is ALSO a regression: it means the engine
stopped applying the CSS that pair is about, which is exactly the silent
capability loss this lane exists to catch.
"""

import argparse
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wpt_reftest_run as R                                      # noqa: E402

PASS_PREFIX = "+"


def load(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def write_baseline(path, recs, digest, prev=None, allow_loosen=False):
    """Write the baseline. Refuses to LOOSEN a ratchet unless told to.

    `--regen` used to be an unconditional exit-0 that recomputed every marker
    from the current run, so the documented command for banking a fix was also
    a one-step way to bank a REGRESSION -- lowering the pass floor and raising
    the error/nondiscriminating ceilings while the file called itself
    "SHRINK-ONLY". Loosening is now an explicit, separately-named act.
    """
    npass = sum(1 for r in recs if r["verdict"] == "PASS")
    nerr = sum(1 for r in recs if r["verdict"] == "ERROR")
    nnd = sum(1 for r in recs if r["verdict"] == "NONDISCRIMINATING")

    if prev and not allow_loosen:
        loosen = []
        if npass < prev["floor"]:
            loosen.append("PASS_FLOOR %d -> %d" % (prev["floor"], npass))
        if nerr > prev["err_ceiling"]:
            loosen.append("ERROR_CEILING %d -> %d"
                          % (prev["err_ceiling"], nerr))
        if nnd > prev["nd_ceiling"]:
            loosen.append("ND_CEILING %d -> %d" % (prev["nd_ceiling"], nnd))
        if loosen:
            print("[reftest-score] REFUSING to regenerate: that would LOOSEN "
                  "the ratchet:", file=sys.stderr)
            for l in loosen:
                print("    %s" % l, file=sys.stderr)
            print("[reftest-score] The baseline is shrink-only. Either fix the\n"
                  "[reftest-score] regression, or -- if the lane itself changed "
                  "(a new area\n[reftest-score] imported, an exclusion lifted) "
                  "-- say so explicitly with\n"
                  "[reftest-score]   --allow-loosen", file=sys.stderr)
            return None

    with open(path, "w") as f:
        f.write(
            "# scripts/wpt_reftest_baseline.txt -- SHRINK-ONLY record of the WPT\n"
            "# REFTEST lane (tests/wpt/REFTEST_MANIFEST.txt): a test document\n"
            "# compared PIXEL-EXACTLY against its <link rel=\"match\"> reference,\n"
            "# both rendered by our own engine.\n"
            "#\n"
            "# Regenerate with:  bash scripts/test_wpt_reftest_ratchet_host.sh --regen\n"
            "# Regeneration REFUSES to loosen any marker below without\n"
            "# --allow-loosen, so banking a fix cannot silently bank a regression.\n"
            "#\n"
            "# Rows (TAB-separated):\n"
            "#   <test>\\t<verdict>   did NOT pass at baseline\n"
            "#   %s<test>\\tPASS      DID pass at baseline (the regression set)\n"
            "#\n"
            "# Verdicts: PASS / FAIL / NONDISCRIMINATING (a null engine with no CSS\n"
            "# at all would also satisfy the relationship, so a pass there is not\n"
            "# evidence -- excluded from the scored denominator) / ERROR (a document\n"
            "# did not render).\n"
            "#\n"
            "# THE FOUR MARKERS. All are required: a baseline missing one is treated\n"
            "# as unusable rather than defaulting to a value that guards nothing.\n"
            "#\n"
            "# #!PASS_FLOOR guards the ABSOLUTE pass count, not a ratio: the\n"
            "# denominator grows when the engine improves (a NONDISCRIMINATING pair\n"
            "# becomes discriminating) or when an exclusion is lifted, so a real fix\n"
            "# can LOWER the ratio.\n"
            "#\n"
            "# #!ERROR_CEILING -- every vendored document must keep RENDERING. A\n"
            "# change that makes the engine bail turns FAILs into ERRORs, which no\n"
            "# pass floor can see.\n"
            "#\n"
            "# #!ND_CEILING -- the ratchet with teeth while PASS_FLOOR is 0. A pair\n"
            "# goes NONDISCRIMINATING when a null engine with no CSS would satisfy it\n"
            "# too, so pairs MOVING INTO that bucket means the engine stopped applying\n"
            "# the CSS they are about: the pairs leave the scored denominator and both\n"
            "# other markers stay happy. That is the silent capability loss this lane\n"
            "# exists to catch, and only this ceiling catches it.\n"
            "#\n"
            "# #!TREE_SHA256 -- over REFTEST_MANIFEST.txt and every document it\n"
            "# names. Makes \"never edit a vendored test or reference\" enforced rather\n"
            "# than merely stated, and stops rows being deleted from the manifest to\n"
            "# launder a FAIL out of the lane. A real re-import changes it, which is\n"
            "# the point: it forces a deliberate --regen that shows in the diff.\n"
            "#\n"
            "#!PASS_FLOOR %d\n"
            "#!ERROR_CEILING %d\n"
            "#!ND_CEILING %d\n"
            "#!TREE_SHA256 %s\n" % (PASS_PREFIX, npass, nerr, nnd, digest))
        for r in sorted(recs, key=lambda r: r["test"]):
            if r["verdict"] == "PASS":
                f.write("%s%s\tPASS\n" % (PASS_PREFIX, r["test"]))
            else:
                f.write("%s\t%s\n" % (r["test"], r["verdict"]))
    return npass


MARKERS = {"#!PASS_FLOOR": "floor", "#!ERROR_CEILING": "err_ceiling",
           "#!ND_CEILING": "nd_ceiling", "#!TREE_SHA256": "digest"}


def read_baseline(path):
    """-> (info, passing, notpassing) or (None, ...) if a marker is missing.

    Every marker is REQUIRED. Defaulting a missing marker to 0 silently
    disabled the ratchet it belonged to and printed a reassuring
    "PASS n >= floor 0" while guarding nothing -- a lost line in a merge was
    enough.
    """
    info, passing, notpassing = {}, set(), {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#!"):
                parts = line.split(None, 1)
                key = MARKERS.get(parts[0])
                if key is None or len(parts) < 2 or not parts[1].strip():
                    continue
                val = parts[1].strip()
                info[key] = val if key == "digest" else int(val)
                continue
            if not line or line.startswith("#"):
                continue
            if line.startswith(PASS_PREFIX):
                passing.add(line[len(PASS_PREFIX):].split("\t")[0])
            else:
                p = line.split("\t")
                notpassing[p[0]] = p[1] if len(p) > 1 else "?"
    missing = [m for m, k in MARKERS.items() if k not in info]
    if missing:
        print("[reftest-score] baseline %s is missing required marker(s): %s"
              % (path, " ".join(missing)), file=sys.stderr)
        return None, passing, notpassing
    return info, passing, notpassing


def report(recs):
    c = collections.Counter(r["verdict"] for r in recs)
    scored = c["PASS"] + c["FAIL"]
    print("[reftest-score] %d reftests" % len(recs))
    for v in ("PASS", "FAIL", "NONDISCRIMINATING", "ERROR"):
        print("[reftest-score]   %-18s %d" % (v, c[v]))
    if scored:
        print("[reftest-score] %d/%d = %.1f%% of DISCRIMINATING pairs"
              % (c["PASS"], scored, 100.0 * c["PASS"] / scored))
    return c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("jsonl")
    ap.add_argument("--baseline")
    ap.add_argument("--check-baseline")
    ap.add_argument("--allow-loosen", action="store_true",
                    help="permit --baseline to relax a ratchet (a new area was "
                         "imported, or an exclusion was lifted)")
    args = ap.parse_args()

    recs = load(args.jsonl)
    if not recs:
        print("[reftest-score] no records", file=sys.stderr)
        return 2
    c = report(recs)
    digest = R.tree_digest()

    if args.baseline:
        prev = None
        if os.path.isfile(args.baseline):
            prev, _, _ = read_baseline(args.baseline)
        n = write_baseline(args.baseline, recs, digest, prev, args.allow_loosen)
        if n is None:
            return 1
        print("[reftest-score] wrote %s (#!PASS_FLOOR %d)" % (args.baseline, n))
        return 0

    if not args.check_baseline:
        return 0

    info, was_passing, was_notpassing = read_baseline(args.check_baseline)
    if info is None:
        # A baseline we cannot read is not a baseline we may pass against.
        print("[reftest-score]   A missing marker would silently disable the "
              "ratchet it belongs to.\n[reftest-score]   Refusing to score.",
              file=sys.stderr)
        return 125

    now = {r["test"]: r["verdict"] for r in recs}
    was = dict(was_notpassing)
    was.update({t: "PASS" for t in was_passing})
    bad = False
    inconclusive = False

    # ---- the vendored tree must be the tree the baseline was taken on --------
    if digest != info["digest"]:
        bad = True
        print("\n[reftest-score] #!TREE_SHA256 MISMATCH.")
        print("[reftest-score]   baseline %s\n[reftest-score]   current  %s"
              % (info["digest"], digest))
        print("[reftest-score]   REFTEST_MANIFEST.txt or a vendored test/"
              "reference has changed.\n"
              "[reftest-score]   Editing a vendored document to make it pass, "
              "or deleting a row\n[reftest-score]   from the manifest to "
              "launder a failure out of the lane, both land\n"
              "[reftest-score]   here. If this is a real re-import, regenerate "
              "deliberately.")

    # ---- tests the baseline knows about that the run did not report ----------
    absent = sorted(t for t in was if t not in now)
    if absent:
        bad = True
        print("\n[reftest-score] %d reftest(s) in the baseline produced NO "
              "record:" % len(absent))
        for t in absent[:20]:
            print("    was %-18s %s" % (was[t], t))
        if len(absent) > 20:
            print("    ... and %d more" % (len(absent) - 20))
        print("[reftest-score]   Coverage SHRANK. This is deliberately not "
              "folded into the\n[reftest-score]   regression list: the test may "
              "have been legitimately excluded,\n[reftest-score]   but that has "
              "to be a visible re-import, not a quiet loss.")

    # ---- a pass that stopped passing ---------------------------------------
    regressed = sorted(t for t in was_passing
                       if t in now and now[t] != "PASS")
    if regressed:
        bad = True
        print("\n[reftest-score] REGRESSION: %d reftest(s) that PASSED at "
              "baseline no longer do:" % len(regressed))
        for t in regressed[:40]:
            print("    %-18s %s" % (now[t], t))
        if len(regressed) > 40:
            print("    ... and %d more" % (len(regressed) - 40))
        print("[reftest-score]   NONDISCRIMINATING here is a regression too: it "
              "means the\n[reftest-score]   engine stopped applying the CSS the "
              "pair is about.")

    # ---- a document that used to render and no longer does -------------------
    # Per-test, not just the total: swapping one ERROR for another keeps the
    # count identical while losing a real observation.
    new_errors = sorted(t for t, v in now.items()
                        if v == "ERROR" and was.get(t, "ERROR") != "ERROR")
    if new_errors:
        inconclusive = True
        print("\n[reftest-score] %d document(s) that RENDERED at baseline no "
              "longer do:" % len(new_errors))
        for t in new_errors[:20]:
            det = next((r.get("detail", "") for r in recs if r["test"] == t), "")
            print("    was %-18s %s  (%s)" % (was.get(t, "?"), t, det))
        if len(new_errors) > 20:
            print("    ... and %d more" % (len(new_errors) - 20))

    if c["PASS"] < info["floor"]:
        bad = True
        print("\n[reftest-score] PASS count %d is BELOW #!PASS_FLOOR %d."
              % (c["PASS"], info["floor"]))

    if c["ERROR"] > info["err_ceiling"]:
        inconclusive = True
        print("\n[reftest-score] ERROR count %d is ABOVE #!ERROR_CEILING %d --"
              % (c["ERROR"], info["err_ceiling"]))
        print("[reftest-score]   document(s) that used to RENDER no longer do. A"
              " failing\n[reftest-score]   reftest is information; a reftest that"
              " cannot be rendered is\n[reftest-score]   the ABSENCE of an"
              " observation, so this reports INCONCLUSIVE (125)\n"
              "[reftest-score]   rather than claiming a conformance verdict.")
        for r in recs:
            if r["verdict"] == "ERROR":
                print("    %s  (%s)" % (r["test"], r.get("detail", "")))

    if c["NONDISCRIMINATING"] > info["nd_ceiling"]:
        bad = True
        print("\n[reftest-score] NONDISCRIMINATING count %d is ABOVE "
              "#!ND_CEILING %d --" % (c["NONDISCRIMINATING"],
                                      info["nd_ceiling"]))
        print("[reftest-score]   pairs MOVED INTO the bucket that a null engine "
              "with no CSS\n[reftest-score]   would also satisfy, i.e. the "
              "engine stopped applying the CSS\n[reftest-score]   those pairs "
              "are about. They leave the scored denominator, so\n"
              "[reftest-score]   PASS_FLOOR and ERROR_CEILING both stay happy "
              "while real\n[reftest-score]   capability was lost. Only this "
              "ceiling catches that.")
        moved = sorted(t for t, v in now.items()
                       if v == "NONDISCRIMINATING"
                       and was.get(t) not in (None, "NONDISCRIMINATING"))
        for t in moved[:20]:
            print("    was %-18s %s" % (was.get(t, "?"), t))

    fixed = sorted(t for t, v in now.items()
                   if v == "PASS" and t not in was_passing)
    if fixed:
        print("\n[reftest-score] %d reftest(s) newly PASS -- regenerate the "
              "baseline to bank them:" % len(fixed))
        for t in fixed[:20]:
            print("    %s" % t)
        if len(fixed) > 20:
            print("    ... and %d more" % (len(fixed) - 20))

    if bad:
        return 1
    if inconclusive:
        return 125
    print("\n[reftest-score] no regression; PASS %d >= floor %d, ERROR %d <= "
          "ceiling %d, NONDISCRIMINATING %d <= ceiling %d, tree digest matches"
          % (c["PASS"], info["floor"], c["ERROR"], info["err_ceiling"],
             c["NONDISCRIMINATING"], info["nd_ceiling"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
