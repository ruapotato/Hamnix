#!/usr/bin/env python3
"""Run the Adder type checker (adder/compiler/sema.py) over the whole tree.

THREE modes, because the original one-program-for-the-whole-tree merge was
STRUCTURALLY BLIND to the bug class that hurt most:

  entry      (default) — resolve PER ENTRY POINT. For every module with a
                         `def main`, take its real import closure
                         (`collect_all_imports` -> `merge_programs`, the exact
                         path the compiler takes) and check that link unit.
                         A symbol is therefore checked in the programs it
                         actually appears in, with the signature that link
                         unit actually sees.
  conflicts            — whole-tree SIGNATURE-CONFLICT detector: every public
                         name whose DECLARATIONS disagree across modules
                         (arity or parameter/return types), with all sites,
                         classified LIVE (the disagreeing modules co-occur in
                         some real link unit — a live miscompile) vs LANDMINE
                         (they never co-occur today; nothing stops them).
  merged               — the legacy whole-tree merge, kept only for the
                         corpus-wide per-class site counts that inform
                         severity policy. UNSOUND for finding bugs: it drops
                         every ambiguous public name, which is exactly the
                         bug class `conflicts` reports.

Why the old default lied: `sys_open` was declared 1-arg in `runtime.S`'s
extern and 3-arg in `linux-runtime.S`'s. In one merged program that is two
decls for one symbol; the merge kept one and DROPPED the name from the
callee table, so `sema_scan` reported 0 arity errors tree-wide while a real
per-entry-point sweep found 36 arity errors in 14 files.

    python3 scripts/sema_scan.py                    # per-entry sweep
    python3 scripts/sema_scan.py --mode conflicts   # signature conflicts
    python3 scripts/sema_scan.py --mode conflicts --fail-on live
    python3 scripts/sema_scan.py --show arity       # print the diagnostics
    python3 scripts/sema_scan.py --mode merged      # legacy class counts
    python3 scripts/sema_scan.py kernel lib         # restrict to subtrees
"""

import argparse
import fnmatch
import multiprocessing
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from adder.compiler import sema                                  # noqa: E402
from adder.compiler.adder import (                               # noqa: E402
    collect_all_imports, merge_programs, resolve_import,
    resolve_module_scopes, _module_name_for,
)
from adder.compiler.ast_nodes import (                           # noqa: E402
    ExternDecl, FunctionDef, Program, VarDecl,
)
from adder.compiler.parser import parse                          # noqa: E402

DEFAULT_DIRS = ["kernel", "mm", "fs", "net", "drivers", "arch", "lib", "user",
                "sys", "init", "linux_abi", "memory", "mod", "examples",
                "adder/compiler", "packages", "etc", "n", "tests"]

SKIP_PARTS = {".git", "build", "__pycache__", ".claude"}

PROJECT_ROOT = Path(__file__).resolve().parent.parent


# --------------------------------------------------------------------------
# shared helpers
# --------------------------------------------------------------------------

def _type_name(t):
    return getattr(t, "name", None) if t is not None else None


def _sig(decl):
    """Signature fingerprint: parameter type names + return type name."""
    return (tuple(_type_name(p.param_type) for p in decl.params),
            _type_name(decl.return_type))


def _sig_text(sig):
    params, ret = sig
    return "(%s) -> %s" % (", ".join(str(p) for p in params),
                           ret if ret is not None else "None")


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


def _scan_policy():
    """Measure EVERY class, but keep the real error/warning split.

    `off` classes are turned on as warnings so the counts stay comparable
    with the legacy scan; classes that are errors by default stay errors so
    "did this link unit fail to type-check?" means the same thing here as in
    a real `adder compile`.
    """
    return {c: (sema.DEFAULT_SEVERITY[c]
                if sema.DEFAULT_SEVERITY[c] != "off" else "warning")
            for c in sema.CLASSES}


def _rel(p):
    try:
        return str(Path(p).resolve().relative_to(PROJECT_ROOT))
    except (ValueError, OSError):
        return str(p)


