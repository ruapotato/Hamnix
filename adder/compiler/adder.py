#!/usr/bin/env python3
"""
Adder CLI - Compile Python-syntax code to x86_64.

Usage:
    adder compile source.py --target=<target> -o output.elf

Targets:
    x86_64-bare-metal           Standalone kernel image (hamnix-kernel.elf)
    x86_64-linux-kernel-module  Emits .S for kbuild → .ko
    x86_64-adder-user           CPL-3 userspace ELF for the bare-metal kernel
    x86_64-linux                Freestanding x86_64 ELF for the HOST Linux kernel
    aarch64-linux               Freestanding aarch64 ELF (qemu-aarch64)

The original ARM Cortex-M target lived in compiler/codegen_arm.py and was
deleted in the legacy cleanup; only the x86_64 backend ships now.
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from .lexer import tokenize, LexerError
from .parser import Parser, ParseError, parse
from .ast_nodes import Program, ImportDecl
from .codegen_x86 import generate as generate_x86, CodeGenError
from .codegen_arm64 import generate as generate_arm64
from .peephole_x86 import optimize_text as peephole_x86
from .regalloc_x86 import optimize_text as regalloc_x86


# Compilation targets. `codegen` selects the backend; `kbuild` means the
# Linux kernel build system owns assembly+link, so the CLI stops at emitting
# a .S file rather than invoking an assembler/linker itself.
#
# Flags:
#   kbuild     — the Linux kernel build system owns assembly+link.
#   bare_metal — no OS underneath: there is no `_start`/exit syscall wrapper
#                and (x86) no .modinfo license stamp. Drives the boot-stub
#                link paths (arch/*/boot.S + a kernel .lds).
#   userspace  — a freestanding userspace ELF: a `_start` + syscall wrappers
#                are linked in and `main`'s return becomes the exit code.
#                Like bare_metal it suppresses the x86 .modinfo stamp, but it
#                is a DISTINCT concept — bare_metal is "no OS", userspace is
#                "runs as a process on an OS". Keeping them separate avoids
#                overloading bare_metal as a proxy for "no modinfo".
TARGETS = {
    "x86_64-linux-kernel-module": {"codegen": "x86", "kbuild": True,
                                   "bare_metal": False, "userspace": False},
    # Standalone x86_64 kernel ELF (hamnix-kernel.elf). The compiler owns
    # assembly + link itself (no kbuild), and the codegen skips the .modinfo
    # license stamp that's only meaningful for loadable modules.
    "x86_64-bare-metal": {"codegen": "x86", "kbuild": False,
                          "bare_metal": True, "userspace": False},
    # CPL-3 user-mode ELF the Adder kernel's fs/elf.py loader can run.
    # Same codegen as bare-metal (RIP-relative addressing, no .modinfo),
    # different link: we add user/runtime.S (the _start + syscall
    # wrappers) and use user/init.lds (single PT_LOAD, OUTPUT_FORMAT
    # elf32-i386 so the kernel's loader can parse it).
    "x86_64-adder-user": {"codegen": "x86", "kbuild": False,
                          "bare_metal": True, "userspace": False},
    # FREESTANDING x86_64 Linux user-mode ELF, runnable on the HOST Linux
    # kernel. Same x86 codegen as x86_64-adder-user (RIP-relative, no
    # .modinfo — driven here by `userspace`, NOT bare_metal), but a real
    # elf64-x86-64 link: user/linux-runtime.S supplies a Linux `_start`
    # (reads argc/argv off the stack) and raw-`syscall` wrappers with
    # standard Linux x86_64 numbers; user/linux-init.lds emits a static
    # elf64 image. No libc, no Plan 9 base. This is the host-tooling unlock
    # for the compiler fuzzer + host self-hosting.
    "x86_64-linux": {"codegen": "x86", "kbuild": False,
                     "bare_metal": False, "userspace": True},
    # PHASE 1 multi-arch: aarch64 (ARM64) Linux user-mode ELF, runnable
    # under qemu-aarch64. Hand-written aarch64 encoder in codegen_arm64.py;
    # assembled + statically linked with aarch64-linux-gnu binutils. This
    # is the foundational backend; the bare-metal ARM64 kernel port is a
    # later phase. The x86_64 paths above are untouched.
    "aarch64-linux": {"codegen": "arm64", "kbuild": False,
                      "bare_metal": False, "userspace": True},
    # PHASE 2 multi-arch: standalone aarch64 kernel image bootable on
    # QEMU's `virt` machine (qemu-system-aarch64 -M virt -kernel). Same
    # arm64 codegen, but bare_metal=True suppresses the Linux
    # `_start`/exit-syscall wrapper: the hand-written boot stub
    # arch/arm64/boot.S owns the reset entry (sets up a stack, branches
    # to the Adder `kmain`), and program output is raw MMIO to the PL011
    # UART rather than the `write` syscall. The compiler owns assembly +
    # link itself (no kbuild). The aarch64-linux + x86 paths above stay
    # byte-identical.
    "aarch64-bare-metal": {"codegen": "arm64", "kbuild": False,
                           "bare_metal": True, "userspace": False},
}
DEFAULT_TARGET = "x86_64-bare-metal"


def _source_has_unsafe_pragma(source: str) -> bool:
    """True if `source` carries a whole-file `# adder: unsafe` pragma (roadmap
    item 3) — a comment line (leading whitespace allowed) of the exact form
    `# adder: unsafe`. Coarsest safety opt-out: marks every function in the
    file unsafe. Parsed at the preprocessor level so it needs no new token."""
    import re as _re
    return bool(_re.search(r'(?m)^[ \t]*#[ \t]*adder:[ \t]*unsafe[ \t]*$',
                           source or ""))


def get_generator(target: str, opt_level: int = 0,
                  check_bounds: bool = False, file_unsafe: bool = False):
    """Return a callable program -> assembly string for the target.

    ``opt_level`` selects the optimization pipeline. ``0`` (default) is the
    trusted single-pass path — the only path the Hamnix image build uses.
    ``1`` runs the x86 peephole optimizer (Track 6) over the emitted assembly;
    it is gated behind ``-O1`` and validated by ``scripts/fuzz_adder.sh``.
    ``2`` additionally runs the stack-slot -> callee-saved-register promotion
    pass (``regalloc_x86``) after the peephole, removing the stack machine's
    per-iteration memory round-trips for hot locals. Both optimizers only
    apply to the x86 backend; arm64 ignores them.
    """
    spec = TARGETS.get(target)
    if spec is None:
        known = ", ".join(TARGETS)
        print(f"Error: unknown target '{target}'. Known targets: {known}",
              file=sys.stderr)
        sys.exit(1)
    if spec["codegen"] == "x86":
        # The x86 codegen's `bare_metal` flag ONLY gates the .modinfo
        # license stamp (meaningful for loadable .ko modules). A
        # freestanding userspace ELF wants no .modinfo either, so suppress
        # it for `userspace` targets too — without claiming bare_metal,
        # which elsewhere means "no OS / boot-stub link".
        no_modinfo = spec.get("bare_metal", False) or spec.get("userspace", False)

        # Runtime array-bounds checking is opt-in AND userspace-only: it is
        # NEVER enabled for a bare-metal/kernel target, so kernel codegen stays
        # byte-for-byte unchanged (docs/adder_memory_safety.md). Even with the
        # flag on, a non-userspace target passes check_bounds=False here.
        #
        # `x86_64-adder-user` is the ON-DEVICE CPL-3 user target (increment 1b):
        # it shares the bare-metal CODEGEN path (bare_metal=True above) but is
        # genuine userspace whose #UD faults are delivered as a clean signal by
        # the Adder kernel's fault path — so it IS bounds-eligible, matching the
        # native backend (adder/compiler/codegen.ad), which enables checks for
        # its ELF_FMT_USER target. Keeping seed and native in lockstep here is
        # required: an on-flag divergence would break the differential objdiff.
        userspace_bounds = spec.get("userspace", False) \
            or target == "x86_64-adder-user"
        do_bounds = check_bounds and userspace_bounds

        # Descriptive-trap stderr message (roadmap item 3) is emitted ONLY for
        # the host Linux ELF (x86_64-linux, the sole x86 `userspace` target) —
        # it has real .rodata sections + Linux write(2) and is run directly on
        # the host so stderr is observable. adder-user/kernel keep the compact
        # `ud2` trap, which is what preserves the seed<->native objdiff lockstep.
        host_userspace = spec.get("userspace", False)

        def _gen_x86(program):
            asm = generate_x86(program, bare_metal=no_modinfo,
                               check_bounds=do_bounds,
                               host_userspace=host_userspace,
                               file_unsafe=file_unsafe)
            if opt_level >= 1:
                asm = peephole_x86(asm)
            if opt_level >= 2:
                asm = regalloc_x86(asm)
            return asm
        return _gen_x86
    if spec["codegen"] == "arm64":
        # arm64's bare_metal gates the inline `_start`/exit wrapper, so a
        # userspace target (aarch64-linux) must pass bare_metal=False to
        # still get its `_start`. Pass the table value verbatim.
        bare = spec.get("bare_metal", False)
        return lambda program: generate_arm64(program, bare_metal=bare)
    raise AssertionError(f"unhandled codegen backend: {spec['codegen']}")


def find_hamnix_root() -> Path:
    """Find the adder project root directory."""
    this_dir = Path(__file__).parent
    return this_dir.parent


def resolve_import(module_path: str, base_dir: Path) -> Path:
    """Resolve a module path to a file path.

    Adder source files use the `.ad` extension to keep them distinct
    from real Python sources (e.g. the compiler implementation in
    compiler/ and build scripts under scripts/). Python-style import
    syntax is reused — the module identifier `kernel.sched.core`
    resolves to `kernel/sched/core.ad`.
    """
    # Convert dots to path separators
    parts = module_path.split(".")
    path = base_dir / "/".join(parts)

    # Try as directory/__init__.ad first
    if (path / "__init__.ad").exists():
        return path / "__init__.ad"

    # Try as file.ad
    if path.with_suffix(".ad").exists():
        return path.with_suffix(".ad")

    raise FileNotFoundError(f"Cannot find module: {module_path}")


def collect_all_imports(main_file: Path, project_root: Path) -> list[Path]:
    """Collect all imported files transitively."""
    visited: set[Path] = set()
    to_process: list[Path] = [main_file.resolve()]
    ordered: list[Path] = []  # Dependency order (imports first)

    while to_process:
        current = to_process.pop()
        if current in visited:
            continue
        visited.add(current)

        # Parse this file to get its imports
        source = current.read_text()
        try:
            program = parse(source, str(current))
        except (LexerError, ParseError) as e:
            print(f"Error parsing {current}: {e}", file=sys.stderr)
            sys.exit(1)

        # Find all imported modules
        for imp in program.imports:
            try:
                imported_file = resolve_import(imp.module, project_root)
                if imported_file not in visited:
                    to_process.append(imported_file)
            except FileNotFoundError:
                # External/runtime imports - ignore
                pass

        # Add this file after its dependencies
        ordered.insert(0, current)

    return ordered


# ---------------------------------------------------------------------------
# Per-module symbol scoping
# ---------------------------------------------------------------------------
#
# Adder has no `export`/`pub` keyword. Visibility is by *convention*:
#
#   * A top-level name that DOES NOT start with `_` is PUBLIC — it lives
#     in the single global symbol namespace, exactly as before. Two
#     modules defining the same public name is still a hard error.
#
#   * A top-level name that DOES start with `_` is MODULE-PRIVATE: it is
#     mangled to `<module_slug>__<name>` so a `_helper` in one .ad file
#     never collides with a `_helper` in another. Intra-module references
#     to that private name (calls, identifier loads, `&fn` address-of)
#     are rewritten to the mangled spelling so they still resolve.
#
#   * EXCEPTION — the `import` statement is itself the export annotation.
#     If any module does `from M import _name`, then `_name` is part of
#     an explicit cross-module contract: it is promoted to PUBLIC and
#     left un-mangled, so the importer's bare `_name` reference resolves.
#     (Today's cross-module underscore symbols: `_add_export`,
#     `__stack_chk_fail/guard/init`, `_u_errstr`.)
#
#   * ExternDecl names are NEVER mangled — they name real external
#     symbols. A private def that *backs* an `extern def` of the same
#     name elsewhere is likewise promoted to public.
#
# This needs ZERO migration of the ~350 existing .ad files: public API
# names are untouched, and underscore helpers — which are exactly the
# things that collide and exactly the things that are conventionally
# private — get scoped automatically.

# Symbols the x86_64 codegen emits references to by a hard-coded name
# (compiler/codegen_x86.py's stack-protector prologue/epilogue). These
# must never be mangled regardless of import status.
_CODEGEN_RESERVED_SYMBOLS = frozenset({
    "__stack_chk_guard",
    "__stack_chk_fail",
    "__stack_chk_init",
})


def _module_name_for(file_path: Path, project_root: Path) -> str:
    """Derive a dotted module path from a source file path.

    Inverse of resolve_import(): `kernel/sched/core.ad` ->
    `kernel.sched.core`. Used both as the scoping key and as the
    private-name mangle prefix.
    """
    try:
        rel = file_path.resolve().relative_to(project_root.resolve())
    except ValueError:
        # File outside the project tree (e.g. an ad-hoc temp file in a
        # standalone test). Fall back to the bare stem.
        rel = Path(file_path.name)
    parts = list(rel.with_suffix("").parts)
    return ".".join(parts)


def _mangle_private(module: str, name: str) -> str:
    """Mangle a module-private name to a globally-unique symbol.

    `<module_slug>__<name>` where the slug is the dotted module path
    with dots replaced by underscores. `name` already begins with `_`,
    so the result is e.g. `kernel_sched_core___emit_str` — the triple
    underscore (slug `_` + private `_`) is intentional and harmless.
    The result is a valid assembler identifier.
    """
    slug = module.replace(".", "_")
    return f"{slug}_{name}"


def _is_private_name(name: str) -> bool:
    """A leading-underscore top-level name is private by convention."""
    return name.startswith("_")


def _iter_child_nodes(node):
    """Yield every dataclass-typed child reachable from `node`.

    Generic structural walk: recurses into dataclass fields, lists,
    tuples and dict values. Used to find every Identifier (and the
    handful of name-bearing type nodes) in a declaration subtree.
    """
    import dataclasses
    if dataclasses.is_dataclass(node):
        for f in dataclasses.fields(node):
            yield getattr(node, f.name)
    elif isinstance(node, (list, tuple)):
        for item in node:
            yield item
    elif isinstance(node, dict):
        for v in node.values():
            yield v


def _collect_local_names(node, acc: set) -> None:
    """Collect names BOUND as locals within a function body subtree.

    A name bound locally (parameter, `x: T = ...`, for-loop var,
    `except E as e`, `with ... as w`, comprehension/lambda var, or a
    tuple unpack target) shadows a same-named module-private top-level
    symbol, so its references must NOT be mangled. A `global _x`
    statement is the opposite — it forces `_x` to mean the module
    global — so global-declared names are deliberately NOT collected
    here (they SHOULD be mangled along with the global decl).

    We over-approximate the rest deliberately: treating a name as
    "local" only ever SUPPRESSES a rewrite, and the codegen already
    resolves locals-before-globals, so a false positive is safe (it
    just leaves a genuine global reference un-mangled) while a false
    negative would miscompile.
    """
    from .ast_nodes import (
        FunctionDef, VarDecl, ForStmt, ForUnpackStmt, ExceptHandler,
        WithItem, ListComprehension, LambdaExpr, TupleUnpackAssign,
        Parameter,
    )
    if node is None:
        return
    if isinstance(node, Parameter):
        acc.add(node.name)
    elif isinstance(node, VarDecl):
        acc.add(node.name)
    elif isinstance(node, ForStmt):
        acc.add(node.var)
    elif isinstance(node, ForUnpackStmt):
        acc.update(node.vars)
    elif isinstance(node, ExceptHandler):
        if node.name:
            acc.add(node.name)
    elif isinstance(node, WithItem):
        if node.var:
            acc.add(node.var)
    elif isinstance(node, ListComprehension):
        acc.add(node.var)
    elif isinstance(node, LambdaExpr):
        acc.update(node.params)
    elif isinstance(node, TupleUnpackAssign):
        acc.update(node.targets)
    # FunctionDef params are Parameter nodes handled above via recursion.
    for child in _iter_child_nodes(node):
        _collect_local_names(child, acc)


def _rewrite_refs(node, rename: dict, shadowed: frozenset) -> None:
    """Rewrite identifier references to module-private mangled names.

    `rename` maps a module-private source name -> its mangled symbol.
    `shadowed` is the set of names bound as locals somewhere in the
    enclosing function (see _collect_local_names) — references to a
    shadowed name are left alone.

    Every symbol-by-name reference in Adder lands on an `Identifier`
    node: a bare variable/global load, the `func` of a CallExpr, and
    the operand of a `&` address-of are all `Identifier`. We also
    defensively rewrite the name-bearing type nodes (StructInitExpr,
    ContainerOfExpr, Type) — no private *types* exist in the codebase
    today, but handling them keeps the scheme correct if one is added.
    """
    from .ast_nodes import (
        Identifier, StructInitExpr, ContainerOfExpr, Type,
    )
    if node is None:
        return
    if isinstance(node, Identifier):
        if node.name in rename and node.name not in shadowed:
            node.name = rename[node.name]
        return
    if isinstance(node, StructInitExpr):
        if node.struct_name in rename:
            node.struct_name = rename[node.struct_name]
    elif isinstance(node, ContainerOfExpr):
        if node.type_name in rename:
            node.type_name = rename[node.type_name]
    elif isinstance(node, Type):
        if node.name in rename:
            node.name = rename[node.name]
    for child in _iter_child_nodes(node):
        _rewrite_refs(child, rename, shadowed)


def _collect_exported_names(programs: list) -> set:
    """Names that must stay global (un-mangled) despite a leading `_`.

    A leading-underscore name is normally module-private, but a name
    that is part of an explicit cross-module contract must stay global:

      * any name appearing in some module's `from M import name` list
        — the import statement IS the export annotation;
      * any ExternDecl name — extern decls reference real external
        symbols, and a private def backing one must keep its name;
      * the codegen-reserved stack-protector symbols.
    """
    from .ast_nodes import ExternDecl
    exported: set = set(_CODEGEN_RESERVED_SYMBOLS)
    for program in programs:
        for imp in program.imports:
            # `from M import a, b` names cross-module symbols. A plain
            # `import M` / `import M as x` has an empty names list.
            for nm in imp.names:
                exported.add(nm)
        for decl in program.declarations:
            if isinstance(decl, ExternDecl):
                exported.add(decl.name)
    return exported


def resolve_module_scopes(programs: list) -> None:
    """Apply per-module private-name scoping to a list of programs.

    Mutates each Program in place: mangles its module-private
    declaration names and rewrites every intra-module reference to
    them. After this runs, the merged declaration set has no private
    name collisions and every public name is still global.

    Each Program MUST already have its `.module` field set.
    """
    exported = _collect_exported_names(programs)

    for program in programs:
        module = program.module or ""
        # Build this module's private-name rename map.
        rename: dict[str, str] = {}
        for decl in program.declarations:
            name = getattr(decl, "name", None)
            if not name:
                continue
            # ExternDecl names are real external symbols — never mangle.
            from .ast_nodes import ExternDecl
            if isinstance(decl, ExternDecl):
                continue
            if not _is_private_name(name):
                continue
            if name in exported:
                # Promoted to public by an explicit import / extern.
                continue
            rename[name] = _mangle_private(module, name)

        if not rename:
            continue

        # Rename the declarations themselves, preserving orig_name so
        # name-based codegen heuristics keep working.
        from .ast_nodes import FunctionDef, VarDecl
        for decl in program.declarations:
            name = getattr(decl, "name", None)
            if name in rename:
                if isinstance(decl, (FunctionDef, VarDecl)):
                    decl.orig_name = name
                decl.name = rename[name]

        # Rewrite intra-module references. Local bindings (params,
        # `x: T`, loop vars, ...) shadow a same-named private global,
        # so collect them per-function and exclude them.
        for decl in program.declarations:
            shadow: set = set()
            _collect_local_names(decl, shadow)
            _rewrite_refs(decl, rename, frozenset(shadow))


def merge_programs(files: list[Path]) -> Program:
    """Parse all files and merge into a single program.

    Before merging, the per-module scoping pass (resolve_module_scopes)
    mangles each module's private (leading-underscore) names so they
    cannot collide. After that, the only remaining name collisions are
    between PUBLIC names — and those are still a hard error, exactly as
    before: silent dedup once meant two modules each defined
    `_find_free_slot`, the second was silently dropped, and callers in
    module B linked against module A's body — hours-of-debugging bug.
    """
    from .ast_nodes import ExternDecl

    project_root = find_hamnix_root()

    # Parse every file once, tagging each Program with its module path.
    programs: list[Program] = []
    program_files: list[Path] = []
    for file_path in files:
        source = file_path.read_text()
        program = parse(source, str(file_path))
        program.module = _module_name_for(file_path, project_root)
        for decl in program.declarations:
            # Tag each top-level decl with its origin module.
            if hasattr(decl, "module"):
                decl.module = program.module
        programs.append(program)
        program_files.append(file_path)

    # Scope module-private names BEFORE merging into one namespace.
    resolve_module_scopes(programs)

    all_imports: list[ImportDecl] = []
    all_declarations = []
    # Map name -> first file we saw it in. Duplicates are allowed only
    # for ExternDecl (the same `extern def foo(...)` may legitimately
    # appear in multiple modules that each call foo). Every other
    # collision is an error.
    seen_names: dict[str, Path] = {}

    for program, file_path in zip(programs, program_files):
        # Collect imports (runtime only)
        for imp in program.imports:
            # Skip internal imports (lib.*, kernel.*, coreutils.*)
            if not (imp.module.startswith("lib.") or
                    imp.module.startswith("kernel.") or
                    imp.module.startswith("coreutils.")):
                all_imports.append(imp)

        for decl in program.declarations:
            name = getattr(decl, 'name', None)
            if not name:
                all_declarations.append(decl)
                continue
            if name in seen_names:
                if isinstance(decl, ExternDecl):
                    # Extern decls are forward references; ignoring a
                    # duplicate `extern def` is harmless.
                    continue
                prev = seen_names[name]
                print(
                    f"Error: duplicate top-level definition '{name}' in "
                    f"{file_path} (first seen in {prev}). Rename one of "
                    f"them — these are PUBLIC names, global across all "
                    f"merged modules. (Module-private helpers — names "
                    f"starting with '_' — are scoped per-module and do "
                    f"not collide.)",
                    file=sys.stderr,
                )
                sys.exit(1)
            seen_names[name] = file_path
            all_declarations.append(decl)

    return Program(imports=all_imports, declarations=all_declarations)


def _run_affine_check(program) -> None:
    """Compile-time affine move-check for `Own[T]` bindings (roadmap increment
    5). A no-op for any program that uses no `own`, so it is byte-inert and
    cannot perturb the kernel/userland corpus. On a use-after-move / double-free
    it prints a diagnostic and exits non-zero (a compile error)."""
    from .affine_check import check_affine, AffineError
    try:
        check_affine(program)
    except AffineError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


def _run_sema(program) -> None:
    """Static type checking (adder/compiler/sema.py).

    Runs between the affine check and codegen. Reports EVERY problem it
    finds — arity, argument/assignment/return type compatibility, pointer
    compatibility, integer-literal range, mixed-signedness comparisons —
    with file:line:col, the source line and a caret, then exits non-zero if
    any of them is `error` severity under the current policy.

    Pure analysis: it never mutates the AST, so codegen output (and the
    seed<->native byte-identity oracle) is unaffected by construction.
    `ADDER_SEMA=0` disables it entirely; `ADDER_SEMA_STRICT=1` promotes
    every warning class to an error. See sema.severity_policy().
    """
    if os.environ.get("ADDER_SEMA") == "0":
        return
    from .sema import check_program, render
    try:
        diagnostics, _counts = check_program(program)
    except Exception as exc:                                  # noqa: BLE001
        # The checker is advisory: an internal failure inside it must never
        # be the reason a previously-compiling program stops compiling.
        print(f"warning: sema pass skipped ({type(exc).__name__}: {exc})",
              file=sys.stderr)
        return
    for d in diagnostics:
        print(render(d), file=sys.stderr)
    n_err = sum(1 for d in diagnostics if d.severity == "error")
    if n_err:
        print(f"Error: {n_err} type error{'' if n_err == 1 else 's'} "
              f"(set ADDER_SEMA=0 to bypass the type checker)",
              file=sys.stderr)
        sys.exit(1)


def compile_source(source: str, filename: str = "<stdin>",
                   target: str = DEFAULT_TARGET, opt_level: int = 0,
                   check_bounds: bool = False) -> str:
    """Compile Adder source to assembly (single file, no imports)."""
    generate = get_generator(target, opt_level, check_bounds,
                             file_unsafe=_source_has_unsafe_pragma(source))
    try:
        program = parse(source, filename)
        _run_affine_check(program)
        _run_sema(program)
        return generate(program)
    except (LexerError, ParseError, CodeGenError) as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


def compile_with_imports(main_file: Path, target: str = DEFAULT_TARGET,
                         opt_level: int = 0, check_bounds: bool = False) -> str:
    """Compile Adder source with import resolution."""
    # The `# adder: unsafe` pragma is scoped to the MAIN file (a whole-file
    # opt-out for a hot/low-level TU), scanned before import merge.
    generate = get_generator(
        target, opt_level, check_bounds,
        file_unsafe=_source_has_unsafe_pragma(main_file.read_text()))
    project_root = find_hamnix_root()

    # Collect all imported files
    all_files = collect_all_imports(main_file, project_root)

    print(f"Compiling {len(all_files)} modules...", file=sys.stderr)
    for f in all_files:
        print(f"  {f.relative_to(project_root)}", file=sys.stderr)

    # Merge into single program
    merged_program = merge_programs(all_files)

    # Generate assembly
    try:
        _run_affine_check(merged_program)
        _run_sema(merged_program)
        return generate(merged_program)
    except CodeGenError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


def assemble_and_link_x86_64_linux(asm_file: Path, output: Path,
                                   project_root: Path) -> bool:
    """Assemble + statically link an Adder FREESTANDING x86_64 Linux ELF.

    The `x86_64-linux` target. Mirrors assemble_and_link_arm64_linux but
    for the host x86_64 Linux kernel: the compiler-emitted .S (plain 64-bit
    code — no `.code64`-in-elf32 wrapper, since a real Linux loader wants a
    genuine elf64-x86-64 image) is combined with user/linux-runtime.S (the
    Linux `_start` + raw-`syscall` wrappers) and linked static/-no-pie with
    user/linux-init.lds, entry `_start`. No libc, no Plan 9 base — runs
    directly on the developer's host Linux kernel.

    linux-runtime.S is preprocessed (`gcc -c -DLINUX_ABI`) so the named
    syscall constants in user/syscall_nums.h resolve; the compiler-emitted
    main object is assembled with plain `as --64`.
    """
    as_cmd = "as"
    ld_cmd = "ld"
    cc_cmd = "gcc"

    for tool in (as_cmd, ld_cmd):
        try:
            subprocess.run([tool, "--version"], capture_output=True,
                           check=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            print(f"Error: {tool} not found (install binutils)",
                  file=sys.stderr)
            return False
    try:
        subprocess.run([cc_cmd, "--version"], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print(f"Error: {cc_cmd} not found (needed to preprocess "
              f"user/linux-runtime.S)", file=sys.stderr)
        return False

    # ET_DYN/PIE opt-in for the self-hosted host compiler (host_ac.elf). When
    # ADDER_X86_LINUX_PIE=1 the image is linked as a position-independent
    # ET_DYN based at vaddr 0 (user/linux-init-pie.lds) instead of the default
    # ET_EXEC at the low base 0x400000 (user/linux-init.lds). The compiler
    # emits fully position-independent code — every global is RIP-relative and
    # there are NO absolute data pointers, so `-pie` produces ZERO dynamic
    # relocations (verified with readelf -r); the image therefore runs at any
    # load base with no relocator. WHY: host_ac's ~474 MiB writable/BSS PT_LOAD
    # at the ET_EXEC low base spans into the on-device kernel's low-identity
    # direct map (aliasing virtqueue rings / kstacks / slab / page tables). As
    # ET_DYN the Hamnix loader (fs/elf.ad) rebases the whole image to a HIGH
    # dyn_vbase (>= 4 GiB, above physical RAM via aslr_load_bias), sidestepping
    # that collision class. Default (unset/0) keeps the ET_EXEC low-base link so
    # every other x86_64-linux consumer (fuzz driver, aarch64 mirror, etc.) is
    # byte-unchanged.
    pie = os.environ.get("ADDER_X86_LINUX_PIE", "") == "1"

    runtime_s = project_root / "user/linux-runtime.S"
    lds       = project_root / ("user/linux-init-pie.lds" if pie
                                else "user/linux-init.lds")
    for required in (runtime_s, lds):
        if not required.exists():
            print(f"Error: missing {required}", file=sys.stderr)
            return False

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        runtime_o = tmpdir / "linux-runtime.o"
        main_o    = tmpdir / "main.o"

        # Runtime: preprocess + assemble (the .S uses #include / #define).
        # -I the user/ dir so syscall_nums.h resolves.
        result = subprocess.run(
            [cc_cmd, "-c", "-x", "assembler-with-cpp",
             "-I", str(project_root / "user"),
             "-o", str(runtime_o), str(runtime_s)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"Error assembling linux-runtime.S:\n{result.stderr}",
                  file=sys.stderr)
            return False

        # Main: the compiler-emitted .S is already 64-bit; assemble straight.
        result = subprocess.run(
            [as_cmd, "--64", "-o", str(main_o), str(asm_file)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"Error assembling (x86_64-linux):\n{result.stderr}",
                  file=sys.stderr)
            return False

        if pie:
            # ET_DYN/PIE: --no-dynamic-linker suppresses the PT_INTERP `ld`
            # would otherwise synthesize for a -pie link (there is no dynamic
            # loader — the image is self-contained with zero relocations).
            link_cmd = [
                ld_cmd, "-m", "elf_x86_64", "-nostdlib", "-pie",
                "--no-dynamic-linker", "-z", "noexecstack",
                "-T", str(lds), "-e", "_start",
                "-o", str(output), str(runtime_o), str(main_o),
            ]
        else:
            link_cmd = [
                ld_cmd, "-m", "elf_x86_64", "-nostdlib", "-static", "-no-pie",
                "-z", "noexecstack", "-T", str(lds), "-e", "_start",
                "-o", str(output), str(runtime_o), str(main_o),
            ]
        result = subprocess.run(link_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error linking (x86_64-linux):\n{result.stderr}",
                  file=sys.stderr)
            return False

    # Stamp EI_OSABI = ELFOSABI_LINUX (3) into e_ident[7] of the linked image.
    # `ld` emits ELFOSABI_SYSV (0) by default, which the Hamnix loader
    # (fs/elf.ad::elf_is_linux_binary) would classify as a NATIVE binary and
    # dispatch under the native ABI — wrong for an image (e.g. host_ac.elf)
    # that issues Linux syscall numbers. Setting OSABI=3 makes the on-device
    # loader route it through the linux_abi shim (like busybox/apt) so it runs
    # correctly inside the Debian/Linux namespace. This mirrors elf_emit.ad's
    # elf_osabi=3 for --target=x86_64-linux. The x86_64-adder-user target
    # (assemble_and_link_x86_user) is untouched and keeps OSABI=0. This changes
    # exactly one header byte; the executable content is unchanged and it still
    # runs identically on a developer host Linux kernel (OSABI is advisory to
    # the host loader).
    with open(output, "r+b") as _fh:
        _fh.seek(7)  # e_ident[EI_OSABI]
        _fh.write(b"\x03")

    return True


def assemble_and_link_arm64_linux(asm_file: Path, output: Path) -> bool:
    """Assemble + statically link a Adder aarch64 Linux user-mode ELF.

    PHASE 1 multi-arch. The aarch64 backend (codegen_arm64.py) emits a
    self-contained user-mode program: a `_start` that calls `main` and
    issues the Linux `exit` syscall, plus the `write` syscall for output.
    No libc, no C runtime — we assemble with aarch64-linux-gnu-as and link
    a static, no-stdlib ELF with aarch64-linux-gnu-ld, entry point `_start`.
    Runnable under qemu-aarch64 (user-mode emulation).
    """
    as_cmd = "aarch64-linux-gnu-as"
    ld_cmd = "aarch64-linux-gnu-ld"

    for tool in (as_cmd, ld_cmd):
        try:
            subprocess.run([tool, "--version"], capture_output=True,
                           check=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            print(f"Error: {tool} not found "
                  f"(install binutils-aarch64-linux-gnu)", file=sys.stderr)
            return False

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        main_o = tmpdir / "main.o"

        result = subprocess.run(
            [as_cmd, "-o", str(main_o), str(asm_file)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"Error assembling (aarch64):\n{result.stderr}",
                  file=sys.stderr)
            return False

        link_cmd = [
            ld_cmd, "-nostdlib", "-static", "-z", "noexecstack",
            "-e", "_start", "-o", str(output), str(main_o),
        ]
        result = subprocess.run(link_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error linking (aarch64):\n{result.stderr}",
                  file=sys.stderr)
            return False

    return True


def assemble_and_link_arm64_baremetal(asm_file: Path, output: Path,
                                      project_root: Path) -> bool:
    """Assemble + link a standalone aarch64 kernel image for QEMU virt.

    PHASE 2 multi-arch. Combines the compiler-emitted .S (the Adder
    `kmain` and friends, generated with bare_metal=True so there is no
    Linux `_start`/exit wrapper) with the hand-written boot stub
    arch/arm64/boot.S — which provides the `_start` reset entry, sets up
    a stack, and branches to `kmain` — and links them with
    arch/arm64/kernel.lds so the image's load address matches QEMU virt's
    `-kernel` entry point (0x40080000).

    No libc, no Linux: the resulting ELF is loaded directly by
    qemu-system-aarch64's `-kernel`, which jumps to its entry point at
    EL1/EL2 with the MMU off. Output is raw MMIO to the PL011 UART
    (the codegen lowers pointer-deref stores to volatile accesses), so no
    syscall layer is involved.
    """
    as_cmd = "aarch64-linux-gnu-as"
    ld_cmd = "aarch64-linux-gnu-ld"

    for tool in (as_cmd, ld_cmd):
        try:
            subprocess.run([tool, "--version"], capture_output=True,
                           check=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            print(f"Error: {tool} not found "
                  f"(install binutils-aarch64-linux-gnu)", file=sys.stderr)
            return False

    boot_s = project_root / "arch/arm64/boot.S"
    vectors_s = project_root / "arch/arm64/vectors.S"
    lds = project_root / "arch/arm64/kernel.lds"
    for required in (boot_s, vectors_s, lds):
        if not required.exists():
            print(f"Error: missing {required}", file=sys.stderr)
            return False

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        boot_o = tmpdir / "boot.o"
        vectors_o = tmpdir / "vectors.o"
        main_o = tmpdir / "main.o"

        # Phase 3: the EL1 exception vector table (vectors.S) is assembled
        # alongside the boot stub and the Adder-compiled kmain. Its IRQ stub
        # calls back into the Adder handler arm64_irq_handler.
        for src, obj in [(boot_s, boot_o), (vectors_s, vectors_o),
                         (asm_file, main_o)]:
            result = subprocess.run(
                [as_cmd, "-o", str(obj), str(src)],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                print(f"Error assembling (aarch64 bare-metal) {src}:\n"
                      f"{result.stderr}", file=sys.stderr)
                return False

        # boot.o first so the reset entry (_start) lands at the image's
        # load address; the linker script enforces section placement.
        link_cmd = [
            ld_cmd, "-nostdlib", "-static", "-z", "noexecstack",
            "-T", str(lds), "-o", str(output),
            str(boot_o), str(vectors_o), str(main_o),
        ]
        result = subprocess.run(link_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error linking (aarch64 bare-metal):\n{result.stderr}",
                  file=sys.stderr)
            return False

    return True


def assemble_and_link_x86_bare(asm_file: Path, output: Path,
                                project_root: Path) -> bool:
    """Assemble + link a Adder bare-metal x86_64 kernel image.

    Combines the compiler-emitted .S (Adder init/main.py et al.) with the
    hand-written boot stubs under arch/x86/boot/header.S and
    arch/x86/kernel/head_64.S, then links with arch/x86/kernel/kernel.lds
    into an ELF that multiboot1-capable loaders (QEMU -kernel, GRUB) accept.

    HIGHER-HALF KERNEL: this now produces a true `elf64-x86-64` ELF
    (assembled with `as --64`, linked `ld -m elf_x86_64`). The kernel
    proper is LINKED at 0xffffffff80000000+offset but LOADED at low
    physical addresses; the elf32-i386 wrapper used previously could
    not represent symbol addresses above 4 GiB. GRUB's multiboot1 ELF
    loader accepts ELFCLASS64 and loads PT_LOAD segments by p_paddr
    (a 64-bit field), so the VMA/LMA split rides through cleanly.
    """
    as_cmd = "as"
    ld_cmd = "ld"

    try:
        subprocess.run([as_cmd, "--version"], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Error: GNU as not found (install binutils)", file=sys.stderr)
        return False

    boot_s = project_root / "arch/x86/boot/header.S"
    head_s = project_root / "arch/x86/kernel/head_64.S"
    lds = project_root / "arch/x86/kernel/kernel.lds"
    for required in (boot_s, head_s, lds):
        if not required.exists():
            print(f"Error: missing {required}", file=sys.stderr)
            return False

    # Additional hand-written .S files under arch/x86/, fs/, drivers/
    # (excluding the two boot/early-entry stubs above, which are passed
    # explicitly so we can guarantee link order: header.o first → multiboot
    # magic lands at top of .head.text). Anything else under these roots
    # that ends in .S is picked up automatically — drop a new file in
    # and rebuild. The drivers/ root was added when fb_text.ad needed
    # an embedded 8x16 font glyph table (drivers/video/console/fb_font_8x16.S).
    extra_s = sorted(
        p for path_root in ("arch/x86", "fs", "drivers")
        for p in (project_root / path_root).rglob("*.S")
        if p != boot_s and p != head_s
    )

    # Opt-in build isolation: when an isolated build dir is in play, the
    # generated initramfs blob lives OUTSIDE the globbed source tree (so
    # concurrent builds in one checkout don't clobber a shared
    # fs/initramfs_blob.S). HAMNIX_INITRAMFS_BLOB names it explicitly;
    # otherwise it's derived from HAMNIX_BUILD_DIR. When set, drop any
    # in-source initramfs_blob.S from the glob (a stale one would
    # double-define initramfs_cpio_start/end/size/base) and link the
    # override instead. Unset → glob is untouched (historical behavior).
    blob_override = os.environ.get("HAMNIX_INITRAMFS_BLOB")
    if not blob_override and os.environ.get("HAMNIX_BUILD_DIR"):
        blob_override = os.path.join(
            os.environ["HAMNIX_BUILD_DIR"], "initramfs_blob.S")
    if blob_override:
        blob_path = Path(blob_override)
        if not blob_path.exists():
            print(f"Error: HAMNIX_BUILD_DIR/HAMNIX_INITRAMFS_BLOB points at "
                  f"{blob_path}, which does not exist. Run "
                  f"build_initramfs.py with the same HAMNIX_BUILD_DIR first.",
                  file=sys.stderr)
            return False
        extra_s = [p for p in extra_s if p.name != "initramfs_blob.S"]
        extra_s.append(blob_path)

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        boot_o = tmpdir / "header.o"
        head_o = tmpdir / "head_64.o"
        main_o = tmpdir / "main.o"

        # Adder's emitted .S is 64-bit code but has no leading `.code64`
        # (the codegen is target-mode-agnostic). `as --64` defaults to
        # 64-bit instruction encoding, so a leading `.code64` is no
        # longer strictly required, but keep it as a belt-and-braces
        # marker — it is harmless in a 64-bit assembly. header.S itself
        # declares `.code32` for its boot prologue and `.code64` for
        # the long-mode trampoline tail, both of which `as --64`
        # honours per-section.
        hamnix_s = tmpdir / "hamnix_main.S"
        hamnix_s.write_text(".code64\n" + asm_file.read_text())

        extra_objs: list[Path] = []
        for src in extra_s:
            obj = tmpdir / (src.stem + ".o")
            extra_objs.append(obj)

        for src, obj in [(boot_s, boot_o), (head_s, head_o),
                         (hamnix_s, main_o)] + list(zip(extra_s, extra_objs)):
            result = subprocess.run(
                [as_cmd, "--64", "-o", str(obj), str(src)],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                print(f"Error assembling {src}:\n{result.stderr}",
                      file=sys.stderr)
                return False

        # Order matters: header.o first so multiboot magic lands at the top
        # of .head.text; the linker script enforces section order but listing
        # header.o first eliminates any cross-section ambiguity in the input.
        # `-z noexecstack` silences the GNU-stack-note warning; `-n` is not
        # used (we want the default page-aligned section layout the
        # multiboot1 loader expects).
        link_cmd = [
            ld_cmd, "-m", "elf_x86_64", "-nostdlib", "-static",
            "-z", "noexecstack", "-z", "max-page-size=4096",
            "-T", str(lds), "-o", str(output),
            str(boot_o), str(head_o), str(main_o),
        ] + [str(o) for o in extra_objs]
        result = subprocess.run(link_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error linking:\n{result.stderr}", file=sys.stderr)
            return False

    return True


def assemble_and_link_x86_user(asm_file: Path, output: Path,
                                project_root: Path,
                                progname: str = "unknown") -> bool:
    """Assemble + link a Adder source into a CPL-3 user-mode ELF.

    Same shape as assemble_and_link_x86_bare but a much smaller link:
    the user binary is purely the compiler-emitted .S (with the
    .code64 prepend trick) plus user/runtime.S (the _start entry and
    syscall wrappers). The linker script is user/init.lds, which
    emits an elf32-i386 wrapper with a single PT_LOAD at virtual base
    0 — this is what fs/elf.py knows how to load.

    No kernel objects are linked in: a user binary lives in its own
    address space and reaches the kernel only via the `syscall`
    instruction.

    TEMP_DEBUG_HAMSH_BRINGUP: `progname` selects the per-binary
    marker string the runtime's `_start` prints to fd 2. We synthesize
    a tiny progname.S on the fly carrying STRONG definitions of
    __runtime_start_mark / __runtime_start_mark_end with the binary's
    name baked in, and link it ahead of runtime.o so the linker picks
    the strong defs over the weak fallback ("[runtime:unknown] _start")
    that lives in user/runtime.S. Output per binary becomes a distinct
    line, e.g. "[runtime:init] _start" vs "[runtime:hamsh] _start" —
    so a real-hardware boot can tell us whether SYSRETQ out of hamsh's
    execve actually reached hamsh's _start.
    """
    as_cmd = "as"
    ld_cmd = "ld"

    try:
        subprocess.run([as_cmd, "--version"], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Error: GNU as not found (install binutils)", file=sys.stderr)
        return False

    runtime_s = project_root / "user/runtime.S"
    lds       = project_root / "user/init.lds"
    for required in (runtime_s, lds):
        if not required.exists():
            print(f"Error: missing {required}", file=sys.stderr)
            return False

    # TEMP_DEBUG_HAMSH_BRINGUP: keep the marker string ASCII-safe and
    # short — the linker script merges .rodata into the single PT_LOAD,
    # so no extra alignment concerns, but the syscall pulls the length
    # from `end - start` at link time so a stray non-ASCII byte would
    # still emit cleanly. The basename comes from cmd_compile and is
    # already a filesystem name, so it can't contain `"` or `\`.
    progname_safe = "".join(
        c if (c.isalnum() or c in "._-") else "_" for c in progname
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        runtime_o  = tmpdir / "runtime.o"
        progname_o = tmpdir / "progname.o"
        main_o     = tmpdir / "main.o"

        # Same .code64 prepend trick the bare-metal kernel uses: the
        # Adder codegen is target-mode-agnostic, but we want 64-bit
        # instructions inside an elf32-i386 wrapper. `as --32` plus a
        # leading `.code64` directive produces exactly that.
        hamnix_s = tmpdir / "hamnix_main.S"
        hamnix_s.write_text(".code64\n" + asm_file.read_text())

        # TEMP_DEBUG_HAMSH_BRINGUP: per-binary marker override. Strong
        # definitions of __runtime_start_mark / _len / _end clobber the
        # .weak fallbacks in user/runtime.S.
        #
        # __runtime_start_mark_len carries the byte count as DATA. The
        # runtime's _start must not compute `$_end - _start` as an
        # immediate: both weak symbols live in runtime.S's own .rodata,
        # so GNU as folds that difference at assembly time to the weak
        # fallback's length (25) even though the linker later resolves
        # the string POINTER to this strong (shorter) one. The stale
        # count made every _start write past its banner — linker NOP
        # padding (66 90 ...) plus the '[' of the weak string leaked to
        # the serial console as "fM-^PfM-^P[" garbage on the next line.
        # A strong length word, folded HERE against this TU's own
        # labels, is correct by construction and travels with the
        # string through the same weak-override relocation.
        progname_s = tmpdir / "progname.S"
        progname_s.write_text(
            ".code64\n"
            "    .section .rodata\n"
            "    .align 8\n"
            "    .globl __runtime_start_mark_len\n"
            "__runtime_start_mark_len:\n"
            "    .quad __runtime_start_mark_end - __runtime_start_mark\n"
            "    .globl __runtime_start_mark\n"
            "    .globl __runtime_start_mark_end\n"
            "__runtime_start_mark:\n"
            f'    .ascii "[runtime:{progname_safe}] _start\\n"\n'
            "__runtime_start_mark_end:\n"
        )

        for src, obj in [(runtime_s, runtime_o),
                         (progname_s, progname_o),
                         (hamnix_s, main_o)]:
            result = subprocess.run(
                [as_cmd, "--32", "-o", str(obj), str(src)],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                print(f"Error assembling {src}:\n{result.stderr}",
                      file=sys.stderr)
                return False

        # progname.o BEFORE runtime.o so the linker sees the strong
        # __runtime_start_mark first; runtime.o's same-named .weak
        # symbols then quietly defer to it. runtime.o still has to
        # come early so _start (and the syscall stubs the user code
        # calls into) sits at the start of .text — the linker script
        # doesn't strictly require this but it keeps `objdump -d`
        # layout predictable.
        link_cmd = [
            ld_cmd, "-m", "elf_i386", "-nostdlib", "-static",
            "-T", str(lds), "-o", str(output),
            str(progname_o), str(runtime_o), str(main_o),
        ]
        result = subprocess.run(link_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error linking:\n{result.stderr}", file=sys.stderr)
            return False

    return True


def cmd_compile(args: argparse.Namespace) -> int:
    """Compile command."""
    source_file = Path(args.source)
    if not source_file.exists():
        print(f"Error: {source_file} not found", file=sys.stderr)
        return 1

    asm = compile_with_imports(source_file, target=args.target,
                               opt_level=getattr(args, "opt_level", 0),
                               check_bounds=getattr(args, "check_bounds", False))

    # kbuild targets: the Linux kernel build system owns assembly + link, so
    # we stop at emitting a .S file for it to consume.
    if TARGETS[args.target]["kbuild"]:
        if args.output:
            output = Path(args.output)
        else:
            output = source_file.with_suffix(".S")
        output.write_text(asm)
        print(f"Emitted {output} for kbuild ({args.target})")
        return 0

    # Determine output file
    if args.output:
        output = Path(args.output)
    else:
        output = source_file.with_suffix(".elf")

    # Write assembly (for debugging)
    if args.emit_asm:
        asm_file = source_file.with_suffix(".s")
        asm_file.write_text(asm)
        print(f"Assembly written to {asm_file}")

    with tempfile.NamedTemporaryFile(suffix=".s", delete=False, mode="w") as f:
        f.write(asm)
        asm_path = Path(f.name)

    try:
        if args.target == "aarch64-linux":
            ok = assemble_and_link_arm64_linux(asm_path, output)
        elif args.target == "aarch64-bare-metal":
            ok = assemble_and_link_arm64_baremetal(
                asm_path, output, find_hamnix_root())
        elif args.target == "x86_64-bare-metal":
            ok = assemble_and_link_x86_bare(asm_path, output, find_hamnix_root())
        elif args.target == "x86_64-linux":
            ok = assemble_and_link_x86_64_linux(
                asm_path, output, find_hamnix_root())
        elif args.target == "x86_64-adder-user":
            # TEMP_DEBUG_HAMSH_BRINGUP: pass the source-file stem as the
            # progname so runtime.S's _start marker is per-binary
            # distinguishable (e.g. "[runtime:init]" vs "[runtime:hamsh]").
            ok = assemble_and_link_x86_user(
                asm_path, output, find_hamnix_root(),
                progname=source_file.stem,
            )
        else:
            raise AssertionError(
                f"x86_64-bare-metal / x86_64-linux / x86_64-adder-user / "
                f"aarch64-linux / aarch64-bare-metal are the only non-kbuild "
                f"link paths; got '{args.target}'"
            )
        if not ok:
            return 1
    finally:
        asm_path.unlink()

    print(f"Compiled to {output}")
    return 0


def cmd_asm(args: argparse.Namespace) -> int:
    """Emit assembly only."""
    source_file = Path(args.source)
    if not source_file.exists():
        print(f"Error: {source_file} not found", file=sys.stderr)
        return 1

    source = source_file.read_text()
    asm = compile_source(source, str(source_file), target=args.target,
                         opt_level=getattr(args, "opt_level", 0),
                         check_bounds=getattr(args, "check_bounds", False))

    if args.output:
        Path(args.output).write_text(asm)
    else:
        print(asm)

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="adder",
        description="Adder compiler — Python syntax to x86_64 native code"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Compile command
    compile_parser = subparsers.add_parser("compile", help="Compile to ELF")
    compile_parser.add_argument("source", help="Source file (.py)")
    compile_parser.add_argument("-o", "--output", help="Output file (.elf)")
    compile_parser.add_argument("--emit-asm", action="store_true",
                               help="Also emit assembly file")
    compile_parser.add_argument("--target", default=DEFAULT_TARGET,
                               choices=list(TARGETS),
                               help=f"Compilation target (default: {DEFAULT_TARGET})")
    compile_parser.add_argument("-O", dest="opt_level", type=int, default=0,
                               choices=[0, 1, 2],
                               help="Optimization level: 0 = trusted "
                                    "single-pass (default), 1 = x86 peephole "
                                    "optimizer, 2 = + stack-slot register "
                                    "promotion (Track 6)")
    compile_parser.add_argument("--check-bounds", dest="check_bounds",
                               action="store_true",
                               help="Emit runtime array-bounds checks for "
                                    "Array[N, T] indexing (userspace targets "
                                    "only; suppressed inside `unsafe:` blocks; "
                                    "no-op for kernel/bare-metal targets). "
                                    "See docs/adder_memory_safety.md")
    compile_parser.set_defaults(func=cmd_compile)

    # Asm command
    asm_parser = subparsers.add_parser("asm", help="Emit assembly only")
    asm_parser.add_argument("source", help="Source file (.py)")
    asm_parser.add_argument("-o", "--output", help="Output file (.s)")
    asm_parser.add_argument("--target", default=DEFAULT_TARGET,
                           choices=list(TARGETS),
                           help=f"Compilation target (default: {DEFAULT_TARGET})")
    asm_parser.add_argument("-O", dest="opt_level", type=int, default=0,
                           choices=[0, 1, 2],
                           help="Optimization level: 0 = trusted single-pass "
                                "(default), 1 = x86 peephole optimizer, "
                                "2 = + stack-slot register promotion")
    asm_parser.add_argument("--check-bounds", dest="check_bounds",
                           action="store_true",
                           help="Emit runtime array-bounds checks for "
                                "Array[N, T] indexing (userspace targets only; "
                                "suppressed inside `unsafe:` blocks). "
                                "See docs/adder_memory_safety.md")
    asm_parser.set_defaults(func=cmd_asm)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
