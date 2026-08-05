#!/usr/bin/env python3
"""SSA-subset coverage census over the real Adder tree.

Runs the host dump driver's `--dump-ssa` analysis lane (build + verify SSA for
every function, never emits code) over every .ad source in the tree and adds up
the accept/fallback counts plus the per-reason and per-CALL-SITE bail
histograms.

Why per-site: SBR_MEMORY alone covers ~40 distinct subset gates, so a per-reason
histogram cannot tell you which construct to implement next.  The site numbers
are the literal `ssa_set_bail_at(REASON, <site>)` arguments in
adder/compiler/ssa.ad, so a hot site maps straight to a line of code.

Usage:
    python3 scripts/ssa_subset_census.py [--kernel] [--json out.json]
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DRIVER = REPO / "build" / "fuzz_ad_codegen" / "ad_codegen_dump"

# Directories that make up the KERNEL proper (as opposed to userland/browser/
# tests/compiler).  arch/arm64 is excluded: that lane is LLVM-only.
KERNEL_DIRS = [
    "kernel", "mm", "fs", "net", "drivers", "sys", "init", "memory", "mod",
    "arch/x86", "linux_abi",
]

SBR = {
    0: "OK", 1: "OVERFLOW", 2: "NONSUBSET_EXPR", 3: "NONSUBSET_STMT",
    4: "NONLOCAL", 5: "NONPROMOTABLE", 6: "LOOPDEPTH", 7: "CFG", 8: "FLOAT",
    9: "FORLOOP", 10: "SHORTCIRCUIT", 11: "MEMORY", 12: "MANYARGS",
    13: "CALL",
}


# Human labels for the bail sites that needed explaining.  The 100-block is the
# SUB-ATTRIBUTION of the old blended site 34 (non-local ND_IDENT rvalue), added
# 2026-08-04 because "site 34" alone could not distinguish an array global from
# an undeclared name — and the answer turned out to be neither.
#
# MEASUREMENT CAVEAT (read before acting on a site-34 number): the census
# compiles each .ad file STANDALONE, while a real build import-MERGES the whole
# module closure into one TU.  A global or function defined in another module is
# therefore invisible here and bails at site 34, even though the real compiler
# resolves it.  Site 34's residual is an upper bound, not a subset gap.
SITE_NOTES = {
    34: "non-local ident: name unknown in this TU (see caveat in this file)",
    47: "obj.field member access (needs struct typing on the native path)",
    56: "local Array[N,T] (no memory model armed)",
    63: "float scalar local (SSE, native path)",
    66: "RETIRED 2026-08-05 -- was 'address-taken scalar local, native path'; "
        "split into 104/105 and then MODELLED (see ssa_mem_native)",
    79: "call with >6 arguments (native SysV round-trip spills 6)",
    92: "callee is not a provably resolvable direct-call symbol (whitelist)",
    100: "non-local ident: aggregate/array global",
    101: "non-local ident: Percpu[T] scalar, native path",
    102: "non-local ident: Percpu[aggregate]",
    103: "non-local ident: bare function name (address decay)",
    104: "non-promotable scalar: TRUE `&x` escape (cl_set)",
    105: "non-promotable scalar: slot-read only, address never escapes",
}

# READ THIS BEFORE PICKING A TARGET FROM THE HISTOGRAM BELOW.
#
# The per-site counts are FIRST-BAIL counts: ssa_build_function stops at the
# first gate a function trips, so a site's share is an UPPER BOUND on what
# closing it can win, never the win itself.  Measured 2026-08-05: site 66 was
# 36.9% of all bails and the largest single gap.  Implementing it alone moved
# the accepted subset 36.65% -> 36.78% (+27 of 21281 functions), because the
# same functions immediately re-bailed at `*p` / `p[i]` / a local array / a
# string literal.  Opening those together took it to 61.15%.
#
# So read a hot site as "which CLUSTER of constructs is in the way", and close
# the cluster.  Then re-measure -- the histogram after a landing looks nothing
# like the histogram before it.


def sources(kernel_only):
    roots = KERNEL_DIRS if kernel_only else ["."]
    out = []
    for r in roots:
        for p in sorted((REPO / r).rglob("*.ad")):
            rel = p.relative_to(REPO).as_posix()
            if rel.startswith((".git/", "build/")):
                continue
            out.append(p)
    return sorted(set(out))


def run(files):
    funcs = accepted = fallback = 0
    parsefail = []
    reasons, sites = {}, {}
    for f in files:
        try:
            r = subprocess.run([str(DRIVER), "--dump-ssa", str(f)],
                               capture_output=True, text=True, timeout=600)
        except subprocess.TimeoutExpired:
            parsefail.append((f, "timeout"))
            continue
        txt = r.stdout
        if "STATUS parsefail" in txt or "AC_DUMP_END" not in txt:
            parsefail.append((f, txt.strip().splitlines()[-2:] or ["?"]))
            continue
        base_r, base_s = dict(reasons), dict(sites)
        for line in txt.splitlines():
            p = line.split()
            if not p:
                continue
            if p[0] == "SSA_FUNCS":
                funcs += int(p[1])
            elif p[0] == "SSA_ACCEPTED":
                accepted += int(p[1])
            elif p[0] == "SSA_FALLBACK":
                fallback += int(p[1])
            elif p[0] == "SSA_BAILREASON":
                # hists are cumulative within a process, not across; each run is
                # a fresh process so these are per-FILE totals.
                reasons[int(p[1])] = base_r.get(int(p[1]), 0) + int(p[2])
            elif p[0] == "SSA_BAILSITE":
                sites[int(p[1])] = base_s.get(int(p[1]), 0) + int(p[2])
    return dict(funcs=funcs, accepted=accepted, fallback=fallback,
                reasons=reasons, sites=sites, parsefail=parsefail)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", action="store_true")
    ap.add_argument("--json")
    ap.add_argument("--top", type=int, default=25)
    a = ap.parse_args()
    if not DRIVER.exists():
        sys.exit("driver not built: python3 -c \"import sys;"
                 "sys.path.insert(0,'tests/fuzz');import ad_codegen_host as h;"
                 "h.build_driver()\"")
    files = sources(a.kernel)
    res = run(files)
    scope = "KERNEL" if a.kernel else "WHOLE TREE"
    f, acc = res["funcs"], res["accepted"]
    pct = (100.0 * acc / f) if f else 0.0
    print(f"=== SSA subset census: {scope} ===")
    print(f"files scanned      : {len(files)} "
          f"({len(res['parsefail'])} unparseable/skipped)")
    print(f"functions           : {f}")
    print(f"accepted into subset: {acc}  ({pct:.2f}%)")
    print(f"fell back to legacy : {res['fallback']}")
    print("\n-- bail reasons --")
    for k, v in sorted(res["reasons"].items(), key=lambda kv: -kv[1]):
        print(f"  SBR_{SBR.get(k, k):<16} {v:6d}  "
              f"{100.0*v/max(1,res['fallback']):5.1f}%")
    print(f"\n-- top {a.top} bail SITES (ssa_set_bail_at arg in ssa.ad) --")
    for k, v in sorted(res["sites"].items(), key=lambda kv: -kv[1])[:a.top]:
        note = SITE_NOTES.get(k, "")
        print(f"  site {k:<4} {v:6d}  {100.0*v/max(1,res['fallback']):5.1f}%"
              f"{('  ' + note) if note else ''}")
    if a.json:
        res["parsefail"] = [str(p[0]) for p in res["parsefail"]]
        Path(a.json).write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