# --------------------------------------------------------------------------
# whole-tree parse (one pass, reused by `conflicts` and `merged`)
# --------------------------------------------------------------------------

def _extract_file(rel_path):
    """Parse ONE file and return only what conflict detection needs.

    Runs in a worker process, so the return value is deliberately tiny
    (tuples of strings/ints, no AST) — shipping whole ASTs back through a
    pickle would cost more than the parse.
    """
    path = _WORKER_ROOT / rel_path
    try:
        prog = parse(path.read_text(errors="replace"), str(path))
    except Exception as exc:                           # noqa: BLE001
        return rel_path, None, "%s" % exc
    imports = [(imp.module, tuple(imp.names)) for imp in prog.imports]
    decls, has_main = [], False
    for d in prog.declarations:
        name = getattr(d, "name", None)
        if not name:
            continue
        line = getattr(getattr(d, "span", None), "start_line", 0)
        if isinstance(d, ExternDecl):
            decls.append(("extern", name, ("fn", _sig(d)), line))
        elif isinstance(d, FunctionDef):
            if name == "main":
                has_main = True
            decls.append(("def", name, ("fn", _sig(d)), line))
        elif isinstance(d, VarDecl):
            decls.append(("var", name,
                          ("var", _type_name(getattr(d, "var_type", None))),
                          line))
    return rel_path, (_module_name_for(path, _WORKER_ROOT), imports, decls,
                      has_main), None


def extract_tree(roots, project_root, jobs):
    """Parallel one-parse-per-file extract of the whole tree."""
    rels = sorted(_rel(p) for p in iter_files(roots, project_root))
    out, fails = {}, []
    if jobs > 1:
        ctx = multiprocessing.get_context("fork")
        with ctx.Pool(jobs, initializer=_init_worker,
                      initargs=(project_root,)) as pool:
            results = pool.map(_extract_file, rels, chunksize=8)
    else:
        _init_worker(project_root)
        results = [_extract_file(r) for r in rels]
    for rel_path, data, err in results:
        if err is not None:
            fails.append((rel_path, err))
            continue
        out[rel_path] = data
    return out, fails


def parse_tree(roots, project_root, quiet=False):
    """Parse every `.ad` file under `roots` once.

    Returns (programs, files, parse_fails) with `.module` set and the real
    module-private scoping applied, so grouping by declaration name uses the
    compiler's own notion of which names are global.
    """
    programs, files, parse_fails = [], [], 0
    for path in iter_files(roots, project_root):
        try:
            prog = parse(path.read_text(errors="replace"), str(path))
        except Exception as exc:                       # noqa: BLE001
            parse_fails += 1
            if not quiet:
                print("parse-skip %s: %s" % (path, exc), file=sys.stderr)
            continue
        prog.module = _module_name_for(path, project_root)
        for decl in prog.declarations:
            if hasattr(decl, "module"):
                decl.module = prog.module
        programs.append(prog)
        files.append(path)

    resolve_module_scopes(programs)
    return programs, files, parse_fails


def entry_points(extracts):
    """Files that define a top-level `main` — one link unit each."""
    return sorted(r for r, d in extracts.items() if d[3])


def import_closures(extracts, project_root, entries):
    """Per-entry import closure, computed from ONE parse of the tree.

    Same resolution rule as `collect_all_imports` (module path resolved
    against the project root, unresolvable imports ignored), but over a
    prebuilt graph, so classifying conflicts costs one parse of each file
    instead of re-parsing every closure hundreds of times.
    """
    cache = {}

    def _resolve(mod):
        if mod not in cache:
            try:
                cache[mod] = _rel(resolve_import(mod, project_root))
            except FileNotFoundError:
                cache[mod] = None
        return cache[mod]

    edges = {}
    for rel_path, (_mod, imports, _decls, _has_main) in extracts.items():
        deps = set()
        for mod, _names in imports:
            r = _resolve(mod)
            if r is not None:
                deps.add(r)
        edges[rel_path] = deps

    closures = {}
    for entry in entries:
        seen, stack = set(), [entry]
        while stack:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            stack.extend(d for d in edges.get(cur, ()) if d not in seen)
        closures[entry] = seen
    return closures


