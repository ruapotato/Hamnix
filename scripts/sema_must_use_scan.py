#!/usr/bin/env python3
"""Whole-tree UNCHECKED-RESULT scan for `# must_use` callees.

WHY A DEDICATED SCANNER AND NOT `sema_scan.py --mode entry`.  The per-entry
sweep resolves link units by finding modules with a top-level `def main`.
The KERNEL has none — its entry is `kmain` — so the entire kernel, every
driver and all of `sys/src/9` are invisible to it.  For the argument- and
pointer-type classes that is acceptable (they need a resolved link unit to
say anything).  `must-use` does NOT: the annotation lives on the callee's
`def` and the violation is a bare-statement call, both of which are purely
syntactic.  Resolving callee names whole-tree therefore sees strictly more
than entry mode, and it is what found the `devwsys_keys_write` short-write
and the `napi_register` never-polled-RX-queue.

The marker grammar is NOT re-implemented here — it is read through
`sema.annotations_of`, so the compiler and this scanner can never disagree
about what is annotated.

    python3 scripts/sema_must_use_scan.py                  # report
    python3 scripts/sema_must_use_scan.py --baseline FILE  # gate (shrink-only)
    python3 scripts/sema_must_use_scan.py --emit-baseline  # regenerate

BASELINE KEYS ARE LINE-FREE.  A site is `<file>::<caller>::<callee>`, not a
line number, because line numbers churn on every edit above them and a
baseline that churns is a baseline nobody re-reads.  The consequence is that
a SECOND unchecked call to the same callee from the same caller is not a new
key; that is a deliberate trade for a file that stays diffable.
"""

import argparse
import multiprocessing
import os
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from adder.compiler import sema                                  # noqa: E402
from adder.compiler.ast_nodes import (                           # noqa: E402
    CallExpr, DeferStmt, ExprStmt, ExternDecl, FunctionDef, Identifier,
)
from adder.compiler.parser import parse                          # noqa: E402

DEFAULT_DIRS = ["kernel", "mm", "fs", "net", "drivers", "arch", "lib", "user",
                "sys", "init", "linux_abi", "memory", "mod", "examples",
                "adder/compiler", "packages", "etc", "n", "tests"]
SKIP_PARTS = {".git", "build", "__pycache__", ".claude"}

# NEGATIVE FIXTURES. tests/sema/*.ad exist precisely to violate this check
# (they are the fixtures of scripts/test_adder_must_use.sh), so their sites
# are the gate working, not debt. Same exclusion sema_scan.py applies.
NEGATIVE_FIXTURES = ("tests/sema/",)


def iter_files(roots):
    for root in roots:
        base = PROJECT_ROOT / root
        if not base.exists():
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_PARTS]
            for fn in sorted(filenames):
                if fn.endswith(".ad"):
                    yield Path(dirpath) / fn


def _walk(body, in_defer=False):
    """Every statement, flagged with whether it is inside a `defer`."""
    for st in body or []:
        yield st, in_defer
        d = in_defer or isinstance(st, DeferStmt)
        for attr in ("body", "then_body", "else_body"):
            v = getattr(st, attr, None)
            if isinstance(v, list):
                yield from _walk(v, d)
        for _cond, b in getattr(st, "elif_branches", []) or []:
            yield from _walk(b, d)
        for arm in getattr(st, "arms", []) or []:
            b = getattr(arm, "body", None)
            if isinstance(b, list):
                yield from _walk(b, d)
        inner = getattr(st, "stmt", None)
        if inner is not None:
            yield from _walk([inner], d)


def _extract(rel):
    """Parse ONE file: its annotated defs and its bare-statement calls."""
    path = PROJECT_ROOT / rel
    try:
        prog = parse(path.read_text(errors="replace"), str(path))
    except Exception as exc:                                # noqa: BLE001
        return rel, None, None, "%s" % exc
    annotated, calls = {}, []
    for d in prog.declarations:
        if isinstance(d, (FunctionDef, ExternDecl)):
            ann = sema.annotations_of(d)
            if "must_use" in ann:
                annotated[d.name] = (ann["must_use"],
                                     getattr(d.span, "start_line", 0))
        if not isinstance(d, FunctionDef):
            continue
        for st, in_defer in _walk(d.body):
            if in_defer:
                continue
            if not isinstance(st, ExprStmt):
                continue
            e = st.expr
            if not isinstance(e, CallExpr) or not isinstance(e.func,
                                                             Identifier):
                continue
            line = getattr(st.span, "start_line", 0)
            if sema._line_optout(st.span, "ignore-result",
                                 "must_use: ignore", "must-use: ignore"):
                continue
            calls.append((e.func.name, d.name, line))
    return rel, annotated, calls, None


