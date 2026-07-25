#!/usr/bin/env python3
"""Run the Adder type checker (adder/compiler/sema.py) over the whole tree.

This is the measurement tool behind the checker's severity policy: it reports
how many sites in the existing ~905k-line corpus each diagnostic CLASS flags,
which is what decides whether a class can be a hard error today or has to
warn until the tree catches up.

    python3 scripts/sema_scan.py                 # whole tree, counts only
    python3 scripts/sema_scan.py --show arity    # print the actual diagnostics
    python3 scripts/sema_scan.py kernel mm       # restrict to some subtrees

Method: parse every `.ad` file once, apply the same module-private name
scoping the real compiler applies (`resolve_module_scopes`), then merge into
one program and check it. That is one whole-program check rather than one per
entry point, so a PUBLIC name defined incompatibly in two never-linked
modules would be a false positive — such names are dropped from the callee
table instead (reported as `ambiguous`).
"""

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from adder.compiler import sema                                  # noqa: E402
from adder.compiler.adder import resolve_module_scopes, _module_name_for  # noqa: E402
from adder.compiler.ast_nodes import (                           # noqa: E402
    ExternDecl, FunctionDef, Program,
)
from adder.compiler.parser import parse                          # noqa: E402

DEFAULT_DIRS = ["kernel", "mm", "fs", "net", "drivers", "arch", "lib", "user",
                "sys", "init", "linux_abi", "memory", "mod", "examples",
                "adder/compiler", "packages", "etc", "n"]

SKIP_PARTS = {".git", "build", "__pycache__", ".claude"}


def _sig(decl):
    """Signature fingerprint: parameter type names + return type name.

    Two modules that both define a public `module_load` — one taking
    `Ptr[uint8]`, one taking `int32` — are never linked together, so keeping
    either signature invents argument-type errors in the other module.
    """
    return (tuple(_type_name(p.param_type) for p in decl.params),
            _type_name(decl.return_type))


def _type_name(t):
    return getattr(t, "name", None) if t is not None else None


def iter_files(roots, project_root):
    for root in roots:
        base = project_root / root
        if not base.exists():
            continue
        if base.is_file():
            yield base
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_PARTS]
            for fn in sorted(filenames):
                if fn.endswith(".ad"):
                    yield Path(dirpath) / fn


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("roots", nargs="*", default=None)
    ap.add_argument("--show", default=None,
                    help="comma-separated classes whose diagnostics to print "
                         "(or 'all')")
    ap.add_argument("--limit", type=int, default=40,
                    help="max diagnostics to print per shown class")
    args = ap.parse_args()

    project_root = Path(__file__).resolve().parent.parent
    roots = args.roots or DEFAULT_DIRS

    programs, parse_fails = [], 0
    for path in iter_files(roots, project_root):
        try:
            prog = parse(path.read_text(errors="replace"), str(path))
        except Exception as exc:                       # noqa: BLE001
            parse_fails += 1
            print("parse-skip %s: %s" % (path, exc), file=sys.stderr)
            continue
        prog.module = _module_name_for(path, project_root)
        for decl in prog.declarations:
            if hasattr(decl, "module"):
                decl.module = prog.module
        programs.append(prog)

    resolve_module_scopes(programs)

    # Merge. A public name defined more than once with a DIFFERENT signature
    # belongs to two modules that are never linked together in one program;
    # drop it rather than invent arity errors.
    by_name, ambiguous = {}, set()
    order = []
    for prog in programs:
        for d in prog.declarations:
            name = getattr(d, "name", None)
            if name is None:
                order.append(d)
                continue
            prev = by_name.get(name)
            if prev is None:
                by_name[name] = d
                order.append(d)
                continue
            # Same PUBLIC name in two modules. The real compiler hard-errors
            # on this when both are actually linked (adder.py merge_programs),
            # so in a whole-tree scan it means these two modules are never
            # compiled together — e.g. `line_len: uint64` in user/sed.ad and
            # `line_len: Ptr[uint8]` in another app. Keeping either one
            # contaminates every reference in the OTHER module, so drop the
            # name unless the two decls agree.
            if isinstance(d, (FunctionDef, ExternDecl)) and \
                    isinstance(prev, (FunctionDef, ExternDecl)):
                if _sig(d) != _sig(prev):
                    ambiguous.add(name)
                continue
            if type(d) is not type(prev) or \
                    _type_name(getattr(d, "var_type", None)) != \
                    _type_name(getattr(prev, "var_type", None)):
                ambiguous.add(name)

    merged = Program(imports=[], declarations=[
        d for d in order
        if getattr(d, "name", None) not in ambiguous])

    policy = {c: "warning" for c in sema.CLASSES}       # measure EVERYTHING
    diags, counts = sema.check_program(merged, policy=policy,
                                       max_diagnostics=10 ** 9)

    print("files parsed: %d (%d parse failures)"
          % (len(programs), parse_fails))
    print("ambiguous public names dropped: %d" % len(ambiguous))
    print("declarations checked: %d" % len(merged.declarations))
    print()
    print("%-14s %8s   %s" % ("class", "sites", "default severity"))
    print("-" * 52)
    for cls in sema.CLASSES:
        print("%-14s %8d   %s"
              % (cls, counts.get(cls, 0), sema.DEFAULT_SEVERITY[cls]))
    print("-" * 52)
    print("%-14s %8d" % ("TOTAL", sum(counts.values())))

    if args.show:
        want = (set(sema.CLASSES) if args.show == "all"
                else set(args.show.split(",")))
        shown = {}
        print()
        for d in diags:
            if d.cls not in want:
                continue
            n = shown.get(d.cls, 0)
            if n >= args.limit:
                continue
            shown[d.cls] = n + 1
            print(sema.render(d))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
