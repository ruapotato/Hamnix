"""Adder semantic analysis (type checking) pass.

Until this pass existed the whole Adder pipeline was

    parse  ->  affine-check  ->  codegen

with **no type checking at all**: type annotations were codegen hints that
selected instruction widths, not contracts.  `f(1)` for a two-parameter `f`
compiled clean and returned whatever the caller happened to leave in `%esi`;
`y: uint8 = 300` truncated silently; `Ptr[uint64] = Ptr[uint8]` needed no
cast.  That made Adder a language with *less* static checking than C, and it
cashed out as real shipped miscompiles (the `icmp slt`/`ult` signed-compare
bug came straight from unchecked signedness).

This module adds the missing pass.  It runs AFTER parse + import-merge and
BEFORE codegen, walks the merged program, and reports EVERY problem it finds
(not just the first) with `file:line:col`, the source line, and a caret span —
so a three-error program produces three diagnostics, the way gcc does.

Design notes
------------

*Adoptability.*  There are ~905k lines of existing Adder that compile today.
A checker that hard-errors on everything is unlandable, so every diagnostic
belongs to a named CLASS and each class has a SEVERITY (`error` / `warning` /
`off`).  The default policy in `DEFAULT_SEVERITY` hard-errors only on the
unambiguous, high-value classes measured to be clean across the whole tree
and warns on the rest.  `scripts/sema_scan.py` reports the per-class flag
counts that justify that split, and `ADDER_SEMA_*` env knobs let a build move
a class either way without a code change.

*Codegen inertness.*  This pass NEVER mutates the AST.  It is pure analysis,
so the seed/native byte-identity oracle (`test_native_vs_seed_kobjdiff.sh`)
is untouched by construction.

*No false positives over correctness.*  Where a type cannot be recovered the
checker yields `None` ("unknown") and stays silent.  Silence is always the
safe answer; a checker that cries wolf on working kernel code gets turned off
and then protects nothing.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional

from .ast_nodes import (
    ArrayType, Assignment, AssertStmt, BinaryExpr, BinOp, BoolLiteral,
    CallExpr, CastExpr, CharLiteral, ClassDef, ConditionalExpr,
    ContainerOfExpr, DeferStmt, DoWhileStmt, EnumDef, ExprStmt, ExternDecl,
    FloatLiteral, ForStmt, ForUnpackStmt, FunctionDef, FunctionPointerType,
    Identifier, IfStmt, IndexExpr, IntLiteral, MatchStmt, MemberExpr,
    MethodCallExpr, NoneLiteral, PercpuType, PointerType, Program,
    ReturnStmt, SizeOfExpr, SliceExpr, SliceType, StringLiteral, StringType,
    StructInitExpr, TupleUnpackAssign, Type, UnaryExpr, UnaryOp, UnionDef,
    UnsafeStmt, VarDecl, VolatileType, WalrusExpr, WhileStmt,
)

# --------------------------------------------------------------------------
# Diagnostic classes
# --------------------------------------------------------------------------
#
# Each class is a stable identifier that appears in the diagnostic text
# (`[arity]`) so it can be grepped, counted, and individually promoted or
# demoted.  Keep this list and DEFAULT_SEVERITY in sync.

CLASSES = (
    "arity",        # wrong number of arguments at a call site
    "kwarg",        # unknown / duplicated keyword argument
    "not-callable", # calling something that is not a function
    "lit-range",    # integer literal cannot be represented in the target type
    "ptr-int",      # INTEGER used where a POINTER is required — the crashing
                    # direction: the callee will dereference it
    "int-from-ptr", # pointer used where an integer is required
    "ptr-ptr",      # pointer of an incompatible pointee type
    "ret-value",    # value returned from `-> None`, or bare `return` from a
                    # value-returning function
    "int-float",    # float used where an integer is required (or vice versa)
    "cmp-sign",     # signed/unsigned mixed comparison (the `icmp slt` bug)
    "narrowing-arg",    # ARGUMENT narrows an integer without a cast — a
                        # wrong-TYPE-of-argument at a CALL SITE, which is
                        # exactly what the directive is about
    "narrowing-assign", # every OTHER narrowing (assignment, init, return);
                        # ~10.7k sites in-tree, so it cannot hard-error yet
    "deref",        # indexing / dereferencing a non-pointer, non-array
    "must-use",     # the result of a FALLIBLE call is discarded — the call
                    # reports failure only through its return value and
                    # nobody is looking at it
    "own-alias",    # a pointer this function OWNS is stored in two places
                    # without an explicit transfer (a LINT, not a borrow
                    # checker — see check_ownership)
)

# The landable default, chosen from measured whole-tree counts — see the
# commit message and scripts/sema_scan.py.  A class is only an ERROR if the
# existing 905k-line corpus is clean (or near-clean and the hits are real
# bugs); everything noisier warns until the tree catches up.
#
# WRONG TYPE OF ARGUMENT.  Every way an argument's type can disagree with its
# parameter's declared type is now an ERROR: `ptr-int` and `ptr-ptr` and
# `int-from-ptr` (pointer confusion), `int-float` (float/int confusion),
# `lit-range` (a constant with no representation in the parameter type) and
# `narrowing-arg` (a wider integer silently truncated to the parameter's
# width).  Together with `arity`/`kwarg` that makes "wrong args OR wrong type
# of args" a compile error, which is the whole point of the pass.
#
# `narrowing-assign` is the one deliberate hold-out.  It is NOT an argument
# check — it is `x: uint32 = some_uint64`, a local truncation the author is
# looking straight at, whereas a narrowed ARGUMENT is invisible from inside
# the callee.  11 sites remain in-tree (listed in the commit message); it
# warns until they are burned down.
DEFAULT_SEVERITY = {
    "arity":        "error",
    "kwarg":        "error",
    "not-callable": "off",      # needs full builtin/vtable modelling first
    "lit-range":    "error",
    "ptr-int":      "error",
    "int-from-ptr": "error",
    "ptr-ptr":      "error",
    "ret-value":    "warning",
    "int-float":    "error",
    "cmp-sign":     "warning",
    "narrowing-arg":    "error",
    "narrowing-assign": "warning",
    "deref":        "warning",
    # OPT-IN BY ANNOTATION.  Neither fires on a single line of unannotated
    # code, so both are on by default at `warning`: the cost of enabling
    # them tree-wide is exactly zero until someone writes the marker, and a
    # lint nobody can see is a lint nobody fixes.  They stay at `warning`
    # rather than `error` because the marker is a claim about intent, and a
    # mis-annotated callee must not be able to break the build.
    "must-use":     "warning",
    "own-alias":    "warning",
}


def severity_policy() -> dict:
    """Resolve the per-class severity policy, env overrides applied.

    * `ADDER_SEMA=0`          — disable the pass entirely (escape hatch).
    * `ADDER_SEMA_STRICT=1`   — promote every non-`off` class to `error`.
    * `ADDER_SEMA_ALL=1`      — additionally enable the `off` classes
                                (as warnings, or errors under STRICT).
    * `ADDER_SEMA_<CLASS>=error|warning|off` — per-class override, with `-`
                                in the class name spelled `_`
                                (e.g. `ADDER_SEMA_PTR_PTR=error`).
    """
    policy = dict(DEFAULT_SEVERITY)
    if os.environ.get("ADDER_SEMA_ALL") == "1":
        for k, v in policy.items():
            if v == "off":
                policy[k] = "warning"
    if os.environ.get("ADDER_SEMA_STRICT") == "1":
        for k, v in policy.items():
            if v != "off":
                policy[k] = "error"
    for cls in CLASSES:
        env = os.environ.get("ADDER_SEMA_" + cls.upper().replace("-", "_"))
        if env in ("error", "warning", "off"):
            policy[cls] = env
    return policy


# --------------------------------------------------------------------------
# Type lattice
# --------------------------------------------------------------------------
#
# A recovered type is one of:
#   ("int", bits, signed)  ("float", bits)  ("bool",)  ("void",)
#   ("ptr", T)  ("array", n, T)  ("fn", ret, (params...))
#   ("struct", name)  ("enum", name)  ("slice", T)  ("string",)
# or None, meaning "unknown — say nothing".

INT_KINDS = {
    "int8":   ("int", 8,  True),
    "int16":  ("int", 16, True),
    "int32":  ("int", 32, True),
    "int64":  ("int", 64, True),
    "uint8":  ("int", 8,  False),
    "uint16": ("int", 16, False),
    "uint32": ("int", 32, False),
    "uint64": ("int", 64, False),
    # `char` is UNSIGNED 8-bit in Adder (pinned, unlike C).
    "char":   ("int", 8,  False),
    # `bool` occupies a byte and compares as an integer; treat it as its own
    # kind so `bool` vs `int32` never produces a signedness complaint.
    "bool":   ("bool",),
    "int":    ("int", 32, True),
}

FLOAT_KINDS = {"float32": ("float", 32), "float64": ("float", 64)}

# Names the codegen lowers inline; they are not `def`s so they must not be
# reported as unknown callees, and their arity is checked from this table
# (None = do not check).
BUILTIN_ARITY = {
    "sizeof": (1, 1), "len": (1, 1),
    "min": (2, 2), "max": (2, 2), "abs": (1, 1), "clamp": (3, 3),
    "strlen": (1, 1), "container_of": (3, 3),
    "range": (1, 3),
    "inb": (1, 1), "inw": (1, 1), "inl": (1, 1),
    "outb": (2, 2), "outw": (2, 2), "outl": (2, 2),
    "asm_volatile": (1, 1),
    "atomic_cas32": (3, 3), "atomic_cas64": (3, 3),
    "atomic_add32": (2, 2), "atomic_add64": (2, 2),
    "print": (0, 99), "str": (1, 1), "ord": (1, 1), "chr": (1, 1),
}

# Type constructors usable in call position (`int32(x)` is parsed as a
# CastExpr, but `Ptr(...)`-shaped spellings and class constructors reach
# gen_call).  Never arity-checked.
_TYPE_NAMES = set(INT_KINDS) | set(FLOAT_KINDS) | {
    "float32", "float64", "str", "Ptr", "Array", "Slice", "String",
    "Percpu", "Fn", "Own", "None",
}


def _is_syscall_builtin(name: str) -> int:
    return (1 if (len(name) == 10 and name.startswith("__syscall")
                  and name[9] in "123456") else 0)


def resolve_type(t, structs: set, enums: set):
    """Lower a parser Type node into the internal lattice (None = unknown)."""
    if t is None:
        return None
    if isinstance(t, VolatileType):
        return resolve_type(t.inner_type, structs, enums)
    if isinstance(t, PointerType):
        return ("ptr", resolve_type(t.base_type, structs, enums))
    if isinstance(t, ArrayType):
        return ("array", t.size, resolve_type(t.element_type, structs, enums))
    if isinstance(t, SliceType):
        return ("slice", resolve_type(t.element_type, structs, enums))
    if isinstance(t, StringType):
        return ("string",)
    if isinstance(t, PercpuType):
        return resolve_type(t.base_type, structs, enums)
    if isinstance(t, FunctionPointerType):
        return ("fn",
                resolve_type(t.return_type, structs, enums),
                tuple(resolve_type(p, structs, enums) for p in t.param_types))
    if isinstance(t, Type):
        n = t.name
        if n in INT_KINDS:
            return INT_KINDS[n]
        if n in FLOAT_KINDS:
            return FLOAT_KINDS[n]
        if n == "None":
            return ("void",)
        if n in structs:
            return ("struct", n)
        if n in enums:
            return ("enum", n)
        return None            # unknown named type -> stay silent
    return None


def type_name(ty) -> str:
    """Render an internal type for a diagnostic."""
    if ty is None:
        return "?"
    k = ty[0]
    if k == "int":
        bits, signed = ty[1], ty[2]
        return ("int" if signed else "uint") + str(bits)
    if k == "float":
        return "float" + str(ty[1])
    if k == "bool":
        return "bool"
    if k == "void":
        return "None"
    if k == "ptr":
        return "Ptr[" + type_name(ty[1]) + "]"
    if k == "array":
        return "Array[%s, %s]" % (ty[1], type_name(ty[2]))
    if k == "slice":
        return "Slice[" + type_name(ty[1]) + "]"
    if k == "string":
        return "String"
    if k == "fn":
        return "Fn[%s%s]" % (type_name(ty[1]),
                             "".join(", " + type_name(p) for p in ty[2]))
    if k in ("struct", "enum"):
        return ty[1]
    return "?"


def _int_fits(value: int, bits: int, signed: bool) -> bool:
    """Does `value` name a representable BIT PATTERN for this int type?

    Deliberately two-sided: `x: uint8 = -1` is the universally used "all
    ones" idiom and must not be flagged, while `x: uint8 = 300` has no
    8-bit representation at all and is a genuine bug.  So the accepted set
    for an N-bit type is [-2^(N-1), 2^N - 1] regardless of signedness.
    """
    return -(1 << (bits - 1)) <= value <= (1 << bits) - 1


# --------------------------------------------------------------------------
# Diagnostics
# --------------------------------------------------------------------------

@dataclass
class Diagnostic:
    cls: str
    severity: str
    message: str
    span: Optional[object]
    note: Optional[str] = None

    def location(self) -> str:
        s = self.span
        if s is None:
            return "<unknown>"
        return "%s:%d:%d" % (getattr(s, "filename", "?") or "?",
                             getattr(s, "start_line", 0),
                             getattr(s, "start_col", 0))


_SOURCE_CACHE: dict = {}


def _source_lines(filename: str) -> list:
    if not filename or filename.startswith("<"):
        return []
    lines = _SOURCE_CACHE.get(filename)
    if lines is None:
        try:
            with open(filename, "r", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            lines = []
        _SOURCE_CACHE[filename] = lines
    return lines


def _source_line(filename: str, line: int) -> Optional[str]:
    lines = _source_lines(filename)
    if 1 <= line <= len(lines):
        return lines[line - 1]
    return None


# --------------------------------------------------------------------------
# Source annotations (`# must_use`, `# owns_return`, and the opt-outs)
# --------------------------------------------------------------------------
#
# WHY A COMMENT AND NOT A DECORATOR.  Adder parses `@name` decorators, but
# BOTH backends (`codegen_x86.py` and the self-hosted `codegen.ad`) hard-error
# on every decorator except `@unsafe`, and both are frozen bootstrap artifacts
# guarded by the seed<->native byte-identity oracle.  Introducing `@must_use`
# would mean editing them, which would mean re-proving that oracle for a pure
# ANALYSIS feature.  A marker comment costs the parser and both backends
# nothing — it is invisible to them — so this whole feature is codegen-inert
# by construction, exactly like the rest of this pass.
#
# The grammar is deliberately tiny:
#
#     # must_use: <why the caller has to look>
#     def _argv_push_cstr(s: Ptr[uint8]) -> int32:
#
#     # owns_return: caller owns the block and must kfree() it
#     def kmalloc(size: uint64) -> uint64:
#
# The marker must be in the comment block IMMEDIATELY above the `def` (no
# blank line between the block and the `def`), so prose two paragraphs up that
# happens to mention must_use cannot annotate anything by accident.
#
# The opt-outs are trailing comments on the offending line:
#     f(x)          # ignore-result   — dropping this status is deliberate
#     tbl.p = q     # alias-ok        — this second owner is deliberate
# plus, for `own-alias` only, an enclosing `unsafe:` block or an `@unsafe`
# function, which is the tree's established "I know what I am doing" idiom.

_MARK_RE = {
    "must_use":    "must_use",
    "must-use":    "must_use",
    "owns_return": "owns_return",
    "owns-return": "owns_return",
}

_ANNOT_CACHE: dict = {}


def _leading_comment_block(filename: str, def_line: int) -> list:
    """The contiguous `#` comment lines directly above line `def_line`."""
    lines = _source_lines(filename)
    if not (1 <= def_line <= len(lines)):
        return []
    out = []
    i = def_line - 2                       # 0-based index of the line above
    while i >= 0:
        s = lines[i].strip()
        if s.startswith("#"):
            out.append(s)
            i -= 1
            continue
        break                              # blank line or code: block ends
    out.reverse()
    return out


def annotations_of(decl) -> dict:
    """`{"must_use": reason, "owns_return": reason}` for a declaration.

    Returns only the keys actually present.  A marker with no `:` yields the
    empty string, which is still truthy as *presence* — callers must test
    `key in result`, not the value.
    """
    span = getattr(decl, "span", None)
    filename = getattr(span, "filename", None) or ""
    line = getattr(span, "start_line", 0) or 0
    key = (filename, line)
    hit = _ANNOT_CACHE.get(key)
    if hit is not None:
        return hit
    out: dict = {}
    for raw in _leading_comment_block(filename, line):
        body = raw.lstrip("#").strip()
        # tolerate `#[must_use]` / `# must_use` / `# must_use: reason`
        body = body.lstrip("[").rstrip("]")
        head, _, tail = body.partition(":")
        canon = _MARK_RE.get(head.strip().rstrip("]").lower())
        if canon is not None:
            out[canon] = tail.strip()
    _ANNOT_CACHE[key] = out
    return out


def _line_optout(span, *words) -> bool:
    """Is one of `words` present as a trailing comment on this line?"""
    if span is None:
        return False
    src = _source_line(getattr(span, "filename", "") or "",
                       getattr(span, "start_line", 0))
    if not src:
        return False
    idx = src.find("#")
    if idx < 0:
        return False
    tail = src[idx:].lower()
    return any(w in tail for w in words)


def render(diag: Diagnostic) -> str:
    """gcc-shaped rendering: location, severity, message, source line, caret."""
    out = ["%s: %s: %s [%s]" % (diag.location(), diag.severity,
                                diag.message, diag.cls)]
    s = diag.span
    if s is not None:
        line_no = getattr(s, "start_line", 0)
        src = _source_line(getattr(s, "filename", "") or "", line_no)
        if src is not None:
            col = max(1, getattr(s, "start_col", 1))
            end_line = getattr(s, "end_line", line_no)
            end_col = getattr(s, "end_col", col + 1)
            width = (end_col - col) if end_line == line_no else 1
            width = max(1, min(width, max(1, len(src) - col + 1)))
            gutter = "%5d | " % line_no
            out.append(gutter + src.expandtabs(4))
            # Re-derive the caret offset against the tab-expanded line so the
            # caret lands under the token the user can see.
            prefix = src[:col - 1].expandtabs(4)
            out.append(" " * 5 + " | " + " " * len(prefix)
                       + "^" + "~" * (width - 1))
    if diag.note:
        # A multi-line note renders as several `note:` lines — "what went
        # wrong" and "what to do about it" are different sentences and a
        # diagnostic that runs them together gets skim-read as one.
        for ln in str(diag.note).split("\n"):
            out.append("      note: " + ln)
    return "\n".join(out)


class SemaError(Exception):
    """Raised when the checker produced at least one `error`-severity
    diagnostic.  `diagnostics` holds every diagnostic, warnings included."""

    def __init__(self, diagnostics: list):
        self.diagnostics = diagnostics
        n = sum(1 for d in diagnostics if d.severity == "error")
        super().__init__("%d type error%s" % (n, "" if n == 1 else "s"))


# --------------------------------------------------------------------------
# The checker
# --------------------------------------------------------------------------

class Checker:
    def __init__(self, program: Program, policy: Optional[dict] = None,
                 max_diagnostics: int = 200):
        self.program = program
        self.policy = policy if policy is not None else severity_policy()
        self.max_diagnostics = max_diagnostics
        self.diagnostics: list = []
        self.counts: dict = {c: 0 for c in CLASSES}

        self.structs: set = set()
        self.enums: set = set()
        self.enum_variants: set = set()
        self.funcs: dict = {}        # name -> FunctionDef | ExternDecl
        self.globals: dict = {}      # name -> internal type
        self.fields: dict = {}       # struct name -> {field: internal type}
        self.methods: set = set()
        self.must_use: dict = {}     # callee name -> (reason, decl)
        self.owns_return: dict = {}  # callee name -> (reason, decl)

        # Per-function state
        self.scope: dict = {}
        self.ret: Optional[tuple] = None
        self.fname: str = "<toplevel>"
        self.defer_depth: int = 0    # `defer f()` discards by design
        self.unsafe_depth: int = 0   # inside an `unsafe:` block

    # ---- reporting -------------------------------------------------------

    def report(self, cls: str, span, message: str, note: str = None) -> None:
        sev = self.policy.get(cls, "warning")
        if sev == "off":
            return
        self.counts[cls] = self.counts.get(cls, 0) + 1
        if len(self.diagnostics) >= self.max_diagnostics:
            return
        self.diagnostics.append(Diagnostic(cls, sev, message, span, note))

    # ---- symbol collection ----------------------------------------------

    def collect(self) -> None:
        decls = self.program.declarations
        for d in decls:
            if isinstance(d, ClassDef):
                self.structs.add(d.name)
            elif isinstance(d, EnumDef):
                self.enums.add(d.name)
                for v in d.variants:
                    self.enum_variants.add(v.name)
            elif isinstance(d, UnionDef):
                self.structs.add(d.name)
        for d in decls:
            if isinstance(d, (FunctionDef, ExternDecl)):
                self.funcs[d.name] = d
                ann = annotations_of(d)
                if "must_use" in ann:
                    self.must_use[d.name] = (ann["must_use"], d)
                if "owns_return" in ann:
                    self.owns_return[d.name] = (ann["owns_return"], d)
            elif isinstance(d, VarDecl):
                self.globals[d.name] = resolve_type(d.var_type, self.structs,
                                                    self.enums)
            elif isinstance(d, ClassDef):
                flds = {}
                # Inheritance in Adder is field flattening; walk bases first
                # so a derived field shadows correctly.
                for base in d.bases:
                    flds.update(self.fields.get(base, {}))
                for f in d.fields:
                    flds[f.name] = resolve_type(f.field_type, self.structs,
                                                self.enums)
                self.fields[d.name] = flds
                for m in d.methods:
                    self.methods.add(m.name)
            elif isinstance(d, UnionDef):
                self.fields[d.name] = {
                    fn: resolve_type(ft, self.structs, self.enums)
                    for fn, ft in d.fields}

    # ---- type resolution helpers ----------------------------------------

    def rt(self, t):
        return resolve_type(t, self.structs, self.enums)

    def sig(self, decl):
        """(param internal types, return internal type) for a callee."""
        return ([self.rt(p.param_type) for p in decl.params],
                self.rt(decl.return_type))

    # ---- expression typing ----------------------------------------------

    def type_of(self, e):
        """Recover the type of an expression, or None if not confidently known."""
        if e is None:
            return None
        if isinstance(e, IntLiteral):
            # Untyped integer literal. A value that does not fit int64 (a
            # full-width mask such as 0xFFFFFFFFFFFFFFFF) is unsigned — typing
            # it signed made every `x > (0xFFFF.. / b)` look like a mixed-sign
            # comparison.
            return ("int", 64, e.value < (1 << 63))
        if isinstance(e, FloatLiteral):
            return ("float", 64)
        if isinstance(e, CharLiteral):
            return ("int", 8, False)
        if isinstance(e, BoolLiteral):
            return ("bool",)
        if isinstance(e, StringLiteral):
            return ("ptr", ("int", 8, False))  # a literal is Ptr[char]
        if isinstance(e, NoneLiteral):
            return None
        if isinstance(e, Identifier):
            if e.name in self.scope:
                return self.scope[e.name]
            if e.name in self.globals:
                return self.globals[e.name]
            if e.name in self.funcs:
                params, ret = self.sig(self.funcs[e.name])
                return ("fn", ret, tuple(params))
            return None
        if isinstance(e, CastExpr):
            return self.rt(e.target_type)
        if isinstance(e, SizeOfExpr):
            return ("int", 64, False)
        if isinstance(e, ContainerOfExpr):
            return ("ptr", ("struct", e.type_name))
        if isinstance(e, UnaryExpr):
            if e.op == UnaryOp.ADDR:
                inner = self.type_of(e.operand)
                if inner is None:
                    return None
                if inner[0] == "array":
                    return ("ptr", inner[2])
                return ("ptr", inner)
            if e.op == UnaryOp.DEREF:
                inner = self.type_of(e.operand)
                if inner is not None and inner[0] == "ptr":
                    return inner[1]
                return None
            if e.op == UnaryOp.NOT:
                return ("bool",)
            return self.type_of(e.operand)
        if isinstance(e, BinaryExpr):
            return self.type_of_binary(e)
        if isinstance(e, ConditionalExpr):
            a = self.type_of(getattr(e, "then_expr", None))
            return a if a is not None else self.type_of(
                getattr(e, "else_expr", None))
        if isinstance(e, WalrusExpr):
            return self.scope.get(e.name) or self.globals.get(e.name)
        if isinstance(e, IndexExpr):
            base = self.type_of(e.obj)
            if base is None:
                return None
            if base[0] == "ptr":
                return base[1]
            if base[0] == "array":
                return base[2]
            if base[0] == "slice":
                return base[1]
            if base[0] == "string":
                return ("int", 8, False)
            return None
        if isinstance(e, MemberExpr):
            return self.member_type(e)
        if isinstance(e, CallExpr):
            f = e.func
            if isinstance(f, Identifier):
                decl = self.funcs.get(f.name)
                if decl is not None and f.name not in self.scope:
                    return self.rt(decl.return_type)
                fty = self.scope.get(f.name) or self.globals.get(f.name)
                if fty is not None and fty[0] == "fn":
                    return fty[1]
                return None
            fty = self.type_of(f)
            if fty is not None and fty[0] == "fn":
                return fty[1]
            if fty is not None and fty[0] == "ptr" and fty[1] is not None \
                    and fty[1][0] == "fn":
                return fty[1][1]
            return None
        return None

    def member_type(self, e: MemberExpr):
        base = self.type_of(e.obj)
        if base is None:
            return None
        if base[0] == "ptr" and base[1] is not None:
            base = base[1]
        if base[0] == "slice" or base[0] == "string":
            if e.member == "len":
                return ("int", 64, False)
            if e.member == "ptr":
                return ("ptr", base[1] if base[0] == "slice"
                        else ("int", 8, False))
            return None
        if base[0] == "struct":
            return self.fields.get(base[1], {}).get(e.member)
        return None

    def type_of_binary(self, e: BinaryExpr):
        op = e.op
        if op in (BinOp.EQ, BinOp.NEQ, BinOp.LT, BinOp.LTE, BinOp.GT,
                  BinOp.GTE, BinOp.AND, BinOp.OR, BinOp.IN, BinOp.NOT_IN):
            return ("bool",)
        lt = self.type_of(e.left)
        rt_ = self.type_of(e.right)
        # Pointer arithmetic keeps the pointer type; `p - q` is a byte count.
        if lt is not None and lt[0] == "ptr":
            if op == BinOp.SUB and rt_ is not None and rt_[0] == "ptr":
                return ("int", 64, False)
            return lt
        if rt_ is not None and rt_[0] == "ptr" and op == BinOp.ADD:
            return rt_
        if lt is not None and lt[0] == "array":
            return ("ptr", lt[2])
        if lt is not None and lt[0] == "float":
            return lt
        if rt_ is not None and rt_[0] == "float":
            return rt_
        if lt is not None and rt_ is not None and lt[0] == "int" \
                and rt_[0] == "int":
            # An untyped integer CONSTANT has no width of its own: it adopts
            # the width of the other operand, exactly as C and Go do and
            # exactly as the backend emits it (`x + 1` for an int32 `x` is a
            # 32-bit add, not a 64-bit one).  Without this rule every
            # `f(x + 1)` for an int32 parameter looked like an int64 argument
            # being narrowed to int32 — 1802 of the 2122 call-site narrowing
            # reports were this one false positive.  A constant that does NOT
            # fit the other operand's type really does widen, so it still
            # falls through to the widest-wins rule below.
            lc = _int_literal_value(e.left)
            rc = _int_literal_value(e.right)
            if rc is not None and lc is None and _int_fits(rc, lt[1], lt[2]):
                return lt
            if lc is not None and rc is None and _int_fits(lc, rt_[1], rt_[2]):
                return rt_
            # Widest wins; signedness follows the wider operand (mirrors what
            # the backend actually does when it recovers a width).
            return lt if lt[1] >= rt_[1] else rt_
        # One side is unknown. Normally the known side is the best answer, but
        # if the known side is an untyped integer CONSTANT then by the rule
        # above it takes its width FROM the unknown side — so the result is
        # unknown, not int64. Returning int64 here is what made `g_len - 1`
        # (g_len's type dropped as ambiguous) report a bogus int64->int32
        # argument narrowing; silence is the safe answer for an unknown type.
        known, known_expr = (rt_, e.right) if lt is None else (lt, e.left)
        if known is not None and known[0] == "int" \
                and _int_literal_value(known_expr) is not None:
            return None
        return known

    # ---- compatibility ---------------------------------------------------

    def check_assignable(self, dst, src_expr, span, what: str,
                         ctx: str = "assign") -> None:
        """Report any incompatibility between `dst` and the type of `src_expr`.

        `what` is a fragment naming the context, e.g. "argument 2 of 'foo'".

        `ctx` is `"arg"` when `dst` is a PARAMETER type at a call site and
        `"assign"` everywhere else.  The two are separate diagnostic classes
        for the width-narrowing case: passing a `uint64` into a `uint32`
        parameter is a wrong-TYPE-of-argument bug the callee cannot see,
        while `x: uint32 = some_uint64` is a local truncation the author is
        looking straight at.  The tree has ~10.7k of the latter and few of
        the former, so only the former can hard-error today.
        """
        if dst is None:
            return
        # Integer-literal range is checked against the DECLARED type, before
        # the literal's own (64-bit) type would swallow the mismatch.
        lit = _int_literal_value(src_expr)
        if lit is not None:
            if dst[0] == "int" and not _int_fits(lit, dst[1], dst[2]):
                self.report("lit-range", _span_of(src_expr) or span,
                            "integer literal %d is not representable in "
                            "'%s' (%s)" % (lit, type_name(dst), what),
                            note="value must lie in [%d, %d]"
                                 % (-(1 << (dst[1] - 1)), (1 << dst[1]) - 1))
                return
            if dst[0] == "ptr" and lit != 0:
                self.report("ptr-int", _span_of(src_expr) or span,
                            "integer literal %d used where '%s' is required "
                            "(%s)" % (lit, type_name(dst), what),
                            note="only the literal 0 is a valid pointer "
                                 "constant; use cast[%s](...) if this is "
                                 "deliberate" % type_name(dst))
                return
            return

        src = self.type_of(src_expr)
        if src is None:
            return
        self.check_types_assignable(dst, src, span, what, ctx)

    def check_types_assignable(self, dst, src, span, what: str,
                               ctx: str = "assign") -> None:
        if dst is None or src is None:
            return
        dk, sk = dst[0], src[0]
        if dk == "void" or sk == "void":
            return
        # Arrays decay to a pointer to their element type.
        if sk == "array":
            src = ("ptr", src[2])
            sk = "ptr"
        if dk == "array":
            dst = ("ptr", dst[2])
            dk = "ptr"
        if dk == "ptr":
            if sk == "ptr":
                if not _pointee_compatible(dst[1], src[1]):
                    self.report("ptr-ptr", span,
                                "incompatible pointer types: '%s' from '%s' "
                                "(%s)" % (type_name(dst), type_name(src), what),
                                note="add an explicit cast[%s](...)"
                                     % type_name(dst))
                return
            if sk in ("int", "bool"):
                self.report("ptr-int", span,
                            "'%s' used where '%s' is required (%s)"
                            % (type_name(src), type_name(dst), what),
                            note="add an explicit cast[%s](...)"
                                 % type_name(dst))
                return
            if sk == "float":
                self.report("ptr-int", span,
                            "'%s' used where '%s' is required (%s)"
                            % (type_name(src), type_name(dst), what),
                            note="a float has no integer bit pattern the "
                                 "backend can put in an address register; "
                                 "this is almost certainly the wrong "
                                 "variable, not a missing cast")
            return
        if dk in ("int", "bool") and sk == "ptr":
            self.report("int-from-ptr", span,
                        "pointer '%s' used where '%s' is required (%s)"
                        % (type_name(src), type_name(dst), what),
                        note="add an explicit cast[%s](...)" % type_name(dst))
            return
        if dk == "float" and sk == "int":
            self.report("int-float", span,
                        "integer '%s' used where '%s' is required (%s)"
                        % (type_name(src), type_name(dst), what),
                        note="Adder has no implicit conversions; use "
                             "cast[%s](...)" % type_name(dst))
            return
        if dk == "int" and sk == "float":
            self.report("int-float", span,
                        "'%s' used where '%s' is required (%s)"
                        % (type_name(src), type_name(dst), what),
                        note="Adder has no implicit conversions; use "
                             "cast[%s](...)" % type_name(dst))
            return
        if dk == "int" and sk == "int":
            if src[1] > dst[1]:
                self.report(
                    "narrowing-arg" if ctx == "arg" else "narrowing-assign",
                    span,
                    "'%s' narrowed to '%s' without a cast (%s)"
                    % (type_name(src), type_name(dst), what),
                    note=("the callee only ever sees the low %d bits; add an "
                          "explicit cast[%s](...) if the truncation is "
                          "intended" % (dst[1], type_name(dst)))
                         if ctx == "arg" else None)
            return
        if dk == "struct" or sk == "struct":
            # Struct vs struct (different tags) AND struct vs scalar. In
            # practice structs reach a call site as `Ptr[T]`, which the
            # pointer branch above already covers; this closes the by-value
            # hole so a struct can never silently stand in for a scalar.
            if dk != sk or dst[1] != src[1]:
                self.report("ptr-ptr", span,
                            "incompatible types: '%s' from '%s' (%s)"
                            % (type_name(dst), type_name(src), what), None)
            return

    # ---- statements ------------------------------------------------------

    def check_function(self, fn: FunctionDef) -> None:
        self.fname = getattr(fn, "orig_name", None) or fn.name
        self.ret = self.rt(fn.return_type)
        self.scope = {}
        for p in fn.params:
            self.scope[p.name] = self.rt(p.param_type)
        # Pre-declare every local in the function so a use that textually
        # precedes its `x: T = ...` (legal across branches) still types.
        self.predeclare(fn.body)
        self.defer_depth = 0
        self.unsafe_depth = 0
        self.check_body(fn.body)
        self.check_ownership(fn)

    def predeclare(self, body, seen: Optional[dict] = None) -> None:
        """Seed the function scope with every local declaration.

        Adder locals are function-scoped for codegen purposes, so a use that
        textually precedes its `x: T = ...` (legal across branches) must still
        type. A name DECLARED TWICE with different types in one function —
        `sk: Ptr[uint8]` in one branch, `sk: int64` in another — has no single
        answer, so it is pinned to unknown rather than guessed."""
        if seen is None:
            seen = {}
        for st in body or []:
            if isinstance(st, VarDecl):
                ty = self.rt(st.var_type)
                if st.name in seen:
                    if type_name(seen[st.name]) != type_name(ty):
                        self.scope[st.name] = None
                        seen[st.name] = None
                elif st.name not in self.scope:
                    self.scope[st.name] = ty
                    seen[st.name] = ty
            for sub in _sub_bodies(st):
                self.predeclare(sub, seen)

    def check_body(self, body) -> None:
        for st in body or []:
            self.check_stmt(st)

    def check_stmt(self, st) -> None:
        if st is None:
            return
        if isinstance(st, VarDecl):
            declared = self.rt(st.var_type)
            if st.name not in self.scope:
                self.scope[st.name] = declared
            if st.value is not None:
                self.check_expr(st.value)
                self.check_assignable(declared, st.value, st.span,
                                      "initialising '%s'" % st.name)
            return
        if isinstance(st, Assignment):
            self.check_expr(st.value)
            self.check_expr(st.target)
            if getattr(st, "op", None) is None:
                dst = self.type_of(st.target)
                self.check_assignable(dst, st.value, st.span,
                                      "assignment to '%s'"
                                      % _describe(st.target))
            return
        if isinstance(st, ReturnStmt):
            self.check_expr(st.value)
            self.check_return(st)
            return
        if isinstance(st, ExprStmt):
            self.check_expr(st.expr)
            self.check_discarded(st)
            return
        if isinstance(st, (IfStmt,)):
            self.check_expr(st.condition)
            self.check_body(st.then_body)
            for cond, body in getattr(st, "elif_branches", []) or []:
                self.check_expr(cond)
                self.check_body(body)
            self.check_body(getattr(st, "else_body", None))
            return
        if isinstance(st, (WhileStmt, DoWhileStmt)):
            self.check_expr(st.condition)
            self.check_body(st.body)
            return
        if isinstance(st, ForStmt):
            # The loop variable's type is not annotated; leave it unknown.
            self.scope.setdefault(st.var, None)
            self.check_expr(st.iterable)
            self.check_body(st.body)
            return
        if isinstance(st, ForUnpackStmt):
            self.check_expr(getattr(st, "iterable", None))
            self.check_body(st.body)
            return
        if isinstance(st, UnsafeStmt):
            self.unsafe_depth += 1
            self.check_body(st.body)
            self.unsafe_depth -= 1
            return
        if isinstance(st, DeferStmt):
            # `defer close(fd)` discards by construction — a defer has
            # nowhere to put a result and no way to branch on one. Flagging
            # it would be pure noise, so the must-use check is suppressed
            # for the whole deferred statement.
            self.defer_depth += 1
            self.check_stmt(st.stmt)
            self.defer_depth -= 1
            return
        if isinstance(st, AssertStmt):
            self.check_expr(st.condition)
            return
        if isinstance(st, MatchStmt):
            self.check_expr(st.expr)
            for arm in st.arms:
                self.check_expr(getattr(arm, "guard", None))
                self.check_body(arm.body)
            return
        if isinstance(st, TupleUnpackAssign):
            self.check_expr(st.value)
            return
        for sub in _sub_bodies(st):
            self.check_body(sub)

    # ---- must-use --------------------------------------------------------

    def check_discarded(self, st: ExprStmt) -> None:
        """A call to a `# must_use` function used as a BARE STATEMENT.

        This is the whole dominant bug class of the tree in one check.  The
        defects that motivated it were not aliasing and not type confusion —
        they were an operation that FAILED, said so in its return value, and
        nobody was required to look:

            _argv_push_cstr dropped argument 64+ and returned 0  ->  `rm *`
            deleted 62 of 230 files and exited 0.

        Scope is deliberately narrow: `f(x)` alone on a line.  `x = f()`,
        `if f():`, `return f()` and `g(f())` all INSPECT the result in the
        only sense a compiler can check, so none of them is reported.  Rust's
        `#[must_use]` draws the line in exactly the same place, and the
        narrowness is what keeps the class quiet enough to leave on.
        """
        if self.defer_depth:
            return
        e = st.expr
        if not isinstance(e, CallExpr) or not isinstance(e.func, Identifier):
            return
        name = e.func.name
        if name in self.scope or name in self.globals:
            return                          # a function-pointer value
        hit = self.must_use.get(name)
        if hit is None:
            return
        reason, decl = hit
        span = _span_of(e.func) or _span_of(e) or st.span
        if _line_optout(span, "ignore-result", "must_use: ignore",
                        "must-use: ignore"):
            return
        ret = self.rt(decl.return_type)
        where = getattr(getattr(decl, "span", None), "filename", None)
        line = getattr(getattr(decl, "span", None), "start_line", 0)
        note = []
        if reason:
            note.append("'%s' returns %s: %s"
                        % (_pretty(decl), type_name(ret), reason))
        else:
            note.append("'%s' reports failure only through its %s result"
                        % (_pretty(decl), type_name(ret)))
        if where:
            note.append("declared `# must_use` at %s:%d" % (where, line))
        note.append("bind the result and branch on it, or write "
                    "`# ignore-result` on this line to state that dropping "
                    "it is deliberate")
        self.report("must-use", span,
                    "result of '%s' is discarded" % _pretty(decl),
                    note="\n".join(note))

    # ---- ownership lint --------------------------------------------------

    def check_ownership(self, fn: FunctionDef) -> None:
        """Warn when a pointer this function OWNS gains a second owner.

        This is a LINT, not a borrow checker, and the difference is the whole
        design.  A real checker would have to understand page tables,
        intrusive lists and hardware-aliased memory — every one of which
        legitimately stores one address in several places — so it would buy
        its soundness with an `unsafe` on the hottest code in the tree and
        change nothing about the defects we actually ship.

        So the rule is one sentence: a local initialised from a
        `# owns_return` function, then stored into TWO escaping locations
        (a global, a struct field, a `*p`, an array slot) with no intervening
        re-assignment, is reported ONCE, at the second store.  Two owners of
        one allocation is a double-free or a leak depending on which one
        frees first; which of the two it is, is beyond a lint, and the
        diagnostic says so rather than guessing.

        Everything that keeps the false-positive rate at zero is a deliberate
        narrowing:
          * it fires only for ANNOTATED allocators — unannotated code cannot
            produce a single report;
          * a store inside `unsafe:`, in an `@unsafe` function, or on a line
            marked `# alias-ok` is not counted at all (that is the escape
            hatch the design asked for, in the idiom the tree already uses);
          * only a BARE `p` counts as the stored value — `p + off`,
            `cast[...](p)` and `&p` are not the same pointer and are not
            tracked;
          * re-assigning `p` ends the old identity, so a loop that allocates
            into the same local each iteration reports nothing.
        """
        if "unsafe" in (getattr(fn, "decorators", None) or []):
            return
        owners: dict = {}       # local -> (alloc name, span)
        stores: dict = {}       # local -> [span, ...]
        reported: set = set()

        def visit(body, unsafe: int) -> None:
            for st in body or []:
                if isinstance(st, UnsafeStmt):
                    visit(st.body, unsafe + 1)
                    continue
                if isinstance(st, VarDecl):
                    src = _called_name(st.value)
                    if src is not None and src in self.owns_return:
                        owners[st.name] = (src, st.span)
                        stores[st.name] = []
                    elif st.name in owners:
                        owners.pop(st.name, None)
                elif isinstance(st, Assignment) \
                        and getattr(st, "op", None) is None:
                    tgt, val = st.target, st.value
                    if isinstance(tgt, Identifier):
                        src = _called_name(val)
                        if src is not None and src in self.owns_return:
                            # a fresh allocation into this local: new identity
                            owners[tgt.name] = (src, st.span)
                            stores[tgt.name] = []
                            continue
                        if tgt.name in owners and tgt.name not in self.globals:
                            # `p` now names something else; stop tracking it
                            owners.pop(tgt.name, None)
                            stores.pop(tgt.name, None)
                            continue
                    if isinstance(val, Identifier) and val.name in owners \
                            and _is_escaping_target(tgt, self.scope):
                        if unsafe or _line_optout(st.span, "alias-ok"):
                            continue
                        stores.setdefault(val.name, []).append(
                            (st.span, _describe(tgt)))
                        if len(stores[val.name]) == 2 \
                                and val.name not in reported:
                            reported.add(val.name)
                            self._report_alias(val.name, owners[val.name],
                                               stores[val.name])
                for sub in _sub_bodies(st):
                    visit(sub, unsafe)

        visit(fn.body, 0)

    def _report_alias(self, local, origin, sites) -> None:
        alloc, alloc_span = origin
        (first_span, first_desc), (second_span, second_desc) = sites
        decl = self.owns_return[alloc][1]
        note = [
            "'%s' was allocated by '%s' at %s:%d, which is declared "
            "`# owns_return`%s"
            % (local, _pretty(decl),
               getattr(alloc_span, "filename", "?") or "?",
               getattr(alloc_span, "start_line", 0),
               (" — " + self.owns_return[alloc][0])
               if self.owns_return[alloc][0] else ""),
            "the first owner is '%s', stored at %s:%d"
            % (first_desc, getattr(first_span, "filename", "?") or "?",
               getattr(first_span, "start_line", 0)),
            "two owners of one allocation is a double free or a leak "
            "depending on which one releases it; transfer the pointer "
            "(clear the first store) or copy the object",
            "if the aliasing is deliberate — a page table, an intrusive "
            "list, hardware-mapped memory — put this store inside "
            "`unsafe:` or write `# alias-ok` on the line",
        ]
        self.report("own-alias", second_span,
                    "owned pointer '%s' is stored in a second place ('%s')"
                    % (local, second_desc), note="\n".join(note))

    def check_return(self, st: ReturnStmt) -> None:
        declared = self.ret
        if st.value is None:
            if declared is not None and declared[0] != "void":
                self.report("ret-value", st.span,
                            "bare 'return' in '%s', which is declared to "
                            "return '%s'" % (self.fname, type_name(declared)),
                            note="return a value of type '%s'"
                                 % type_name(declared))
            return
        if declared is not None and declared[0] == "void":
            self.report("ret-value", st.span,
                        "value returned from '%s', which is declared "
                        "'-> None'" % self.fname,
                        note="the value is computed and then dropped — the "
                             "caller cannot see it. Give '%s' a return type, "
                             "or drop the expression." % self.fname)
            return
        self.check_assignable(declared, st.value, st.span,
                              "return from '%s'" % self.fname)

    # ---- expressions -----------------------------------------------------

    def check_expr(self, e) -> None:
        if e is None:
            return
        if isinstance(e, CallExpr):
            self.check_call(e)
            for a in e.args:
                self.check_expr(a)
            for a in e.kwargs.values():
                self.check_expr(a)
            return
        if isinstance(e, BinaryExpr):
            self.check_expr(e.left)
            self.check_expr(e.right)
            self.check_comparison(e)
            return
        if isinstance(e, UnaryExpr):
            self.check_expr(e.operand)
            return
        if isinstance(e, IndexExpr):
            self.check_expr(e.obj)
            self.check_expr(e.index)
            base = self.type_of(e.obj)
            if base is not None and base[0] in ("int", "bool", "float"):
                self.report("deref", _span_of(e.obj),
                            "cannot index '%s': it has scalar type '%s', "
                            "not a pointer, array or slice"
                            % (_describe(e.obj), type_name(base)),
                            note="if '%s' holds an ADDRESS, say so in its "
                                 "type (`Ptr[T]`) or index through "
                                 "`cast[Ptr[T]](%s)[...]`; an integer has no "
                                 "elements to index"
                                 % (_describe(e.obj), _describe(e.obj)))
            return
        if isinstance(e, MemberExpr):
            self.check_expr(e.obj)
            return
        if isinstance(e, MethodCallExpr):
            self.check_expr(e.obj)
            for a in e.args:
                self.check_expr(a)
            return
        if isinstance(e, CastExpr):
            self.check_expr(e.expr)
            return
        if isinstance(e, ConditionalExpr):
            for attr in ("condition", "then_expr", "else_expr"):
                self.check_expr(getattr(e, attr, None))
            return
        if isinstance(e, WalrusExpr):
            self.check_expr(e.value)
            dst = self.scope.get(e.name) or self.globals.get(e.name)
            self.check_assignable(dst, e.value, _span_of(e),
                                  "walrus assignment to '%s'" % e.name)
            return
        if isinstance(e, SliceExpr):
            for attr in ("obj", "start", "end", "step"):
                self.check_expr(getattr(e, attr, None))
            return
        if isinstance(e, StructInitExpr):
            for v in getattr(e, "fields", {}).values() if isinstance(
                    getattr(e, "fields", None), dict) else []:
                self.check_expr(v)
            return
        if isinstance(e, ContainerOfExpr):
            self.check_expr(e.expr)
            return

    def check_comparison(self, e: BinaryExpr) -> None:
        """Mixed signed/unsigned comparison — the `icmp slt` miscompile class.

        Only reported when BOTH sides have a confidently recovered integer
        type of the SAME width and DIFFERENT signedness, and neither side is
        a literal (a literal takes the other side's signedness in practice).
        That is the shape that actually miscompares.
        """
        if e.op not in (BinOp.LT, BinOp.LTE, BinOp.GT, BinOp.GTE):
            return
        if _int_literal_value(e.left) is not None or \
                _int_literal_value(e.right) is not None:
            return
        lt = self.type_of(e.left)
        rt_ = self.type_of(e.right)
        if lt is None or rt_ is None:
            return
        if lt[0] != "int" or rt_[0] != "int":
            if (lt[0] == "ptr") != (rt_[0] == "ptr"):
                if "int" in (lt[0], rt_[0]):
                    self.report("cmp-sign", _span_of(e),
                                "comparison between '%s' and '%s'"
                                % (type_name(lt), type_name(rt_)),
                                note="an address is being ordered against a "
                                     "plain integer; if that is intended, "
                                     "cast the pointer to `uint64` so the "
                                     "compare is unambiguously unsigned")
            return
        if lt[1] == rt_[1] and lt[2] != rt_[2]:
            self.report("cmp-sign", _span_of(e),
                        "comparison between signed '%s' and unsigned '%s'"
                        % (type_name(lt if lt[2] else rt_),
                           type_name(rt_ if lt[2] else lt)),
                        note="the backend picks ONE of signed/unsigned "
                             "compare for the whole expression; cast both "
                             "sides to the intended signedness")

    def check_call(self, e: CallExpr) -> None:
        f = e.func
        if not isinstance(f, Identifier):
            return
        name = f.name
        if name in self.scope or name in self.globals:
            return                       # function-pointer value; no signature
        decl = self.funcs.get(name)
        if decl is None:
            if name in BUILTIN_ARITY:
                lo, hi = BUILTIN_ARITY[name]
                n = len(e.args)
                if not (lo <= n <= hi):
                    self.report("arity", _span_of(e) or _span_of(f),
                                "builtin '%s' takes %s argument%s but %d "
                                "%s given" % (name, _range_str(lo, hi),
                                              "" if hi == 1 else "s", n,
                                              "was" if n == 1 else "were"),
                                None)
                return
            if _is_syscall_builtin(name) or name in _TYPE_NAMES \
                    or name in self.structs or name in self.enums \
                    or name in self.enum_variants or name in self.methods:
                return
            near = _did_you_mean(name, self.funcs)
            note = []
            if near is not None:
                note.append("did you mean '%s'?  %s"
                            % (_pretty(self.funcs[near]),
                               _signature_note(self.funcs[near])))
            note.append("nothing in this link unit declares '%s'; add a "
                        "`def`, an `extern def`, or the missing `from ... "
                        "import %s`" % (name, name))
            self.report("not-callable", _span_of(f),
                        "call to undeclared function '%s'" % name,
                        note="\n".join(note))
            return

        params = decl.params
        n_req = sum(1 for p in params if p.default is None)
        n_max = len(params)
        n_pos = len(e.args)

        if n_pos > n_max:
            self.report("arity", _span_of(e) or _span_of(f),
                        "too many arguments to '%s': %d given, %s expected"
                        % (_pretty(decl), n_pos, _range_str(n_req, n_max)),
                        note=_signature_note(decl))
            return

        # Bind keywords so under-supply is judged against the real slot map.
        by_name = {p.name: i for i, p in enumerate(params)}
        filled = [False] * n_max
        for i in range(n_pos):
            filled[i] = True
        bad_kw = False
        for kw in e.kwargs:
            j = by_name.get(kw)
            if j is None:
                self.report("kwarg", _span_of(e) or _span_of(f),
                            "'%s' has no parameter named '%s'"
                            % (_pretty(decl), kw),
                            note=_signature_note(decl))
                bad_kw = True
                continue
            if filled[j]:
                self.report("kwarg", _span_of(e) or _span_of(f),
                            "argument '%s' to '%s' given twice"
                            % (kw, _pretty(decl)), note=_signature_note(decl))
                bad_kw = True
            filled[j] = True
        if bad_kw:
            return

        missing = [params[i].name for i in range(n_max)
                   if not filled[i] and params[i].default is None]
        if missing:
            self.report("arity", _span_of(e) or _span_of(f),
                        "too few arguments to '%s': %d given, %s expected "
                        "(missing %s)"
                        % (_pretty(decl), n_pos + len(e.kwargs),
                           _range_str(n_req, n_max),
                           ", ".join("'%s'" % m for m in missing)),
                        note=_signature_note(decl))
            return

        # Argument types, positional slots only (keywords are rare and the
        # slot mapping above already validated their names).
        for i in range(min(n_pos, n_max)):
            pty = self.rt(params[i].param_type)
            self.check_assignable(
                pty, e.args[i], _span_of(e.args[i]) or _span_of(e),
                "argument %d ('%s') of '%s'"
                % (i + 1, params[i].name, _pretty(decl)), ctx="arg")

    # ---- driver ----------------------------------------------------------

    def run(self) -> list:
        self.collect()
        for d in self.program.declarations:
            if isinstance(d, FunctionDef):
                self.check_function(d)
            elif isinstance(d, ClassDef):
                for m in d.methods:
                    self.check_function(m)
            elif isinstance(d, VarDecl):
                self.fname = "<global %s>" % d.name
                self.ret = None
                self.scope = {}
                if d.value is not None:
                    self.check_assignable(
                        self.rt(d.var_type), d.value, d.span,
                        "initialising global '%s'" % d.name)
        return self.diagnostics


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def _pointee_compatible(a, b) -> bool:
    """Are `Ptr[a]` and `Ptr[b]` interchangeable without a cast?

    Deliberately permissive on the byte-ish types: `Ptr[uint8]`,
    `Ptr[char]` and `Ptr[int8]` are the same thing in this tree (a string
    literal is `Ptr[char]` and is passed to `Ptr[uint8]` parameters ~10k
    times), and `Ptr[?]` (unrecoverable pointee, e.g. an opaque named type)
    is compatible with everything.
    """
    if a is None or b is None:
        return True
    ak, bk = a[0], b[0]
    if ak == "void" or bk == "void":
        return True
    if ak == "int" and bk == "int":
        if a[1] == 8 and b[1] == 8:
            return True                 # uint8 / int8 / char are one type here
        return a[1] == b[1] and a[2] == b[2]
    if ak != bk:
        return False
    if ak == "ptr":
        return _pointee_compatible(a[1], b[1])
    if ak == "array":
        return a[1] == b[1] and _pointee_compatible(a[2], b[2])
    if ak in ("struct", "enum"):
        return a[1] == b[1]
    if ak == "float":
        return a[1] == b[1]
    return True


_FOLD = {
    BinOp.ADD: lambda a, b: a + b,
    BinOp.SUB: lambda a, b: a - b,
    BinOp.MUL: lambda a, b: a * b,
    BinOp.SHL: lambda a, b: a << b if 0 <= b < 64 else None,
    BinOp.SHR: lambda a, b: a >> b if 0 <= b < 64 else None,
    BinOp.BIT_OR: lambda a, b: a | b,
    BinOp.BIT_AND: lambda a, b: a & b,
    BinOp.BIT_XOR: lambda a, b: a ^ b,
}


def _int_literal_value(e):
    """Constant integer value of `e`, if it folds to one.

    Folds literal arithmetic, not just bare literals: `160 - 8` and
    `1 << 12` are written as constants all over the tree, and treating them
    as ordinary signed expressions produced a stream of bogus mixed-sign
    comparison warnings against `uint64` loop counters."""
    if isinstance(e, IntLiteral):
        return e.value
    if isinstance(e, CharLiteral):
        return None
    if isinstance(e, UnaryExpr) and e.op == UnaryOp.NEG:
        inner = _int_literal_value(e.operand)
        return None if inner is None else -inner
    if isinstance(e, UnaryExpr) and e.op == UnaryOp.BIT_NOT:
        inner = _int_literal_value(e.operand)
        return None if inner is None else ~inner
    if isinstance(e, BinaryExpr):
        fold = _FOLD.get(e.op)
        if fold is None:
            return None
        a = _int_literal_value(e.left)
        if a is None:
            return None
        b = _int_literal_value(e.right)
        if b is None:
            return None
        try:
            return fold(a, b)
        except (TypeError, ValueError):
            return None
    return None


def _span_of(e):
    """Best available span for a node, walking into children when the node
    itself carries none (the parser builds postfix/binary nodes without one)."""
    if e is None:
        return None
    s = getattr(e, "span", None)
    if s is not None:
        return s
    for attr in ("func", "left", "obj", "operand", "expr", "value",
                 "target", "condition"):
        child = getattr(e, attr, None)
        if child is not None and not isinstance(child, (str, int, float)):
            s = _span_of(child)
            if s is not None:
                return s
    args = getattr(e, "args", None)
    if args:
        return _span_of(args[0])
    return None


def _called_name(e) -> Optional[str]:
    """The callee name if `e` is a direct call `f(...)`, else None."""
    if isinstance(e, CallExpr) and isinstance(e.func, Identifier):
        return e.func.name
    return None


def _is_escaping_target(target, scope: dict) -> bool:
    """Does storing into `target` publish the value beyond this frame?

    A plain local is NOT escaping: `q = p` inside one function is a second
    NAME, not a second OWNER, and flagging it would fire on every `tmp = p`
    in the tree.  A global, a struct field, an array slot or a `*p` outlives
    the frame (or is reachable from something that does), so a pointer put
    there really is claimed by a second owner.
    """
    if isinstance(target, Identifier):
        return target.name not in scope
    if isinstance(target, (MemberExpr, IndexExpr)):
        return True
    if isinstance(target, UnaryExpr) and target.op == UnaryOp.DEREF:
        return True
    return False


def _describe(target) -> str:
    if isinstance(target, Identifier):
        return target.name
    if isinstance(target, MemberExpr):
        return _describe(target.obj) + "." + target.member
    if isinstance(target, IndexExpr):
        return _describe(target.obj) + "[...]"
    if isinstance(target, UnaryExpr) and target.op == UnaryOp.DEREF:
        return "*" + _describe(target.operand)
    return "<target>"


def _pretty(decl) -> str:
    return getattr(decl, "orig_name", None) or decl.name


def _range_str(lo: int, hi: int) -> str:
    return str(lo) if lo == hi else "%d to %d" % (lo, hi)


def _signature_note(decl) -> str:
    """The callee's declaration, verbatim enough to fix the call from.

    Defaults are spelled out: without them "1 given, 3 expected" plus a
    parameter list is still not enough to know WHICH arguments the caller is
    allowed to omit, which is the only question the reader has.
    """
    parts = []
    for p in decl.params:
        t = p.param_type
        text = "%s: %s" % (p.name, getattr(t, "name", "?")
                           if t is not None else "?")
        d = getattr(p, "default", None)
        if d is not None:
            text += " = " + _literal_text(d)
        parts.append(text)
    ret = decl.return_type
    where = getattr(decl, "span", None)
    note = "declared as %s(%s)%s" % (
        _pretty(decl), ", ".join(parts),
        (" -> " + getattr(ret, "name", "?")) if ret is not None else "")
    if where is not None and getattr(where, "filename", None):
        note += "\nat %s:%d" % (where.filename, getattr(where, "start_line", 0))
    return note


def _literal_text(e) -> str:
    """Short rendering of a default-argument expression."""
    v = _int_literal_value(e)
    if v is not None:
        return str(v)
    if isinstance(e, BoolLiteral):
        return "True" if e.value else "False"
    if isinstance(e, StringLiteral):
        return '"..."'
    if isinstance(e, NoneLiteral):
        return "None"
    if isinstance(e, Identifier):
        return e.name
    return "..."


def _did_you_mean(name: str, candidates) -> Optional[str]:
    """Closest known name to `name`, or None if nothing is close enough.

    Cheap edit-distance-free heuristic: same length +/-2 and a shared
    prefix/suffix, ranked by a difflib ratio.  Good enough to catch the
    typo/rename case that `not-callable` is really about, and it costs
    nothing because it only runs when a diagnostic is already firing.
    """
    import difflib
    hits = difflib.get_close_matches(name, list(candidates), n=1, cutoff=0.82)
    return hits[0] if hits else None


def _sub_bodies(st):
    """Every nested statement list hanging off a statement node."""
    out = []
    for attr in ("body", "then_body", "else_body", "try_body",
                 "finally_body", "else_clause"):
        v = getattr(st, attr, None)
        if isinstance(v, list):
            out.append(v)
    for cond, body in getattr(st, "elif_branches", []) or []:
        if isinstance(body, list):
            out.append(body)
    for arm in getattr(st, "arms", []) or []:
        b = getattr(arm, "body", None)
        if isinstance(b, list):
            out.append(b)
    for h in getattr(st, "handlers", []) or []:
        b = getattr(h, "body", None)
        if isinstance(b, list):
            out.append(b)
    inner = getattr(st, "stmt", None)
    if inner is not None:
        out.append([inner])
    return out


# --------------------------------------------------------------------------
# Public entry point
# --------------------------------------------------------------------------

def check_program(program: Program, policy: Optional[dict] = None,
                  max_diagnostics: int = 200):
    """Type-check `program`.  Returns (diagnostics, per-class counts).

    Never raises for a type problem — the caller decides what to do with the
    diagnostics.  Never mutates the AST.
    """
    checker = Checker(program, policy, max_diagnostics)
    diags = checker.run()
    return diags, checker.counts
