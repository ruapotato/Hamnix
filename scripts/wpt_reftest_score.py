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
import sys

PASS_PREFIX = "+"


def load(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def write_baseline(path, recs):
    npass = sum(1 for r in recs if r["verdict"] == "PASS")
    nerr = sum(1 for r in recs if r["verdict"] == "ERROR")
    with open(path, "w") as f:
        f.write(
            "# scripts/wpt_reftest_baseline.txt -- SHRINK-ONLY record of the WPT\n"
            "# REFTEST lane (tests/wpt/REFTEST_MANIFEST.txt): a test document\n"
            "# compared PIXEL-EXACTLY against its <link rel=\"match\"> reference,\n"
            "# both rendered by our own engine.\n"
            "#\n"
            "# Regenerate with:  bash scripts/test_wpt_reftest_ratchet_host.sh --regen\n"
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
            "# #!PASS_FLOOR guards the ABSOLUTE pass count, not a ratio: the\n"
            "# denominator grows when the engine improves (a NONDISCRIMINATING pair\n"
            "# becomes discriminating) or when an exclusion is lifted, so a real fix\n"
            "# can LOWER the ratio. See scripts/wpt_reftest_score.py.\n"
            "#\n"
            "# #!ERROR_CEILING is the second ratchet, and on a lane whose PASS\n"
            "# floor is still 0 it is the one with teeth: every vendored document\n"
            "# must keep RENDERING. A change that makes the engine bail on a page\n"
            "# turns FAILs into ERRORs, which no pass-floor can see. It may only\n"
            "# shrink.\n"
            "#\n"
            "#!PASS_FLOOR %d\n"
            "#!ERROR_CEILING %d\n" % (PASS_PREFIX, npass, nerr))
        for r in sorted(recs, key=lambda r: r["test"]):
            if r["verdict"] == "PASS":
                f.write("%s%s\tPASS\n" % (PASS_PREFIX, r["test"]))
            else:
                f.write("%s\t%s\n" % (r["test"], r["verdict"]))
    return npass


def read_baseline(path):
    floor, ceiling, passing, notpassing = 0, 0, set(), {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#!PASS_FLOOR"):
                floor = int(line.split()[1])
                continue
            if line.startswith("#!ERROR_CEILING"):
                ceiling = int(line.split()[1])
                continue
            if not line or line.startswith("#"):
                continue
            if line.startswith(PASS_PREFIX):
                passing.add(line[len(PASS_PREFIX):].split("\t")[0])
            else:
                p = line.split("\t")
                notpassing[p[0]] = p[1] if len(p) > 1 else "?"
    return floor, ceiling, passing, notpassing


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
    args = ap.parse_args()

    recs = load(args.jsonl)
    if not recs:
        print("[reftest-score] no records", file=sys.stderr)
        return 2
    c = report(recs)

    if args.baseline:
        n = write_baseline(args.baseline, recs)
        print("[reftest-score] wrote %s (#!PASS_FLOOR %d)" % (args.baseline, n))
        return 0

    if not args.check_baseline:
        return 0

    floor, ceiling, was_passing, _ = read_baseline(args.check_baseline)
    now = {r["test"]: r["verdict"] for r in recs}
    regressed = sorted(t for t in was_passing if now.get(t) != "PASS")
    bad = False

    if regressed:
        bad = True
        print("\n[reftest-score] REGRESSION: %d reftest(s) that PASSED at "
              "baseline no longer do:" % len(regressed))
        for t in regressed[:40]:
            print("    %-18s %s" % (now.get(t, "<absent from run>"), t))
        if len(regressed) > 40:
            print("    ... and %d more" % (len(regressed) - 40))
        print("[reftest-score]   NONDISCRIMINATING here is a regression too: it "
              "means the\n[reftest-score]   engine stopped applying the CSS the "
              "pair is about.")

    if c["PASS"] < floor:
        bad = True
        print("\n[reftest-score] PASS count %d is BELOW #!PASS_FLOOR %d."
              % (c["PASS"], floor))

    if c["ERROR"] > ceiling:
        bad = True
        print("\n[reftest-score] ERROR count %d is ABOVE #!ERROR_CEILING %d --"
              % (c["ERROR"], ceiling))
        print("[reftest-score]   document(s) that used to RENDER no longer do. A"
              " failing\n[reftest-score]   reftest is information; a reftest that"
              " cannot be rendered is\n[reftest-score]   the loss of an"
              " observation.")
        for r in recs:
            if r["verdict"] == "ERROR":
                print("    %s  (%s)" % (r["test"], r.get("detail", "")))

    fixed = sorted(t for t, v in now.items()
                   if v == "PASS" and t not in was_passing)
    if fixed:
        print("\n[reftest-score] %d reftest(s) newly PASS -- regenerate the "
              "baseline to bank them:" % len(fixed))
        for t in fixed[:20]:
            print("    %s" % t)
        if len(fixed) > 20:
            print("    ... and %d more" % (len(fixed) - 20))

    if not bad:
        print("\n[reftest-score] no regression; PASS %d >= floor %d, ERROR %d <= "
              "ceiling %d" % (c["PASS"], floor, c["ERROR"], ceiling))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
