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
concrete. The reported ratio is PASS / (PASS + WEAK-PASS + FAIL) --
NONDISCRIMINATING pairs are excluded from the denominator on purpose (a pair
whose render does not depend on CSS at all is not evidence). So the denominator
MOVES:

  * teach the engine to honour a property, and a pair that used to be
    NONDISCRIMINATING becomes discriminating. It enters the denominator, very
    likely as a FAIL at first, and the RATIO DROPS while the engine got better.
  * lift the .xht exclusion and ~1,000 tests arrive at once.

A ratio floor would fail on both. An absolute PASS floor cannot: it only ever
asks "are we still passing at least as many real tests as before".

TWO PASS CLASSES, AND WHY THE SPLIT REPLACED A SINGLE ND BUCKET
---------------------------------------------------------------
The discrimination control used to ask ONE question: "would an engine with no
CSS at all also see this relationship hold?" -- global-strip both documents and
re-compare. It is a sound question and it is retained (see run_one's mutant 0),
but on its own it made real CSS progress unscoreable:

  57 of the 67 remaining failures in the round-1 tranche use a trivial
  `css/reference/ref-filled-green-*` reference. Test and reference BOTH reduce
  to the same boilerplate sentence once CSS is stripped, so fixing one moved it
  FAIL -> NONDISCRIMINATING. It left the denominator instead of entering the
  numerator, and pushed against #!ND_CEILING while doing it. Two genuine fixes
  (max-height-applies-to-018, max-height-separates-margin) did exactly that and
  scored as nothing.

The control is now per-test and mutation-based: neutralize ONE declaration in
the TEST and re-compare against the UNCHANGED reference. A pair scores when the
holding is load-bearing on some declaration, and scores as a full PASS when
that declaration is one the reference does not supply VERBATIM -- so a shared
bug cannot cancel across the two sides. Everything else that still depends on
CSS is WEAK-PASS: banked, ratcheted, and kept out of the headline number.

MEASURED, not argued (100-test round-1 tranche, engine unchanged):

    model      no mutation   blind to max-height   blind to display
    old        PASS 1  ND 32   PASS 1  ND 30 -> GREEN   PASS 1 ND 32 -> GREEN
    new        PASS 4  ND  6   PASS 2        -> FAIL    WEAK 22      -> FAIL

i.e. the previous gate let an engine LOSE max-height and LOSE display without
noticing, because the affected pairs were parked in a bucket it did not score.
The new model catches both, catches everything the old model caught, and the
null-CSS engine still scores exactly 0 PASS and 0 WEAK-PASS
(`wpt_reftest_run.py --prove-null`, run by the gate on every invocation).

ROW KINDS (TAB-separated)
  <test>\t<verdict>     did NOT pass at baseline (FAIL / NONDISCRIMINATING /
                        ERROR, recorded so the CAUSE is visible in the diff)
  +<test>\tPASS         DID pass at baseline -- the regression set
  ~<test>\tWEAK-PASS    weak-passed at baseline -- also a regression set

Recording the passes is what makes a regression decidable. A newly appearing
FAIL row is ambiguous on its own: the test may have regressed, or it may be new
to the manifest. Only a test that was in the pass set and no longer passes
counts as a regression -- and #!PASS_FLOOR catches any genuine loss a second
time regardless.

A PASS turning into WEAK-PASS or NONDISCRIMINATING is ALSO a regression: the
first means the pair stopped being evidence about its own subject matter, the
second that the render stopped depending on CSS at all. WEAK-PASS -> PASS is a
PROMOTION and is not treated as one.
"""

import argparse
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wpt_reftest_run as R                                      # noqa: E402

PASS_PREFIX = "+"
WEAK_PREFIX = "~"


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
    nweak = sum(1 for r in recs if r["verdict"] == "WEAK-PASS")
    nerr = sum(1 for r in recs if r["verdict"] == "ERROR")
    nnd = sum(1 for r in recs if r["verdict"] == "NONDISCRIMINATING")

    if prev and not allow_loosen:
        loosen = []
        if npass < prev["floor"]:
            loosen.append("PASS_FLOOR %d -> %d" % (prev["floor"], npass))
        if nweak < prev["weak_floor"]:
            loosen.append("WEAK_PASS_FLOOR %d -> %d"
                          % (prev["weak_floor"], nweak))
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
            "#   %s<test>\\tPASS      PASSED at baseline (the regression set)\n"
            "#   %s<test>\\tWEAK-PASS WEAK-PASSED at baseline\n"
            "#\n"
            "# VERDICTS\n"
            "#   PASS       the relationship holds, and it is load-bearing on a\n"
            "#              declaration the REFERENCE does not supply verbatim --\n"
            "#              neutralize that declaration in the test alone and the pair\n"
            "#              stops holding. The engine demonstrably applied something\n"
            "#              this test is about.\n"
            "#   WEAK-PASS  the relationship holds and CSS is load-bearing on it, but\n"
            "#              only through declarations the reference repeats IDENTICALLY.\n"
            "#              Both sides run the same code, so a shared bug cancels: real\n"
            "#              work, tracked and ratcheted, but not conflated with a PASS.\n"
            "#   FAIL       the relationship does not hold.\n"
            "#   NONDISCRIMINATING\n"
            "#              the relationship holds no matter WHICH of the test's\n"
            "#              declarations is neutralized, and with all CSS removed. The\n"
            "#              render does not depend on CSS at all, so an engine with no\n"
            "#              CSS support would satisfy it too. Not evidence.\n"
            "#   ERROR      a document, or a control, did not render.\n"
            "#\n"
            "# THE FIVE MARKERS. All are required: a baseline missing one is treated\n"
            "# as unusable rather than defaulting to a value that guards nothing.\n"
            "#\n"
            "# #!PASS_FLOOR guards the ABSOLUTE pass count, not a ratio: the\n"
            "# denominator grows when the engine improves (a NONDISCRIMINATING pair\n"
            "# becomes discriminating) or when an exclusion is lifted, so a real fix\n"
            "# can LOWER the ratio.\n"
            "#\n"
            "# #!WEAK_PASS_FLOOR -- the same guarantee for the weak class. It is a\n"
            "# FLOOR and not a ceiling on purpose: a weak pass is a pair whose holding\n"
            "# depends on CSS, so losing one is a capability loss, and the split exists\n"
            "# to keep weak evidence OUT of the headline number, not out of the ratchet.\n"
            "#\n"
            "# #!ERROR_CEILING -- every vendored document must keep RENDERING. A\n"
            "# change that makes the engine bail turns FAILs into ERRORs, which no\n"
            "# pass floor can see. It is not zero: the round-2 import found a document\n"
            "# that SIGSEGVs the engine (css/css-display/\n"
            "# display-contents-dynamic-fieldset-legend-001.html -- needs its <script>;\n"
            "# with the script removed it renders fine). That is an engine bug, not a\n"
            "# runner limitation, so it may NOT be excluded, and banking it does not\n"
            "# blind the gate: the check is also PER-TEST, so any OTHER document that\n"
            "# starts erroring still reports INCONCLUSIVE.\n"
            "#\n"
            "# #!ND_CEILING -- the capability-loss detector. Under the previous\n"
            "# (global-strip) model this ceiling ALSO capped progress, because fixing a\n"
            "# test whose reference is a plain green square moved it FAIL ->\n"
            "# NONDISCRIMINATING: 57 of 67 remaining failures could not have scored at\n"
            "# all, and two genuine fixes landed in the bucket and read as nothing.\n"
            "# Under the mutation model the class is MONOTONE in the right direction --\n"
            "# a pair only enters it when the render stops depending on CSS -- so this\n"
            "# ceiling now catches loss without capping gain.\n"
            "#\n"
            "# #!TREE_SHA256 -- over REFTEST_MANIFEST.txt and every document it\n"
            "# names. Makes \"never edit a vendored test or reference\" enforced rather\n"
            "# than merely stated, and stops rows being deleted from the manifest to\n"
            "# launder a FAIL out of the lane. A real re-import changes it, which is\n"
            "# the point: it forces a deliberate --regen that shows in the diff.\n"
            "#\n"
            "#!PASS_FLOOR %d\n"
            "#!WEAK_PASS_FLOOR %d\n"
            "#!ERROR_CEILING %d\n"
            "#!ND_CEILING %d\n"
            "#!TREE_SHA256 %s\n" % (PASS_PREFIX, WEAK_PREFIX, npass, nweak,
                                    nerr, nnd, digest))
        for r in sorted(recs, key=lambda r: r["test"]):
            if r["verdict"] == "PASS":
                f.write("%s%s\tPASS\n" % (PASS_PREFIX, r["test"]))
            elif r["verdict"] == "WEAK-PASS":
                f.write("%s%s\tWEAK-PASS\n" % (WEAK_PREFIX, r["test"]))
            else:
                f.write("%s\t%s\n" % (r["test"], r["verdict"]))
    return npass, nweak


MARKERS = {"#!PASS_FLOOR": "floor", "#!WEAK_PASS_FLOOR": "weak_floor",
           "#!ERROR_CEILING": "err_ceiling",
           "#!ND_CEILING": "nd_ceiling", "#!TREE_SHA256": "digest"}


def read_baseline(path):
    """-> (info, passing, weak, notpassing) or (None, ...) on a missing marker.

    Every marker is REQUIRED. Defaulting a missing marker to 0 silently
    disabled the ratchet it belonged to and printed a reassuring
    "PASS n >= floor 0" while guarding nothing -- a lost line in a merge was
    enough.
    """
    info, passing, weak, notpassing = {}, set(), set(), {}
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
            elif line.startswith(WEAK_PREFIX):
                weak.add(line[len(WEAK_PREFIX):].split("\t")[0])
            else:
                p = line.split("\t")
                notpassing[p[0]] = p[1] if len(p) > 1 else "?"
    missing = [m for m, k in MARKERS.items() if k not in info]
    if missing:
        print("[reftest-score] baseline %s is missing required marker(s): %s"
              % (path, " ".join(missing)), file=sys.stderr)
        return None, passing, weak, notpassing
    return info, passing, weak, notpassing


def report(recs):
    c = collections.Counter(r["verdict"] for r in recs)
    scored = c["PASS"] + c["WEAK-PASS"] + c["FAIL"]
    print("[reftest-score] %d reftests" % len(recs))
    for v in ("PASS", "WEAK-PASS", "FAIL", "NONDISCRIMINATING", "ERROR"):
        print("[reftest-score]   %-18s %d" % (v, c[v]))
    if scored:
        print("[reftest-score] %d/%d = %.1f%% of DISCRIMINATING pairs "
              "(+%d weak)"
              % (c["PASS"], scored, 100.0 * c["PASS"] / scored, c["WEAK-PASS"]))
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
            prev, _, _, _ = read_baseline(args.baseline)
        n = write_baseline(args.baseline, recs, digest, prev, args.allow_loosen)
        if n is None:
            return 1
        print("[reftest-score] wrote %s (#!PASS_FLOOR %d  #!WEAK_PASS_FLOOR %d)"
              % (args.baseline, n[0], n[1]))
        return 0

    if not args.check_baseline:
        return 0

    info, was_passing, was_weak, was_notpassing = read_baseline(
        args.check_baseline)
    if info is None:
        # A baseline we cannot read is not a baseline we may pass against.
        print("[reftest-score]   A missing marker would silently disable the "
              "ratchet it belongs to.\n[reftest-score]   Refusing to score.",
              file=sys.stderr)
        return 125

    now = {r["test"]: r["verdict"] for r in recs}
    was = dict(was_notpassing)
    was.update({t: "WEAK-PASS" for t in was_weak})
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
              "means the\n[reftest-score]   render stopped depending on CSS at "
              "all. So is WEAK-PASS: it means\n[reftest-score]   the holding no "
              "longer rests on any declaration the reference does\n"
              "[reftest-score]   not itself supply, i.e. the pair stopped being "
              "evidence about\n[reftest-score]   this test's own subject "
              "matter.")

    # ---- a WEAK pass that stopped passing at all ----------------------------
    # WEAK-PASS -> PASS is a PROMOTION and must not read as a regression; only a
    # drop out of the scoring classes entirely counts.
    weak_regressed = sorted(t for t in was_weak
                            if t in now and now[t] not in ("PASS", "WEAK-PASS"))
    if weak_regressed:
        bad = True
        print("\n[reftest-score] REGRESSION: %d reftest(s) that WEAK-PASSED at "
              "baseline no longer hold:" % len(weak_regressed))
        for t in weak_regressed[:40]:
            print("    %-18s %s" % (now[t], t))
        if len(weak_regressed) > 40:
            print("    ... and %d more" % (len(weak_regressed) - 40))

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

    if c["WEAK-PASS"] < info["weak_floor"]:
        bad = True
        print("\n[reftest-score] WEAK-PASS count %d is BELOW "
              "#!WEAK_PASS_FLOOR %d." % (c["WEAK-PASS"], info["weak_floor"]))
        print("[reftest-score]   A weak pass is still a pair whose holding "
              "DEPENDS on CSS.\n[reftest-score]   Losing one is a capability "
              "loss; the class is separated from\n[reftest-score]   PASS so it "
              "cannot inflate the headline number, not so it can be\n"
              "[reftest-score]   dropped for free.")

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
        print("[reftest-score]   pairs MOVED INTO the bucket whose render does "
              "not depend on\n[reftest-score]   CSS AT ALL -- neutralizing any "
              "one of the test's declarations,\n[reftest-score]   and removing "
              "every one of them, leaves the relationship intact.\n"
              "[reftest-score]   That only happens when the engine stops "
              "applying CSS those\n[reftest-score]   pairs depend on. They "
              "leave the scored denominator, so PASS_FLOOR\n"
              "[reftest-score]   and ERROR_CEILING both stay happy while real "
              "capability was\n[reftest-score]   lost. Only this ceiling "
              "catches that.")
        moved = sorted(t for t, v in now.items()
                       if v == "NONDISCRIMINATING"
                       and was.get(t) not in (None, "NONDISCRIMINATING"))
        for t in moved[:20]:
            print("    was %-18s %s" % (was.get(t, "?"), t))

    for label, sel in (("PASS", lambda t, v: v == "PASS"
                        and t not in was_passing),
                       ("WEAK-PASS", lambda t, v: v == "WEAK-PASS"
                        and t not in was_weak)):
        fixed = sorted(t for t, v in now.items() if sel(t, v))
        if fixed:
            print("\n[reftest-score] %d reftest(s) newly %s -- regenerate the "
                  "baseline to bank them:" % (len(fixed), label))
            for t in fixed[:20]:
                print("    %s" % t)
            if len(fixed) > 20:
                print("    ... and %d more" % (len(fixed) - 20))

    if bad:
        return 1
    if inconclusive:
        return 125
    print("\n[reftest-score] no regression; PASS %d >= floor %d, WEAK-PASS %d "
          ">= floor %d, ERROR %d <= ceiling %d, NONDISCRIMINATING %d <= ceiling "
          "%d, tree digest matches"
          % (c["PASS"], info["floor"], c["WEAK-PASS"], info["weak_floor"],
             c["ERROR"], info["err_ceiling"],
             c["NONDISCRIMINATING"], info["nd_ceiling"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
