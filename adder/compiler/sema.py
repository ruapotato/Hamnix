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
    "int-from-ptr", # pointer stored into an integer without a cast — lossless
                    # on x86_64 and an established idiom in this tree
    "ptr-ptr",      # pointer of an incompatible pointee type
    "ret-value",    # value returned from `-> None`, or bare `return` from a
                    # value-returning function
    "int-float",    # float used where an integer is required (or vice versa)
    "cmp-sign",     # signed/unsigned mixed comparison (the `icmp slt` bug)
    "narrowing",    # assignment narrows an integer without a cast
    "deref",        # indexing / dereferencing a non-pointer, non-array
)

# The landable default, chosen from measured whole-tree counts — see the
# commit message and scripts/sema_scan.py.  A class is only an ERROR if the
# existing 905k-line corpus is clean (or near-clean and the hits are real
# bugs); everything noisier warns until the tree catches up.
DEFAULT_SEVERITY = {
    "arity":        "error",
    "kwarg":        "error",
    "not-callable": "off",      # needs full builtin/vtable modelling first
    "lit-range":    "error",
    "ptr-int":      "error",
    "int-from-ptr": "warning",
    "ptr-ptr":      "warning",
    "ret-value":    "warning",
    "int-float":    "warning",
    "cmp-sign":     "warning",
    "narrowing":    "off",      # ~every `uint64 = uint32` in the tree
    "deref":        "warning",
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


def _source_line(filename: str, line: int) -> Optional[str]:
    if not filename or filename.startswith("<"):
        return None
    lines = _SOURCE_CACHE.get(filename)
    if lines is None:
        try:
            with open(filename, "r", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            lines = []
        _SOURCE_CACHE[filename] = lines
    if 1 <= line <= len(lines):
        return lines[line - 1]
    return None


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
        out.append("      note: " + diag.note)
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

        # Per-function state
        self.scope: dict = {}
        self.ret: Optional[tuple] = None
        self.fname: str = "<toplevel>"

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
            # Widest wins; signedness follows the wider operand (mirrors what
            # the backend actually does when it recovers a width).
            return lt if lt[1] >= rt_[1] else rt_
        return lt if lt is not None else rt_

    # ---- compatibility ---------------------------------------------------

    def check_assignable(self, dst, src_expr, span, what: str) -> None:
        """Report any incompatibility between `dst` and the type of `src_expr`.

        `what` is a fragment naming the context, e.g. "argument 2 of 'foo'".
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
        self.check_types_assignable(dst, src, span, what)

    def check_types_assignable(self, dst, src, span, what: str) -> None:
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
                            % (type_name(src), type_name(dst), what), None)
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
                self.report("narrowing", span,
                            "'%s' narrowed to '%s' without a cast (%s)"
                            % (type_name(src), type_name(dst), what), None)
            return
        if dk == "struct" and sk == "struct" and dst[1] != src[1]:
            self.report("ptr-ptr", span,
                        "incompatible struct types: '%s' from '%s' (%s)"
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
        self.check_body(fn.body)

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
            self.check_body(st.body)
            return
        if isinstance(st, DeferStmt):
            self.check_stmt(st.stmt)
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
                        "'-> None'" % self.fname, None)
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
                            "cannot index a value of type '%s'"
                            % type_name(base), None)
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
                                % (type_name(lt), type_name(rt_)), None)
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
            self.report("not-callable", _span_of(f),
                        "call to undeclared function '%s'" % name, None)
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
                % (i + 1, params[i].name, _pretty(decl)))

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
    parts = []
    for p in decl.params:
        t = p.param_type
        parts.append("%s: %s" % (p.name, getattr(t, "name", "?")
                                 if t is not None else "?"))
    ret = decl.return_type
    return "declared as %s(%s)%s" % (
        _pretty(decl), ", ".join(parts),
        (" -> " + getattr(ret, "name", "?")) if ret is not None else "")


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