# --------------------------------------------------------------------------
# mode: conflicts — the dedicated signature-conflict detector
# --------------------------------------------------------------------------
#
# Visibility model, copied from compiler/adder.py `resolve_module_scopes`:
#
#   * a top-level name NOT starting with `_` is PUBLIC — one global symbol;
#   * a `_`-prefixed name is MODULE-PRIVATE and mangled to
#     `<module_slug>_<name>`, so two modules' `_helper`s never collide;
#   * UNLESS some module in the same program does `from M import _helper`,
#     or `_helper` is declared `extern` — either promotes it back to public.
#
# The promotion set is per-PROGRAM, so a `_`-prefixed name can be private in
# one link unit and public in another. LIVE classification therefore
# recomputes the promotion set inside each link unit; the whole-tree
# catalogue uses the union (a name promoted anywhere can collide somewhere).


def _exported_names(extracts, scope):
    """Names promoted to public within `scope` (a set of rel paths)."""
    out = set()
    for rel_path in scope:
        data = extracts.get(rel_path)
        if data is None:
            continue
        _mod, imports, decls, _has_main = data
        for _m, names in imports:
            out.update(names)
        for kind, name, _shape, _line in decls:
            if kind == "extern":
                out.add(name)
    return out


def _resolved_name(module, kind, name, exported):
    """The global symbol a declaration contributes, after private scoping."""
    if kind == "extern" or not name.startswith("_") or name in exported:
        return name
    return "%s%s" % (module.replace(".", "_"), name)


def find_conflicts(extracts):
    """Public names whose declarations disagree across modules.

    Returns {name: [(shape, rel_path, line, kind), ...]} for every name with
    more than one distinct declaration shape, using the whole-tree promotion
    set (the widest reading of "public").
    """
    exported = _exported_names(extracts, extracts.keys())
    decls = {}
    for rel_path, (module, _imports, dl, _hm) in extracts.items():
        for kind, name, shape, line in dl:
            key = _resolved_name(module, kind, name, exported)
            decls.setdefault(key, []).append((shape, rel_path, line, kind))
    return {n: sites for n, sites in decls.items()
            if len({s[0] for s in sites}) > 1}


def classify_conflicts(extracts, conflicts, closures):
    """LIVE if two disagreeing decls co-occur in ONE link unit.

    LIVE means a real program today contains both spellings of the symbol.
    `merge_programs` keeps the first and silently drops the rest, so every
    call compiled against the dropped spelling uses the wrong ABI — that is
    the `sys_open` bug verbatim (1-arg device extern vs 3-arg host extern:
    the call set only %rdi and open(2) read garbage flags/mode).
    LANDMINE means no link unit sees both spellings today; nothing prevents
    one from doing so tomorrow, and the compiler would not say a word.

    A conflict can only be live under the CLOSURE's promotion set, which is
    a subset of the whole tree's, so this re-resolves names per closure.
    """
    # Which files declare each conflicting name, and under which spelling.
    sites_by_name = {}
    for name, sites in conflicts.items():
        by_file = {}
        for shape, rel_path, _line, kind in sites:
            by_file.setdefault(rel_path, set()).add((shape, kind))
        sites_by_name[name] = by_file

    out = {}
    live_units = {n: [] for n in conflicts}
    for entry, closure in closures.items():
        exported = None
        for name, by_file in sites_by_name.items():
            touched = [(f, sh) for f, sh in by_file.items() if f in closure]
            if len(touched) < 2:
                continue
            if name.startswith("_"):
                # Private unless promoted INSIDE this link unit; an extern
                # site is never mangled and so is always public.
                if exported is None:
                    exported = _exported_names(extracts, closure)
                if name not in exported and not any(
                        k == "extern" for _f, shs in touched for _s, k in shs):
                    continue
            shapes = {s for _f, shs in touched for s, _k in shs}
            if len(shapes) > 1:
                live_units[name].append(entry)

    for name in conflicts:
        units = live_units[name]
        out[name] = ("LIVE" if units else "LANDMINE", units)
    return out