def scan(roots, jobs):
    rels = sorted(r for r in (str(p.relative_to(PROJECT_ROOT))
                              for p in iter_files(roots))
                  if not r.startswith(NEGATIVE_FIXTURES))
    if jobs > 1:
        ctx = multiprocessing.get_context("fork")
        with ctx.Pool(jobs) as pool:
            results = pool.map(_extract, rels, chunksize=8)
    else:
        results = [_extract(r) for r in rels]

    annotated, fails = {}, []
    for rel, ann, _calls, err in results:
        if err is not None:
            fails.append((rel, err))
            continue
        for name, (reason, line) in ann.items():
            annotated[name] = (reason, rel, line)

    sites = []
    for rel, _ann, calls, err in results:
        if err is not None:
            continue
        for callee, caller, line in calls:
            if callee in annotated:
                sites.append((rel, caller, callee, line))
    sites.sort()
    return annotated, sites, fails, len(rels)


def key_of(site):
    rel, caller, callee, _line = site
    return "%s::%s::%s" % (rel, caller, callee)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("roots", nargs="*", default=None)
    ap.add_argument("--jobs", "-j", type=int,
                    default=min(12, (os.cpu_count() or 4)))
    ap.add_argument("--baseline", default=None,
                    help="accepted-sites file; exit non-zero on any site "
                         "NOT in it (the list is SHRINK-ONLY)")
    ap.add_argument("--emit-baseline", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    annotated, sites, fails, n_files = scan(args.roots or DEFAULT_DIRS,
                                            args.jobs)

    if args.emit_baseline:
        for k in sorted({key_of(s) for s in sites}):
            print(k)
        return 0

    if not args.quiet:
        print("files parsed: %d (%d parse failures)" % (n_files, len(fails)))
        print("`# must_use` functions: %d" % len(annotated))
        print("unchecked-result sites: %d in %d distinct caller/callee pairs"
              % (len(sites), len({key_of(s) for s in sites})))
        print()
        by_callee: dict = {}
        for s in sites:
            by_callee.setdefault(s[2], []).append(s)
        for callee in sorted(by_callee, key=lambda c: -len(by_callee[c])):
            reason, arel, aline = annotated[callee]
            print("%4d  %s   (declared %s:%d)"
                  % (len(by_callee[callee]), callee, arel, aline))
            print("      %s" % reason)
            for rel, caller, _c, line in by_callee[callee]:
                print("        %s:%d  in %s()" % (rel, line, caller))
            print()

    rc = 0
    if args.baseline:
        known = set()
        for raw in Path(args.baseline).read_text().splitlines():
            raw = raw.split("#", 1)[0].strip()
            if raw:
                known.add(raw)
        seen = {key_of(s) for s in sites}
        new = sorted(seen - known)
        gone = sorted(known - seen)
        print("=" * 78)
        print("baseline %s: %d known, %d new, %d resolved"
              % (args.baseline, len(known), len(new), len(gone)))
        if gone:
            print("  RESOLVED (delete these lines from the baseline):")
            for k in gone:
                print("    %s" % k)
        for k in new:
            rel, caller, callee = k.split("::")
            line = min(s[3] for s in sites if key_of(s) == k)
            reason = annotated[callee][0]
            print("  NEW UNCHECKED RESULT: %s:%d — %s() drops the result of "
                  "%s()" % (rel, line, caller, callee))
            print("      %s" % reason)
        if new or gone:
            print("FAIL: %d new unchecked-result site(s), %d stale baseline "
                  "entr%s" % (len(new), len(gone),
                              "y" if len(gone) == 1 else "ies"))
            rc = 1
        else:
            print("ok: no new unchecked-result sites")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
