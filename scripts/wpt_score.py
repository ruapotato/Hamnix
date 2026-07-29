#!/usr/bin/env python3
"""wpt_score.py -- turn wpt_run.py JSONL into the headline score, the per-area
breakdown, the ranked gap list, and the chromium cross-check.

    python3 scripts/wpt_score.py hamnix.jsonl
    python3 scripts/wpt_score.py hamnix.jsonl --vs chromium.jsonl
    python3 scripts/wpt_score.py hamnix.jsonl --gaps 40
    python3 scripts/wpt_score.py hamnix.jsonl --baseline scripts/wpt_baseline.txt

THE CROSS-CHECK IS NOT OPTIONAL. A harness that reports everything as failing
is worse than no harness: it produces a confident number that is pure noise.
`--vs` scores the SAME tests under `chromium --headless` through the SAME
reporter, and reports:

  * chromium's own score -- if this is not ~100%, the harness is broken, not us.
  * WE-FAIL-CHROMIUM-PASSES -- the real gap list.
  * WE-PASS-CHROMIUM-FAILS  -- suspicious. Either a genuine chromium bug (rare,
    a handful exist in any WPT snapshot) or our harness scoring something it
    should not.
"""

import argparse
import collections
import json
import re
import sys

SUB = {0: "PASS", 1: "FAIL", 2: "TIMEOUT", 3: "NOTRUN", 4: "PRECOND"}


def load(path):
    recs = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                recs.append(json.loads(line))
    return recs


def key(rec, sub):
    return (rec["test"], sub["name"])


def bucket_note(rec):
    """Coarse cause for a file that produced no results at all."""
    n = (rec.get("note") or "")
    if not n:
        if rec.get("harness") is not None:
            # The harness ran and completed, but not one test reported. Almost
            # always the engine aborting or re-entering mid-test.
            return "harness completed, ZERO subtests reported"
        return "no output at all (engine produced nothing)"
    if "timeout" in n.lower():
        return "engine wall-clock timeout"
    if n.startswith("Uncaught"):
        # Collapse "of null or undefined" style detail into the failing member.
        m = re.search(r"property '([^']+)'", n)
        if m:
            return "uncaught: missing property '%s'" % m.group(1)
        return "uncaught: " + n[:70]
    return n[:70]


NO_RESULTS = "<FILE PRODUCED NO RESULTS>"


def failure_rows(recs):
    """The shrink-only set: every (test, subtest) that is not a PASS, plus a
    single sentinel row for a file that reported nothing at all."""
    rows = set()
    for r in recs:
        if not r["subtests"]:
            rows.add("%s\t%s" % (r["test"], NO_RESULTS))
            continue
        for s in r["subtests"]:
            if s["status"] != 0:
                rows.add("%s\t%s" % (r["test"], s["name"]))
    return rows


def write_baseline(recs, path):
    rows = failure_rows(recs)
    npass = sum(1 for r in recs for s in r["subtests"] if s["status"] == 0)
    with open(path, "w") as f:
        f.write(
            "# scripts/wpt_baseline.txt -- SHRINK-ONLY record of what the native\n"
            "# engine does NOT pass in the vendored WPT subset (tests/wpt/).\n"
            "#\n"
            "# The ratchet (scripts/test_wpt_ratchet_host.sh) fails when a line\n"
            "# APPEARS that is not here, i.e. when something that passed starts\n"
            "# failing. Lines DISAPPEARING is the point of the exercise: fix\n"
            "# engine bugs, then regenerate with\n"
            "#   bash scripts/test_wpt_ratchet_host.sh --regen\n"
            "#\n"
            "# A line reading '%s' means the whole file produced\n"
            "# no harness output; when that file starts reporting, its individual\n"
            "# failures are NOT counted as regressions (they were always failing,\n"
            "# just invisible).\n"
            "#\n"
            "# TAB-separated: <test path>\\t<subtest name>\n"
            "#!PASS_FLOOR %d\n" % (NO_RESULTS, npass))
        for line in sorted(rows):
            f.write(line + "\n")
    return npass, len(rows)


