#!/usr/bin/env python3
"""scripts/leakprobe_slopes.py — STEP-AWARE slopes for every counter in a
soak serial log.

WHAT THIS IS FOR
================
A leak hunt ends in one number: how many pages per cycle does the system
fail to give back? The soak (scripts/test_de_stress_soak.sh) samples
/proc/meminfo twice per cycle and the serial log carries the whole series.
This turns that log into a per-counter slope.

WHY IT IS NOT A LEAST-SQUARES FIT
=================================
Two phantom findings were reported to the user from naive slopes on these
exact series, and both cost real time:

  * A series with a true flat rate of about +10 pg/cycle and ONE 16 MiB
    level shift partway through read as least-squares +104 and Theil-Sen
    +86. The pass concluded there was "a second mechanism accelerating
    late". There was no second mechanism. There was one step.
  * With 42 pre-step and 26 post-step samples, ~47% of Theil-Sen's pairs
    STRADDLED the step, so the "robust" estimator was contaminated too —
    robustness to outliers is not robustness to a level shift. Note the
    margin: a SINGLE step can straddle at most 50% of the pairs (the
    maximum, at a step dead centre), so Theil-Sen's median survives one
    step by a hair and therefore LOOKS trustworthy. A second step pushes
    the straddling fraction to about two thirds and it goes with them —
    the selftest below demonstrates exactly this, at ts=+158 on a series
    whose true rate is +10.

A level shift is not an outlier and it is not a trend. It is a one-time
event bolted onto an otherwise flat series, and any estimator that looks
at (y_j - y_i) for i and j on opposite sides of it absorbs the whole step
into the slope. Only an estimator built from WITHIN-SEGMENT differences
answers the question actually being asked.

THE THREE ESTIMATORS, AND WHICH ONE YOU MAY BELIEVE
===================================================
  ls      ordinary least-squares on (cycle, value).  STEP-CONTAMINATED.
  ts      Theil-Sen median of all pairwise slopes.   STEP-CONTAMINATED.
  steady  the series CUT at every detected level shift, least-squares
          per segment, pooled by segment length.          <-- the valid one

`ls` and `ts` are computed and printed anyway, for exactly one reason:
WHEN ALL THREE AGREE, THE SERIES IS UNCONTAMINATED. That is a real and
useful signal — after the 16 MiB step was fixed the same series read
+9.93 / +10.1 / +9.73 and the agreement is what made the number
trustworthy. When they disagree, the tool says so loudly and only
`steady` means anything.

TWO MORE MEASUREMENT FACTS THIS TOOL ENFORCES
=============================================
  * RUN-TO-RUN SPREAD ON IDENTICAL CODE IS AT LEAST 1.5 pg/cycle. A slope
    smaller than that is not a small leak, it is noise, and a "-36%"
    computed from two such numbers is not a result. Anything under the
    floor is printed as NOISE, never as a rate.
  * A 10-MINUTE SOAK DOES NOT PREDICT THE 30-MINUTE RESULT. A fix once
    measured -36% at 10 minutes and EXACTLY ZERO at 30. If the log carries
    too few cycles the tool prints a SHORT-SOAK caution on every line.

USAGE
    python3 scripts/leakprobe_slopes.py <soak-serial-log> [options]
      --label SUBSTR   only samples whose marker label contains SUBSTR
                       (default "closed" — the apps-are-shut series, the
                       only one where recovery is even meaningful)
      --warmup N       drop the first N matching samples (default 1)
      --all            print every counter, not just the moving ones
      --json           machine-readable output
      --selftest       run the built-in estimator tests and exit

LOG FORMAT
    Samples are delimited by SOAKSMP_<label>_B / SOAKSMP_<label>_E markers
    and each body line is "Key: <int> [<int> ...]". A multi-value line is
    split into sub-series; PgSite<N> lines (the allocation tracker's
    per-site histogram, mm/page_alloc.ad) are named .live/.allocs/.frees.
"""
from __future__ import annotations

import argparse
import json
import re
import sys