def _arities(sites):
    return sorted({len(s[0][1][0]) for s in sites if s[0][0] == "fn"})


def _has_extern(sites):
    """True if any declaration is an `extern` — the ABI-crossing tier.

    An `extern def` names a REAL runtime symbol that every module shares, so
    two arities for one extern means at least one caller is provably setting
    the wrong registers. `sys_open` was in this tier; `sys_execve` still is.
    A conflict among plain `def`s is usually just two apps that each grew
    their own local helper with the same obvious name.
    """
    return any(s[3] == "extern" for s in sites)


def _conflict_report(conflicts, classes, limit=None):
    live = {n: v for n, v in classes.items() if v[0] == "LIVE"}
    mines = {n: v for n, v in classes.items() if v[0] == "LANDMINE"}

    def arity_conflict(name):
        return len(_arities(conflicts[name])) > 1

    lines = []
    for title, group in (
            ("LIVE — disagreeing decls co-occur in a real link unit "
             "(silent ABI mismatch)", live),
            ("LANDMINE — no link unit sees both spellings today", mines)):
        lines.append("=" * 78)
        lines.append("%s: %d" % (title, len(group)))
        lines.append("=" * 78)
        # Rank: ABI-crossing externs first, then arity conflicts, then by
        # how badly the declarations disagree.
        ordered = sorted(group,
                         key=lambda n: (not _has_extern(conflicts[n]),
                                        not arity_conflict(n),
                                        -len(_arities(conflicts[n])),
                                        -len({s[0] for s in conflicts[n]}),
                                        n))
        if limit:
            ordered = ordered[:limit]
        for name in ordered:
            sites = conflicts[name]
            ar = _arities(sites)
            tag = "arity %s" % (ar,) if len(ar) > 1 else "types"
            if _has_extern(sites):
                tag += ", extern/ABI"
            lines.append("")
            lines.append("%s  [%s]  %d decls, %d distinct signatures"
                         % (name, tag, len(sites), len({s[0] for s in sites})))
            # One line per DISTINCT signature, with its sites.
            by_shape = {}
            for shape, rel_path, line, kind in sites:
                by_shape.setdefault(shape, []).append((rel_path, line, kind))
            for shape in sorted(by_shape, key=lambda s: str(s)):
                where = sorted(by_shape[shape])
                text = (_sig_text(shape[1]) if shape[0] == "fn"
                        else ": %s" % shape[1])
                lines.append("    %-52s  %d site(s)" % (text, len(where)))
                for rel_path, line, kind in where[:6]:
                    lines.append("        %-6s %s:%d" % (kind, rel_path, line))
                if len(where) > 6:
                    lines.append("        ... %d more" % (len(where) - 6))
            units = group[name][1]
            if units:
                lines.append("    LIVE in %d link unit(s): %s%s"
                             % (len(units), ", ".join(units[:3]),
                                " ..." if len(units) > 3 else ""))
        lines.append("")
    return lines, live, mines