def read_baseline(path):
    rows, floor = set(), 0
    with open(path) as f:
        for line in f:
            if line.startswith("#!PASS_FLOOR"):
                floor = int(line.split()[1])
                continue
            if line.startswith("#"):
                continue
            line = line.rstrip("\n")
            if line:
                rows.add(line)
    return rows, floor


def check_baseline(recs, path):
    base, floor = read_baseline(path)
    cur = failure_rows(recs)
    npass = sum(1 for r in recs for s in r["subtests"] if s["status"] == 0)

    # A file that used to report nothing is now reporting. Its individual
    # failures were always there, just unobservable -- not regressions.
    was_silent = {l.split("\t")[0] for l in base if l.endswith("\t" + NO_RESULTS)}
    new = sorted(l for l in cur - base if l.split("\t")[0] not in was_silent)
    fixed = sorted(base - cur)

    print("[wpt-ratchet] baseline failures %d   current failures %d" % (len(base), len(cur)))
    print("[wpt-ratchet] PASS floor %d   current PASS %d" % (floor, npass))
    if fixed:
        print("[wpt-ratchet] %d baseline entries no longer fail (good). Sample:" % len(fixed))
        for l in fixed[:10]:
            print("    + %s" % l.replace("\t", "  ::  "))
    rc = 0
    if new:
        print("[wpt-ratchet] REGRESSION: %d subtest(s) newly failing:" % len(new))
        for l in new[:40]:
            print("    - %s" % l.replace("\t", "  ::  "))
        if len(new) > 40:
            print("    ... and %d more" % (len(new) - 40))
        rc = 1
    if npass < floor:
        print("[wpt-ratchet] REGRESSION: PASS count fell from %d to %d" % (floor, npass))
        rc = 1
    if rc == 0:
        print("[wpt-ratchet] OK: nothing regressed."
              + ("  Regenerate the baseline to bank the %d fix(es)." % len(fixed)
                 if fixed or npass > floor else ""))
    return rc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("jsonl")
    ap.add_argument("--vs", help="chromium JSONL for the cross-check")
    ap.add_argument("--gaps", type=int, default=25)
    ap.add_argument("--baseline", help="write a shrink-only baseline of failing tests")
    ap.add_argument("--check-baseline", metavar="FILE",
                    help="ratchet: fail if anything regressed against FILE")
    ap.add_argument("--markdown", action="store_true")
    args = ap.parse_args()

    recs = load(args.jsonl)
    if args.check_baseline:
        return check_baseline(recs, args.check_baseline)
    tot = collections.Counter()
    per_area = collections.defaultdict(collections.Counter)
    no_result = collections.Counter()
    msg_hist = collections.Counter()

    for r in recs:
        a = r["area"]
        per_area[a]["files"] += 1
        tot["files"] += 1
        if not r["subtests"]:
            per_area[a]["dead"] += 1
            tot["dead"] += 1
            no_result[bucket_note(r)] += 1
        for s in r["subtests"]:
            per_area[a][SUB.get(s["status"], "?")] += 1
            tot[SUB.get(s["status"], "?")] += 1
            if s["status"] != 0:
                m = s["message"] or "(no message)"
                m = re.sub(r"U\+[0-9a-f]{1,6}", "", m)          # engine escaping noise
                m = re.sub(r"\d+", "N", m)
                msg_hist[m[:90]] += 1

    subs = sum(tot[k] for k in ("PASS", "FAIL", "TIMEOUT", "NOTRUN", "PRECOND"))
    print("=" * 78)
    print("WPT SCORE  files=%d  subtests=%d" % (tot["files"], subs))
    print("  PASS %-6d FAIL %-6d TIMEOUT %-5d NOTRUN %-5d   score = %.2f%%"
          % (tot["PASS"], tot["FAIL"], tot["TIMEOUT"], tot["NOTRUN"],
             100.0 * tot["PASS"] / subs if subs else 0))
    print("  files producing NO harness output at all: %d / %d"
          % (tot["dead"], tot["files"]))
    print("=" * 78)

    print("\nPER-AREA (sorted by subtests lost)")
    print("%-38s %6s %6s %6s %7s %6s" % ("area", "files", "pass", "total", "score", "dead"))
    rows = []
    for a, c in per_area.items():
        t = sum(c[k] for k in ("PASS", "FAIL", "TIMEOUT", "NOTRUN", "PRECOND"))
        rows.append((t - c["PASS"], a, c, t))
    for lost, a, c, t in sorted(rows, reverse=True):
        print("%-38s %6d %6d %6d %6.1f%% %6d"
              % (a, c["files"], c["PASS"], t,
                 100.0 * c["PASS"] / t if t else 0.0, c["dead"]))

    print("\nFILES WITH NO RESULTS -- grouped cause (these are the cheapest wins:")
    print("a single missing API can silence an entire file's assertions)")
    for cause, n in no_result.most_common(15):
        print("  %5d  %s" % (n, cause))

    print("\nTOP FAILURE MESSAGES (digits normalised to N)")
    for m, n in msg_hist.most_common(20):
        print("  %5d  %s" % (n, m))

    if args.vs:
        cr = load(args.vs)
        cmap = {}
        cfiles = {}
        for r in cr:
            cfiles[r["test"]] = r
            for s in r["subtests"]:
                cmap[key(r, s)] = s["status"]
        ctot = collections.Counter()
        for r in cr:
            for s in r["subtests"]:
                ctot[SUB.get(s["status"], "?")] += 1
        csubs = sum(ctot.values())
        print("\n" + "=" * 78)
        print("CROSS-CHECK vs chromium --headless (same tests, same reporter)")
        print("  chromium: %d subtests, PASS %d  -> %.2f%%"
              % (csubs, ctot["PASS"], 100.0 * ctot["PASS"] / csubs if csubs else 0))
        if csubs and 100.0 * ctot["PASS"] / csubs < 90:
            print("  !! chromium scores below 90%. Treat OUR number as a HARNESS")
            print("     artifact until this is explained.")
        both = wefail = wepass = 0
        gapfiles = collections.Counter()
        suspicious = []
        for r in recs:
            for s in r["subtests"]:
                k = key(r, s)
                if k not in cmap:
                    continue
                both += 1
                if s["status"] != 0 and cmap[k] == 0:
                    wefail += 1
                    gapfiles[r["area"]] += 1
                elif s["status"] == 0 and cmap[k] != 0:
                    wepass += 1
                    if len(suspicious) < 15:
                        suspicious.append((r["test"], s["name"], SUB.get(cmap[k])))
        print("  comparable subtests (present in both): %d" % both)
        print("  WE FAIL / CHROMIUM PASSES: %d   <-- the real gap" % wefail)
        print("  WE PASS / CHROMIUM FAILS : %d   <-- suspicious, inspect" % wepass)
        for t, n, st in suspicious:
            print("      %s :: %s (chromium %s)" % (t, n[:60], st))
        # Files chromium runs and we do not.
        dead_us = {r["test"] for r in recs if not r["subtests"]}
        dead_cr = {r["test"] for r in cr if not r["subtests"]}
        print("  files with results in chromium but NONE for us: %d"
              % len(dead_us - dead_cr))
        print("  files dead in BOTH (harness/import artifact, not an engine gap): %d"
              % len(dead_us & dead_cr))
        print("\n  RANKED GAP BY AREA (we fail, chromium passes)")
        for a, n in gapfiles.most_common(args.gaps):
            print("    %6d  %s" % (n, a))

    if args.baseline:
        npass, nrows = write_baseline(recs, args.baseline)
        print("\n[wpt-score] wrote baseline %s (%d failing rows, PASS floor %d)"
              % (args.baseline, nrows, npass))
    return 0


if __name__ == "__main__":
    sys.exit(main())