# Run-to-run spread measured on IDENTICAL code across repeated soaks.
# A slope under this is noise, not a leak.
NOISE_FLOOR = 1.5

# Cycles below which the series cannot be believed at all: the 10-vs-30
# minute divergence above. The soak samples twice per cycle.
SHORT_SOAK_CYCLES = 40

# Measured DE stress-soak cycle length. Used ONLY to turn a pages/cycle
# slope into the units the uptime requirement is actually stated in.
CYCLE_SECONDS = 28.0
PAGE_BYTES = 4096


def horizon(pages_per_cycle):
    """A pages/cycle slope in the units 'runs for months' is stated in.

    THE POINT. The soak gate's tolerance is 1.0 pg/cycle, and it is easy to
    read a passing verdict as "no leak". Do the arithmetic: 1 pg/cycle at
    ~28 s/cycle is ~500 kB/hour, ~12 MB/day, ~4 GB/YEAR. That is a gate
    threshold, not a target — for the stated goal of months-to-years of
    uptime without a reboot it is a failure that happens to pass. Printing
    the yearly figure next to every slope makes that impossible to misread,
    and makes the difference between 0.0 and 0.3 pg/cycle feel like what it
    is (0 vs 1.2 GB/year) instead of "both basically zero".

    Returns (bytes_per_hour, mib_per_day, gib_per_year).
    """
    per_cycle_bytes = pages_per_cycle * PAGE_BYTES
    cycles_per_hour = 3600.0 / CYCLE_SECONDS
    bph = per_cycle_bytes * cycles_per_hour
    return (bph, bph * 24.0 / (1024.0 * 1024.0),
            bph * 24.0 * 365.0 / (1024.0 * 1024.0 * 1024.0))

# A first-difference is called a LEVEL SHIFT when it exceeds the typical
# difference by this many robust sigma. 6 is deliberately conservative:
# missing a step corrupts the answer, flagging one extra difference costs
# one sample out of dozens.
STEP_SIGMA = 6.0

# ...and never below this absolute magnitude, so a perfectly flat series
# (MAD == 0) does not classify every ordinary +1 as a step.
STEP_ABS_FLOOR = 8.0

# Per-site names for the allocation tracker's PgSite<N> lines. Mirrors the
# PA_SITE_* constants in mm/page_alloc.ad; ids are frozen there.
PA_SITES = {
    0: "unknown", 1: "vma_large", 2: "vma_fixed", 3: "vma_prefault",
    4: "vma_file", 5: "vma_huge", 6: "vma_anon", 7: "vma_swapin",
    8: "vma_grow", 9: "pgtable", 10: "fork_copy", 11: "cow_resolve_pte",
    12: "kstack", 13: "ustack", 14: "pml4", 15: "selftest", 16: "slab",
    17: "uaccess", 18: "tmpfs", 19: "wsys", 20: "execve",
}

# Per-site names for the kernel-heap tracker's KmSite<N> lines. Mirrors the
# KM_SITE_* constants in mm/slab.ad; ids are frozen there, append-only.
KM_SITES = {
    0: "unknown", 1: "vfs", 2: "vma", 3: "wsys", 4: "vk", 5: "task",
    6: "abi", 7: "net", 8: "block", 9: "snd", 10: "tmpfs", 11: "selftest",
}


# --- estimators -------------------------------------------------------