def run_conflicts(roots, project_root, jobs, fail_on=None, limit=None,
                  baseline=None, names_only=False):
    extracts, fails = extract_tree(roots, project_root, jobs)
    entries = entry_points(extracts)
    closures = import_closures(extracts, project_root, entries)
    conflicts = find_conflicts(extracts)
    classes = classify_conflicts(extracts, conflicts, closures)

    if names_only:
        for name in sorted(conflicts):
            print("%s %s" % (classes[name][0], name))
        return 0

    body, live, mines = _conflict_report(conflicts, classes, limit)

    def arity_conflict(name):
        return len(_arities(conflicts[name])) > 1

    print("files parsed: %d (%d parse failures)" % (len(extracts), len(fails)))
    print("entry points (link units): %d" % len(entries))
    print("conflicting public names: %d  (LIVE %d, LANDMINE %d)"
          % (len(conflicts), len(live), len(mines)))
    print("  of which ARITY conflicts: %d"
          % sum(1 for n in conflicts if arity_conflict(n)))
    print("  LIVE arity conflicts:     %d"
          % sum(1 for n in live if arity_conflict(n)))
    print("  extern/ABI conflicts:     %d"
          % sum(1 for n in conflicts if _has_extern(conflicts[n])))
    print()
    for ln in body:
        print(ln)

    rc = 0
    if baseline:
        known = {}
        for raw in Path(baseline).read_text().splitlines():
            raw = raw.split("#", 1)[0].strip()
            if not raw:
                continue
            parts = raw.split()
            known[parts[-1]] = parts[0] if len(parts) > 1 else "LANDMINE"
        new = sorted(set(conflicts) - set(known))
        gone = sorted(set(known) - set(conflicts))
        # A landmine that starts co-occurring in a real program has BECOME
        # the bug; that is a regression even though the name is not new.
        armed = sorted(n for n in conflicts
                       if n in known and known[n] == "LANDMINE"
                       and classes[n][0] == "LIVE")
        print("=" * 78)
        print("baseline %s: %d known, %d new, %d resolved, %d newly LIVE"
              % (baseline, len(known), len(new), len(gone), len(armed)))
        if gone:
            print("  RESOLVED (drop from the baseline): %s" % ", ".join(gone))
        for n in new:
            print("  NEW CONFLICT [%s]: %s" % (classes[n][0], n))
        for n in armed:
            print("  LANDMINE WENT LIVE: %s (link units: %s)"
                  % (n, ", ".join(classes[n][1][:3])))
        if new or armed:
            print("FAIL: %d new conflict(s), %d newly-live conflict(s)"
                  % (len(new), len(armed)))
            rc = 1
    if fail_on == "live" and live:
        print("FAIL: %d LIVE signature conflict(s)" % len(live))
        rc = 1
    if fail_on == "any" and conflicts:
        print("FAIL: %d signature conflict(s)" % len(conflicts))
        rc = 1
    return rc


# --------------------------------------------------------------------------
# mode: entry — per-entry-point resolution (the sound scan)
# --------------------------------------------------------------------------

_WORKER_ROOT = None


def _check_entry(rel_path):
    """Check ONE link unit. Runs in a worker process."""
    path = _WORKER_ROOT / rel_path
    try:
        all_files = collect_all_imports(path, _WORKER_ROOT)
        prog = merge_programs(all_files)
        diags, counts = sema.check_program(prog, policy=_scan_policy(),
                                           max_diagnostics=10 ** 9)
    except SystemExit as exc:                          # collect_all_imports
        return rel_path, None, "parse error (exit %s)" % exc.code, {}
    except Exception as exc:                           # noqa: BLE001
        return rel_path, None, "%s: %s" % (type(exc).__name__, exc), {}
    out = [(d.cls, d.severity, d.location(), d.message, sema.render(d))
           for d in diags]
    return rel_path, out, None, dict(counts)


def _init_worker(root):
    global _WORKER_ROOT
    _WORKER_ROOT = root


