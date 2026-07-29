#!/usr/bin/env python3
"""wpt_reftest_chromium_check.py -- validate the REFTEST HARNESS against Chromium.

    python3 scripts/wpt_reftest_chromium_check.py            # whole manifest
    python3 scripts/wpt_reftest_chromium_check.py --limit 20  # a sample

WHY
---
scripts/wpt_reftest_run.py reports a number. A number from an instrument nobody
checked is not evidence. The specific worry:

    if our comparator calls a pair DIFFERENT on a pair that Chromium -- which
    passes essentially all of css/CSS2 -- calls IDENTICAL, the reported failure
    may be the HARNESS (viewport normalization, resource inlining, the
    exact-equality rule) rather than the engine.

So we run the SAME pairs through headless Chromium at the SAME 800x600
viewport, with the SAME exact-equality comparison, and cross-tabulate. Chromium
gets the vendored files UNMODIFIED -- it has a real CSS/script loader, so it
needs none of our inlining. That is deliberate: if the inlining changed a
document's meaning, Chromium's verdict would diverge from ours on pairs where
the CSS is external, and that shows up here.

READING THE TABLE
  ours=FAIL chromium=PASS   -> a real engine bug. This is what we want to see.
  ours=PASS chromium=FAIL   -> FALSE PASS: our comparator or renderer is
                              coincidentally agreeing. Any nonzero count here
                              is a harness defect, not a score. Exits non-zero.
  ours=NONDISCRIMINATING,
      chromium=FAIL         -> a pair that WOULD have been a false pass, caught
                              by the discrimination control. Reported as
                              "unearned agreement", not as a failure: this is the
                              control working. Read it as the empirical measure
                              of how much work that control is doing.
  ours=PASS chromium=PASS   -> earned pass.
  ours=FAIL chromium=FAIL   -> the pair does not hold even in Chromium at our
                              viewport: an upstream-fragile pair, or a
                              viewport/AA difference in CHROMIUM. Investigate
                              before crediting or blaming anything.

This is an on-demand audit, not in ci_battery_manifest.txt because it shells out
to a system chromium that CI is not guaranteed to have, and because its job is
to validate the instrument when the instrument changes -- not to gate every
commit. The gate (scripts/test_wpt_reftest_ratchet_host.sh) is engine-only and
needs no browser.
"""

import argparse
import collections
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import wpt_reftest_run as R                                   # noqa: E402

CHROMIUM = shutil.which("chromium") or shutil.which("chromium-browser") \
    or shutil.which("google-chrome")