def median(xs):
    if not xs:
        return 0.0
    s = sorted(xs)
    n = len(s)
    return float(s[n // 2]) if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def slope_ls(ys):
    """Ordinary least squares. Step-contaminated; reported for agreement."""
    n = len(ys)
    if n < 2:
        return 0.0
    mx = (n - 1) / 2.0
    my = sum(ys) / n
    num = sum((i - mx) * (y - my) for i, y in enumerate(ys))
    den = sum((i - mx) ** 2 for i in range(n))
    return num / den if den else 0.0


def slope_ts(ys):
    """Theil-Sen over ALL pairs. Robust to outliers, NOT to level shifts:
    with a step at 62% of the series, ~47% of these pairs straddle it."""
    n = len(ys)
    if n < 2:
        return 0.0
    slopes = [(ys[j] - ys[i]) / (j - i)
              for i in range(n) for j in range(i + 1, n)]
    return median(slopes)


def find_steps(ys):
    """Indices i where ys[i+1]-ys[i] is a LEVEL SHIFT rather than trend.

    Robust detector: median / MAD of the first differences, both computed
    over the differences themselves so an ongoing trend is the baseline
    and only departures from it are steps.
    """
    if len(ys) < 3:
        return []
    d = [ys[i + 1] - ys[i] for i in range(len(ys) - 1)]
    med = median(d)
    mad = median([abs(x - med) for x in d])
    sigma = 1.4826 * mad
    thresh = max(STEP_SIGMA * sigma, STEP_ABS_FLOOR)
    return [i for i, x in enumerate(d) if abs(x - med) > thresh]


def segments(ys):
    """The series CUT at every detected level shift."""
    bounds = [0] + [i + 1 for i in find_steps(ys)] + [len(ys)]
    return [(a, b) for a, b in zip(bounds, bounds[1:]) if b > a]


def slope_steady(ys):
    """THE VALID ESTIMATOR on a stepped series.

    Cut the series at every detected level shift, least-squares each
    segment on its own, and pool the segment slopes weighted by length.
    No pair of points from opposite sides of a step is ever differenced,
    so the step contributes nothing to the slope; everything else in the
    series still contributes, which is why this is a segmented FIT and
    not a median of adjacent differences.

    (A median of adjacent differences is also step-resistant — a rare big
    difference cannot move a median — but it throws away most of the
    information in the series and its variance is correspondingly worse.
    It is kept as the fallback for a series so fragmented that no segment
    is long enough to fit.)
    """
    if len(ys) < 2:
        return 0.0
    num = 0.0
    den = 0.0
    for a, b in segments(ys):
        if b - a >= 3:
            w = float(b - a - 1)
            num += slope_ls(ys[a:b]) * w
            den += w
    if den:
        return num / den
    d = [ys[i + 1] - ys[i] for i in range(len(ys) - 1)]
    steps = set(find_steps(ys))
    kept = [x for i, x in enumerate(d) if i not in steps]
    return median(kept if kept else d)


def analyse(ys):
    """Full verdict for one series."""
    steps = find_steps(ys)
    d = [ys[i + 1] - ys[i] for i in range(len(ys) - 1)] if len(ys) > 1 else []
    st = slope_steady(ys)
    ls = slope_ls(ys)
    ts = slope_ts(ys)
    est = [st, ls, ts]
    spread = max(est) - min(est)
    # Disagreement means the series has structure the naive estimators
    # absorbed. Tolerance is the larger of the noise floor and a quarter
    # of the steady rate (a big real slope has proportionally big spread).
    tol = max(NOISE_FLOOR, abs(st) * 0.25)
    return {
        "n": len(ys),
        "first": ys[0] if ys else 0,
        "last": ys[-1] if ys else 0,
        "steady": st,
        "ls": ls,
        "ts": ts,
        "spread": spread,
        "contaminated": spread > tol,
        "noise": abs(st) < NOISE_FLOOR,
        "segments": len(segments(ys)),
        "steps": [{"at": i + 1, "delta": d[i]} for i in steps],
    }


# --- log parsing ------------------------------------------------------

SAMPLE_RE = re.compile(r'^SOAKSMP_(\w+)_B\s*$(.*?)^SOAKSMP_\1_E\s*$',
                       re.S | re.M)
LINE_RE = re.compile(r'^\s*([A-Za-z_][A-Za-z_0-9]*):\s+([0-9 ]+?)\s*$', re.M)


def subkeys(key, count):
    """Names for the columns of a multi-value line."""
    m = re.fullmatch(r'PgSite(\d+)', key)
    if m and count == 3:
        sid = int(m.group(1))
        base = "PgSite%s:%s" % (sid, PA_SITES.get(sid, "site%d" % sid))
        return [base + ".live", base + ".allocs", base + ".frees"]
    # KmSite<N> carries FOUR columns (mm/slab.ad kmtrack): live objects,
    # live bytes, cumulative allocs, cumulative frees. .live is the leak
    # series; .bytes says how much the leak actually costs, which for a
    # 32-byte cache and a 2048-byte cache differ by 64x for the same count.
    m = re.fullmatch(r'KmSite(\d+)', key)
    if m and count == 4:
        sid = int(m.group(1))
        base = "KmSite%s:%s" % (sid, KM_SITES.get(sid, "site%d" % sid))
        return [base + ".live", base + ".bytes",
                base + ".allocs", base + ".frees"]
    if count == 1:
        return [key]
    return ["%s.c%d" % (key, i) for i in range(count)]


def parse(text):
    text = text.replace('\r', '\n')
    out = []
    for m in SAMPLE_RE.finditer(text):
        label, body = m.group(1), m.group(2)
        vals = {}
        for lm in LINE_RE.finditer(body):
            nums = [int(x) for x in lm.group(2).split()]
            if not nums:
                continue
            for name, v in zip(subkeys(lm.group(1), len(nums)), nums):
                vals[name] = v
        out.append((label, vals))
    return out


# --- reporting --------------------------------------------------------

def report(samples, label, warmup, show_all, as_json):
    sel = [(l, v) for l, v in samples if label in l]
    if len(sel) > warmup + 3:
        sel = sel[warmup:]
    n = len(sel)
    short = n < SHORT_SOAK_CYCLES
    keys = sorted({k for _, v in sel for k in v})

    results = {}
    for k in keys:
        ys = [v[k] for _, v in sel if k in v]
        if len(ys) < 3:
            continue
        results[k] = analyse(ys)

    if as_json:
        print(json.dumps({"samples": n, "label": label,
                          "short_soak": short,
                          "noise_floor": NOISE_FLOOR,
                          "counters": results}, indent=2, sort_keys=True))
        return 0

    print("samples=%d label~=%s warmup=%d noise_floor=%.1f/cycle"
          % (n, label, warmup, NOISE_FLOOR))
    if short:
        print("!! SHORT SOAK (%d cycles < %d): a 10-minute soak does NOT "
              "predict the 30-minute result — a fix once measured -36%% at "
              "10 min and ZERO at 30. Treat every number below as "
              "provisional." % (n, SHORT_SOAK_CYCLES))
    if n < 3:
        print("!! too few samples to slope anything")
        return 1

    print("%-34s %12s %12s %10s %10s %10s  %s"
          % ("counter", "first", "last", "steady", "ls", "ts", "verdict"))
    moved = 0
    for k in sorted(results):
        r = results[k]
        if not show_all and r["noise"] and r["first"] == r["last"]:
            continue
        bits = []
        if r["steps"]:
            bits.append("STEPS=%d(%s)" % (
                len(r["steps"]),
                ",".join("%+d@%d" % (s["delta"], s["at"])
                         for s in r["steps"][:3])))
        if r["contaminated"]:
            bits.append("DISAGREE spread=%.1f -> BELIEVE `steady` ONLY"
                        % r["spread"])
        elif not r["noise"]:
            bits.append("agree (uncontaminated)")
        if r["noise"]:
            bits.append("NOISE (<%.1f/cycle)" % NOISE_FLOOR)
        else:
            moved += 1
        print("%-34s %12d %12d %10.2f %10.2f %10.2f  %s"
              % (k[:34], r["first"], r["last"], r["steady"], r["ls"],
                 r["ts"], "; ".join(bits)))
    print("\n%d counter(s) moving above the noise floor." % moved)

    # EXTRAPOLATION TO THE STATED REQUIREMENT. A pages/cycle number does not
    # communicate "this box reboots itself every N months", which is the
    # actual acceptance criterion. Anchor on PagesInUse when present (the
    # system-wide figure), else on the largest non-noise page counter.
    pin = None
    for cand in ("PagesInUse", "PagesInUse.c0"):
        if cand in results:
            pin = results[cand]
            break
    if pin is not None:
        bph, mibd, giby = horizon(pin["steady"])
        print("PagesInUse steady=%+.2f pg/cycle  ->  %+.0f B/h  %+.1f MiB/day"
              "  %+.2f GiB/year" % (pin["steady"], bph, mibd, giby))
        if pin["noise"]:
            print("  (at or under the %.1f pg/cycle run-to-run noise floor: "
                  "this run cannot distinguish it from zero — which is NOT "
                  "the same as having measured zero)" % NOISE_FLOOR)
        else:
            print("  NOT zero. The soak gate's 1.0 pg/cycle tolerance is a "
                  "GATE THRESHOLD, not the target: 1.0 pg/cycle is ~4 GB/year, "
                  "a reboot-every-few-months leak that passes. A measured "
                  "non-zero slope is an OPEN BUG regardless of the verdict.")
    return 0


# --- selftest ---------------------------------------------------------

def selftest():
    """The two phantom findings, reproduced, plus the clean case."""
    fails = []

    def check(name, cond, detail=""):
        print("  %-52s %s %s" % (name, "ok" if cond else "FAIL", detail))
        if not cond:
            fails.append(name)

    import random
    rng = random.Random(7)
    jitter = [rng.randint(-3, 3) for _ in range(68)]

    def series(rate, steps):
        ys, v = [], 1000
        for i in range(68):
            v += steps.get(i, 0) + rate
            ys.append(v + jitter[i])
        return ys

    # 1. TRUE +10/cycle with one 16 MiB (4096-page) level shift at 42/68 —
    #    the exact shape that was misread as "+104, a second mechanism
    #    accelerating late". There was no second mechanism, only a step.
    stepped = series(10, {42: 4096})
    r = analyse(stepped)
    check("stepped: steady recovers the true +10",
          abs(r["steady"] - 10) < 1.0, "steady=%.2f" % r["steady"])
    check("stepped: least-squares is contaminated (reads high)",
          r["ls"] > 40, "ls=%.2f" % r["ls"])
    check("stepped: the step is located",
          len(r["steps"]) == 1 and r["steps"][0]["at"] == 42,
          "steps=%s" % r["steps"])
    check("stepped: flagged as DISAGREE",
          r["contaminated"], "spread=%.1f" % r["spread"])

    # 1b. Theil-Sen's specific failure. ONE step can only make ~47% of its
    #     pairs straddle (the maximum is 50%, at a step dead centre), so
    #     its median survives by a hair — which is exactly why it reads as
    #     trustworthy and is not. TWO steps push the straddling fraction to
    #     ~2/3 and the "robust" estimator goes with it. Robustness to
    #     outliers is not robustness to level shifts.
    two = series(10, {22: 4096, 45: 4096})
    r1b = analyse(two)
    check("two steps: Theil-Sen is contaminated too",
          r1b["ts"] > 40, "ts=%.2f" % r1b["ts"])
    check("two steps: steady still recovers +10",
          abs(r1b["steady"] - 10) < 1.0, "steady=%.2f" % r1b["steady"])
    check("two steps: both steps located",
          len(r1b["steps"]) == 2, "steps=%s" % r1b["steps"])

    # 2. Same rate, no step: all three must converge and NOT warn — the
    #    post-fix +9.93 / +10.1 / +9.73 signature.
    clean = series(10, {})
    r2 = analyse(clean)
    check("clean: all three estimators agree",
          not r2["contaminated"], "spread=%.2f" % r2["spread"])
    check("clean: steady ~ +10",
          abs(r2["steady"] - 10) < 1.0, "steady=%.2f" % r2["steady"])
    check("clean: no spurious steps",
          not r2["steps"], "steps=%s" % r2["steps"])

    # 3. Sub-noise drift must be reported as NOISE, never as a rate.
    quiet = [1000 + (i % 2) for i in range(68)]
    r3 = analyse(quiet)
    check("quiet: reported as NOISE not a leak", r3["noise"],
          "steady=%.2f" % r3["steady"])

    # 4. A step with NO underlying trend must slope to ~0, not to the step.
    pure = [1000] * 30 + [5096] * 30
    r4 = analyse(pure)
    check("pure step, no trend: steady ~ 0",
          abs(r4["steady"]) < 1.0, "steady=%.2f" % r4["steady"])
    check("pure step, no trend: ls absorbs the step",
          r4["ls"] > 40, "ls=%.2f" % r4["ls"])

    # 4b. THE HORIZON ARITHMETIC. The gate tolerance is 1.0 pg/cycle and it
    #     is easy to read a pass as "no leak"; these numbers are what make
    #     that unreadable. Pinned to the brief's own figures so a change to
    #     CYCLE_SECONDS cannot silently rescale the requirement.
    bph, mibd, giby = horizon(1.0)
    check("horizon: 1.0 pg/cycle is ~500 kB/hour",
          abs(bph - 500000) < 60000, "%.0f B/h" % bph)
    check("horizon: 1.0 pg/cycle is ~12 MB/day",
          abs(mibd - 12.0) < 1.5, "%.1f MiB/day" % mibd)
    check("horizon: 1.0 pg/cycle is ~4 GB/year (a gate PASS that still "
          "reboots the box)", abs(giby - 4.3) < 0.6, "%.2f GiB/yr" % giby)
    check("horizon: zero slope extrapolates to zero",
          horizon(0.0) == (0.0, 0.0, 0.0), "%s" % (horizon(0.0),))

    # 5. End-to-end through the log parser, including a PgSite line.
    body = []
    for i in range(20):
        body.append("SOAKSMP_%d_closed_B" % i)
        body.append("MemFree: %d kB" % (900000 - 40 * i))
        body.append("PgSite11: %d %d %d" % (100 + 9 * i, 500 + 20 * i, 400 + 11 * i))
        # KmSite carries FOUR columns; a 4-column line must NOT fall through
        # to the generic .c0/.c1 naming, or a kernel-heap leak would be
        # reported under a name no human recognises.
        body.append("KmSite1: %d %d %d %d"
                    % (200 + 5 * i, (200 + 5 * i) * 64,
                       900 + 30 * i, 700 + 25 * i))
        body.append("SOAKSMP_%d_closed_E" % i)
    parsed = parse("\n".join(body).replace("SOAKSMP_%d_closed" % 0,
                                           "SOAKSMP_0_closed"))
    # labels are per-sample unique, so match on the shared substring
    sel = [v for l, v in parsed if "closed" in l]
    check("parser: 20 samples recovered", len(sel) == 20, "n=%d" % len(sel))
    kmkey = "KmSite1:vfs.live"
    check("parser: KmSite 4 columns named", kmkey in (sel[0] if sel else {}),
          "keys=%s" % sorted(k for k in (sel[0] if sel else {})
                             if k.startswith("KmSite")))
    if sel and kmkey in sel[0]:
        rk = analyse([v[kmkey] for v in sel])
        check("parser: kmalloc vfs.live slopes to +5",
              abs(rk["steady"] - 5) < 0.6, "steady=%.2f" % rk["steady"])
        rb = analyse([v["KmSite1:vfs.bytes"] for v in sel])
        check("parser: kmalloc vfs.bytes slopes to +320 (5 objs x 64 B)",
              abs(rb["steady"] - 320) < 40, "steady=%.2f" % rb["steady"])
    key = "PgSite11:cow_resolve_pte.live"
    check("parser: PgSite columns named", key in (sel[0] if sel else {}),
          "keys=%s" % sorted(sel[0])[:3] if sel else "")
    if sel and key in sel[0]:
        r5 = analyse([v[key] for v in sel])
        check("parser: cow_resolve_pte.live slopes to +9",
              abs(r5["steady"] - 9) < 0.5, "steady=%.2f" % r5["steady"])

    print("\nselftest: %d failure(s)" % len(fails))
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", nargs="?")
    ap.add_argument("--label", default="closed")
    ap.add_argument("--warmup", type=int, default=1)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.log:
        ap.error("a log path is required (or --selftest)")
    text = open(a.log, "rb").read().decode("utf-8", "replace")
    return report(parse(text), a.label, a.warmup, a.all, a.json)


if __name__ == "__main__":
    sys.exit(main())