def run_entry(roots, project_root, jobs, show=None, limit=40,
              fail_on_error=True, entries_override=None, excludes=()):
    if entries_override is None:
        extracts, fails = extract_tree(roots, project_root, jobs)
        parse_fails = len(fails)
        rels = sorted(entry_points(extracts))
    else:
        parse_fails = 0
        rels = sorted(_rel(e) for e in entries_override)

    # NEGATIVE FIXTURES. tests/sema/*.ad and tests/app_sugar/err_*.ad exist
    # precisely to be rejected by this checker (they are the fixtures of
    # scripts/test_adder_sema.sh), so their diagnostics are the gate working,
    # not a regression. Excluded by path, both as entry points and as
    # diagnostic sites.
    def _excluded(rel_path):
        return any(fnmatch.fnmatch(rel_path, pat) for pat in excludes)

    n_excluded = sum(1 for r in rels if _excluded(r))
    rels = [r for r in rels if not _excluded(r)]

    print("link units (modules with `def main`): %d   jobs: %d"
          % (len(rels), jobs), flush=True)

    results = []
    if jobs > 1:
        ctx = multiprocessing.get_context("fork")
        with ctx.Pool(jobs, initializer=_init_worker,
                      initargs=(project_root,)) as pool:
            for i, r in enumerate(pool.imap_unordered(_check_entry, rels,
                                                      chunksize=1), 1):
                results.append(r)
                if i % 50 == 0:
                    print("  ... %d/%d" % (i, len(rels)), file=sys.stderr,
                          flush=True)
    else:
        _init_worker(project_root)
        for r in rels:
            results.append(_check_entry(r))

    # Dedup by SITE across link units: one bad call site reached from ten
    # entry points is one bug, not ten.
    seen, sites = set(), []
    counts, skipped = {}, []
    err_files = set()
    for rel_path, out, err, _c in results:
        if err is not None:
            skipped.append((rel_path, err))
            continue
        for cls, sev, loc, msg, rendered in out:
            key = (cls, loc, msg)
            if key in seen:
                continue
            if _excluded(_rel(loc.rsplit(":", 2)[0])):
                continue
            seen.add(key)
            sites.append((cls, sev, loc, msg, rendered, rel_path))
            counts[cls] = counts.get(cls, 0) + 1
            if sev == "error":
                err_files.add(loc.rsplit(":", 2)[0])

    errors = [s for s in sites if s[1] == "error"]

    print()
    print("link units checked: %d (%d unresolvable, %d parse failures, "
          "%d negative fixtures excluded)"
          % (len(rels) - len(skipped), len(skipped), parse_fails, n_excluded))
    print("unique diagnostic sites: %d" % len(sites))
    print()
    print("%-16s %8s   %s" % ("class", "sites", "default severity"))
    print("-" * 54)
    for cls in sema.CLASSES:
        print("%-16s %8d   %s"
              % (cls, counts.get(cls, 0), sema.DEFAULT_SEVERITY[cls]))
    print("-" * 54)
    print("%-16s %8d" % ("TOTAL", sum(counts.values())))
    print()
    print("ERROR-severity sites: %d in %d file(s)"
          % (len(errors), len(err_files)))
    by_cls = {}
    for cls, sev, loc, msg, rendered, ent in errors:
        by_cls.setdefault(cls, []).append((loc, msg, ent))
    for cls in sorted(by_cls):
        print("  %-16s %d" % (cls, len(by_cls[cls])))

    if errors:
        print()
        for cls in sorted(by_cls):
            for loc, msg, ent in sorted(by_cls[cls])[:limit]:
                print("  %s: error: %s [%s]   (via %s)"
                      % (loc, msg, cls, ent))
            if len(by_cls[cls]) > limit:
                print("  ... %d more [%s]" % (len(by_cls[cls]) - limit, cls))

    if skipped:
        print()
        print("unresolvable link units (%d):" % len(skipped))
        for rel_path, err in skipped[:20]:
            print("  %s: %s" % (rel_path, err))
        if len(skipped) > 20:
            print("  ... %d more" % (len(skipped) - 20))

    if show:
        want = (set(sema.CLASSES) if show == "all" else set(show.split(",")))
        shown = {}
        print()
        for cls, sev, loc, msg, rendered, ent in sites:
            if cls not in want:
                continue
            n = shown.get(cls, 0)
            if n >= limit:
                continue
            shown[cls] = n + 1
            print(rendered)

    if fail_on_error and errors:
        print()
        print("FAIL: %d error-severity site(s) across %d link unit(s)"
              % (len(errors), len(rels)))
        return 1
    return 0