def shoot(tmp, rel, n):
    """Chromium screenshot of a vendored document, as normalized viewport bytes."""
    out = os.path.join(tmp, "c%d.png" % n)
    src = os.path.join(R.TESTS, rel)
    try:
        subprocess.run(
            [CHROMIUM, "--headless", "--no-sandbox", "--disable-gpu",
             "--hide-scrollbars", "--force-device-scale-factor=1",
             "--default-background-color=FFFFFFFF",
             "--virtual-time-budget=2000",
             "--screenshot=" + out,
             "--window-size=%d,%d" % (R.VIEW_W, R.VIEW_H),
             "file://" + os.path.abspath(src)],
            capture_output=True, timeout=90)
    except (OSError, subprocess.SubprocessError):
        # One hung chromium used to raise TimeoutExpired straight out of here,
        # abort the audit mid-manifest and skip the JSONL write entirely.
        return None
    if not os.path.isfile(out) or os.path.getsize(out) == 0:
        return None
    try:
        from PIL import Image
        im = Image.open(out).convert("RGB")
        # same top-left composite onto a fixed page-background canvas
        return R.viewport((im.size[0], im.size[1], im.tobytes()))
    except Exception:
        return None
    finally:
        try:
            os.unlink(out)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--jsonl", default="build/host/wpt_reftest_chromium.jsonl")
    args = ap.parse_args()

    if not CHROMIUM:
        print("[reftest-xcheck] INCONCLUSIVE: no chromium on PATH; the harness "
              "cannot be validated, so do not trust an unvalidated score.")
        return 125
    if not os.path.isfile(R.MANIFEST):
        print("[reftest-xcheck] INCONCLUSIVE: %s absent" % R.MANIFEST)
        return 125

    rows = R.load_manifest()
    if args.limit:
        rows = rows[:args.limit]

    tmp = tempfile.mkdtemp(prefix="reftest-xcheck-")
    tab = collections.Counter()
    recs = []
    try:
        rend = R.Renderer(tmp)
        cache, n = {}, 0
        for test, kind, refs in rows:
            ours = R.run_one(rend, test, kind, refs)
            for doc in [test] + refs:
                if doc not in cache:
                    n += 1
                    cache[doc] = shoot(tmp, doc, n)
            if cache[test] is None or any(cache[r] is None for r in refs):
                cver = "ERROR"
            else:
                eq = [r for r in refs if cache[r] == cache[test]]
                cver = "PASS" if (bool(eq) if kind == "match"
                                  else not eq) else "FAIL"
            ov = ours["verdict"]
            tab[(ov, cver)] += 1
            recs.append({"test": test, "kind": kind, "ours": ov,
                         "chromium": cver,
                         "null_holds": ours.get("null_holds")})
            print("%-18s chromium=%-6s %s" % (ov, cver, test))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if args.jsonl:
        os.makedirs(os.path.dirname(os.path.abspath(args.jsonl)), exist_ok=True)
        with open(args.jsonl, "w") as f:
            for r in recs:
                f.write(json.dumps(r, sort_keys=True) + "\n")

    print("\n[reftest-xcheck] %d pairs through BOTH engines at %dx%d, "
          "exact equality both sides\n" % (len(recs), R.VIEW_W, R.VIEW_H))
    ours_v = sorted({o for o, _ in tab})
    chr_v = sorted({c for _, c in tab})
    print("        chromium: " + "".join("%-8s" % c for c in chr_v))
    for o in ours_v:
        print("%-16s  " % ("ours=" + o) + "".join(
            "%-8d" % tab[(o, c)] for c in chr_v))

    # An instrument that took no measurement must not print an all-clear.
    measured = sum(v for (_o, c), v in tab.items() if c != "ERROR")
    if measured < max(1, len(recs) // 2):
        print("\n[reftest-xcheck] INCONCLUSIVE: chromium produced a usable "
              "screenshot for only %d of %d pairs." % (measured, len(recs)))
        print("[reftest-xcheck]   (PIL missing? chromium refusing --headless? "
              "sandbox denied?)\n[reftest-xcheck]   With nothing to compare "
              "against, '0 false passes' would be an\n[reftest-xcheck]   "
              "all-clear from an instrument that measured nothing.")
        return 125

    # Our PASS against chromium FAIL is the textbook false pass -- but with our
    # PASS count at 0 that number is 0 by ARITHMETIC, not by evidence. The pairs
    # actually at risk are the ones where OUR comparator found the relationship
    # HOLDING, which includes every NONDISCRIMINATING record. So both are
    # reported, and the second is the one to read.
    strict = sum(v for (o, c), v in tab.items() if o == "PASS" and c == "FAIL")
    unearned = sum(v for (o, c), v in tab.items()
                   if o in ("PASS", "NONDISCRIMINATING") and c == "FAIL")
    print("\n[reftest-xcheck] FALSE PASSES (ours=PASS, chromium=FAIL): %d"
          % strict)
    print("[reftest-xcheck]   ours=PASS total is %d, so read the next line too."
          % sum(v for (o, _c), v in tab.items() if o == "PASS"))
    print("[reftest-xcheck] UNEARNED AGREEMENT (our comparator found the "
          "relationship\n[reftest-xcheck]   holding -- PASS or "
          "NONDISCRIMINATING -- where chromium found it\n"
          "[reftest-xcheck]   violated): %d" % unearned)
    print("[reftest-xcheck] real engine bugs (ours=FAIL, chromium=PASS): %d"
          % tab[("FAIL", "PASS")])
    print("[reftest-xcheck] both FAIL -- pair not stable even in chromium at "
          "this viewport: %d" % tab[("FAIL", "FAIL")])
    print("[reftest-xcheck] chromium ERROR (no usable screenshot): %d"
          % sum(v for (_o, c), v in tab.items() if c == "ERROR"))
    # Exit non-zero ONLY on a strict false pass, which is unambiguously a
    # harness defect. An unearned agreement sitting in the NONDISCRIMINATING
    # bucket is the discrimination control DOING ITS JOB -- it is the pair being
    # kept out of the score -- so failing on it would punish the mechanism that
    # prevented the false pass.
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