# --------------------------------------------------------------------------
# mode: merged — legacy whole-tree merge (measurement only)
# --------------------------------------------------------------------------

def run_merged(roots, project_root, show=None, limit=40):
    programs, files, parse_fails = parse_tree(roots, project_root)

    by_name, ambiguous, order = {}, set(), []
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
        d for d in order if getattr(d, "name", None) not in ambiguous])

    diags, counts = sema.check_program(merged, policy=_scan_policy(),
                                       max_diagnostics=10 ** 9)

    print("files parsed: %d (%d parse failures)" % (len(programs),
                                                    parse_fails))
    print("ambiguous public names dropped: %d   <-- BLIND SPOT: these are "
          "unchecked" % len(ambiguous))
    print("declarations checked: %d" % len(merged.declarations))
    print()
    print("%-16s %8s   %s" % ("class", "sites", "default severity"))
    print("-" * 54)
    for cls in sema.CLASSES:
        print("%-16s %8d   %s"
              % (cls, counts.get(cls, 0), sema.DEFAULT_SEVERITY[cls]))
    print("-" * 54)
    print("%-16s %8d" % ("TOTAL", sum(counts.values())))

    if show:
        want = (set(sema.CLASSES) if show == "all" else set(show.split(",")))
        shown = {}
        print()
        for d in diags:
            if d.cls not in want:
                continue
            n = shown.get(d.cls, 0)
            if n >= limit:
                continue
            shown[d.cls] = n + 1
            print(sema.render(d))
    return 0


# --------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("roots", nargs="*", default=None)
    ap.add_argument("--mode", default="entry",
                    choices=["entry", "conflicts", "merged", "all"])
    ap.add_argument("--jobs", "-j", type=int,
                    default=min(12, (os.cpu_count() or 4)))
    ap.add_argument("--show", default=None,
                    help="comma-separated classes whose diagnostics to print "
                         "(or 'all')")
    ap.add_argument("--limit", type=int, default=40,
                    help="max diagnostics to print per shown class")
    ap.add_argument("--fail-on", default=None, choices=["live", "any"],
                    help="conflicts mode: exit non-zero on LIVE (or any) "
                         "conflict")
    ap.add_argument("--no-fail", action="store_true",
                    help="entry mode: report but always exit 0")
    ap.add_argument("--entries", default=None,
                    help="entry mode: file with one entry-point path per "
                         "line (skips entry discovery)")
    ap.add_argument("--baseline", default=None,
                    help="conflicts mode: file of accepted conflicting names; "
                         "exit non-zero on any name NOT in it")
    ap.add_argument("--exclude", action="append", default=[],
                    help="entry mode: glob of paths to skip as entry points "
                         "AND as diagnostic sites (negative fixtures). "
                         "Repeatable.")
    ap.add_argument("--names-only", action="store_true",
                    help="conflicts mode: print '<CLASS> <name>' per line "
                         "(the baseline file format)")
    args = ap.parse_args()

    project_root = PROJECT_ROOT
    roots = args.roots or DEFAULT_DIRS

    entries_override = None
    if args.entries:
        entries_override = [project_root / ln.strip()
                            for ln in Path(args.entries).read_text().split()
                            if ln.strip()]

    rc = 0
    if args.mode in ("conflicts", "all"):
        rc |= run_conflicts(roots, project_root, args.jobs,
                            fail_on=args.fail_on, limit=None,
                            baseline=args.baseline,
                            names_only=args.names_only)
    if args.mode in ("entry", "all"):
        rc |= run_entry(roots, project_root, args.jobs, show=args.show,
                        limit=args.limit,
                        fail_on_error=not args.no_fail,
                        entries_override=entries_override,
                        excludes=tuple(args.exclude))
    if args.mode == "merged":
        rc |= run_merged(roots, project_root, show=args.show,
                         limit=args.limit)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
