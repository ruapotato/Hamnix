#!/usr/bin/env bash
# scripts/test_adder_sema.sh — Adder STATIC TYPE CHECKER (adder/compiler/sema.py).
# HOST-ONLY, NO QEMU.
#
# Until this pass landed the Adder pipeline was parse -> affine-check -> codegen
# with no semantic analysis at all, so Adder had LESS static checking than C:
#   * `f(1)` for `def f(a: int32, b: int32)` COMPILED, and `main` returned a
#     different value on every run (`b` = whatever was left in %esi);
#   * `y: uint8 = 300` was accepted and silently truncated;
#   * `Ptr[uint64] = Ptr[uint8]` needed no cast;
#   * an `int32` passed where `Ptr[uint8]` was declared was accepted.
# All four of those are this gate's fixtures (tests/sema/).
#
# Verifies:
#   (1) REJECT wrong arity, out-of-range integer literal, and int-where-pointer
#       — each with a `file:line:col`, a source line and a caret.
#   (2) MULTI-ERROR: a three-error program reports all THREE (gcc parity), not
#       just the first.
#   (3) WARN (not reject) on the incompatible-pointer class, which is still
#       being burned down across the tree.
#   (4) SILENT + still compiles + still RUNS on well-typed code (no false
#       positives), exit code 42.
#   (5) ESCAPE HATCH: ADDER_SEMA=0 restores the old behaviour exactly.
#   (6) CODEGEN-INERT: the emitted assembly for a well-typed program is
#       BYTE-IDENTICAL with the checker on and off — the pass is pure analysis
#       and cannot perturb the seed<->native objdiff oracle.
#
# Usage:  bash scripts/test_adder_sema.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[sema] FAIL $*"; exit 1; }
ok()   { echo "[sema] ok   $*"; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/sema"
WORK="build/sema_check"
rm -rf "$WORK"; mkdir -p "$WORK"

# compile <src> <out-elf> -> rc, stderr in $WORK/cerr
compile() {
    python3 -m compiler.adder compile "$1" --target=x86_64-linux \
        -o "$2" >/dev/null 2>"$WORK/cerr"
}

# ---- (1) the three hard-error classes ------------------------------------
check_reject() { # check_reject <fixture> <class> <needle>
    local src="$FIX/$1.ad" cls="$2" needle="$3"
    compile "$src" "$WORK/$1.elf" && fail "$1 compiled; expected rejection"
    grep -q "\[$cls\]" "$WORK/cerr" || {
        cat "$WORK/cerr"; fail "$1: no [$cls] diagnostic"; }
    grep -q "$needle" "$WORK/cerr" || {
        cat "$WORK/cerr"; fail "$1: diagnostic text missing '$needle'"; }
    # file:line:col + caret line
    grep -qE "$1\.ad:[0-9]+:[0-9]+: error:" "$WORK/cerr" || {
        cat "$WORK/cerr"; fail "$1: diagnostic has no file:line:col"; }
    grep -qE '^ +\| *\^' "$WORK/cerr" || {
        cat "$WORK/cerr"; fail "$1: diagnostic has no caret line"; }
    ok "$1 rejected [$cls] with location + caret"
}

check_reject sema_arity        arity     "too few arguments to 'f'"
check_reject sema_lit_range    lit-range "not representable in 'uint8'"
check_reject sema_int_where_ptr ptr-int  "used where 'Ptr\[uint8\]' is required"

# ---- (2) multi-error diagnostics (gcc parity) -----------------------------
compile "$FIX/sema_three_errors.ad" "$WORK/three.elf" \
    && fail "sema_three_errors compiled; expected rejection"
n=$(grep -cE ': error: ' "$WORK/cerr")
[ "$n" -eq 3 ] || { cat "$WORK/cerr"; fail "expected 3 errors, got $n"; }
for cls in lit-range arity ptr-int; do
    grep -q "\[$cls\]" "$WORK/cerr" || fail "three-error program: missing [$cls]"
done
ok "three-error program reports all 3 errors"

# ---- (3) incompatible pointer types are REJECTED --------------------------
check_reject sema_ptr_mismatch ptr-ptr \
    "incompatible pointer types: 'Ptr\[uint64\]' from 'Ptr\[uint8\]'"

# ---- (3b) WRONG TYPE OF ARGUMENT at a call site is REJECTED ---------------
# The user directive: "calling a function with the wrong args or the wrong
# type of args should cause an error". Wrong NUMBER of args is (1) above;
# this is the wrong-TYPE half — one call of each class, all five reported
# from ONE compile.
compile "$FIX/sema_arg_types.ad" "$WORK/argty.elf" \
    && fail "sema_arg_types compiled; a wrong-type argument must be rejected"
n=$(grep -cE ': error: ' "$WORK/cerr")
[ "$n" -eq 5 ] || { cat "$WORK/cerr"; fail "expected 5 arg-type errors, got $n"; }
for cls in narrowing-arg ptr-ptr int-from-ptr int-float ptr-int; do
    grep -q "error:.*\[$cls\]" "$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "arg types: missing [$cls] error"; }
    grep -q "\[$cls\]" "$WORK/cerr" && \
    grep -qE "argument [0-9]+ \('[a-z0-9_]+'\) of '" "$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "[$cls]: no argument-slot attribution"; }
done
grep -qE '^ +\| *\^' "$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "arg types: no caret line"; }
ok "wrong-TYPE argument rejected: 5 classes, argument slot named, carets"

# ---- (3c) the remaining warning tier still compiles -----------------------
compile "$FIX/sema_narrow_assign.ad" "$WORK/narr.elf" \
    || { cat "$WORK/cerr"; fail "narrowing-assign warning must NOT be fatal"; }
grep -q "warning:.*\[narrowing-assign\]" "$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "expected a [narrowing-assign] warning"; }
ok "narrowing ASSIGNMENT warns without blocking the build"

# ---- (3d) an untyped integer literal does not fabricate a narrowing -------
# `x + 1` for an int32 `x` is an int32, exactly as the backend emits it.
# Getting this wrong made 1802 of 2122 call-site narrowing reports bogus and
# would have made this class unlandable.
cat > "$WORK/litw.ad" <<'ADEOF'
def sink(x: int32, y: uint8):
    return


def main() -> int32:
    a: int32 = 100
    b: uint8 = 7
    sink(a + 1, b - 2)
    sink(a * 2 - 3, b + 1)
    return 0
ADEOF
compile "$WORK/litw.ad" "$WORK/litw.elf" \
    || { cat "$WORK/cerr"; fail "literal-width arithmetic rejected"; }
grep -qE ': (error|warning): ' "$WORK/cerr" \
    && { cat "$WORK/cerr"; fail "untyped literal fabricated a diagnostic"; }
ok "untyped integer literal adopts the other operand's width"

# ---- (4) no false positives on well-typed code ----------------------------
compile "$FIX/sema_ok.ad" "$WORK/ok.elf" \
    || { cat "$WORK/cerr"; fail "well-typed program rejected"; }
grep -qE ': (error|warning): ' "$WORK/cerr" \
    && { cat "$WORK/cerr"; fail "well-typed program produced diagnostics"; }
"$WORK/ok.elf"; rc=$?
[ "$rc" -eq 42 ] || fail "sema_ok.elf exit $rc, expected 42"
ok "well-typed program: silent, compiles, runs (exit 42)"

# ---- (5) escape hatch ------------------------------------------------------
ADDER_SEMA=0 python3 -m compiler.adder compile "$FIX/sema_arity.ad" \
    --target=x86_64-linux -o "$WORK/arity_bypass.elf" \
    >/dev/null 2>"$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "ADDER_SEMA=0 must bypass the checker"; }
ok "ADDER_SEMA=0 restores the pre-checker behaviour"

# ---- (6) the pass is codegen-inert ----------------------------------------
python3 -m compiler.adder compile "$FIX/sema_ok.ad" --target=x86_64-linux \
    --emit-asm -o "$WORK/on.elf" >/dev/null 2>&1
mv -f "$FIX/sema_ok.s" "$WORK/on_keep.s" 2>/dev/null
ADDER_SEMA=0 python3 -m compiler.adder compile "$FIX/sema_ok.ad" \
    --target=x86_64-linux --emit-asm -o "$WORK/off.elf" >/dev/null 2>&1
mv -f "$FIX/sema_ok.s" "$WORK/off_keep.s" 2>/dev/null
[ -s "$WORK/on_keep.s" ] || fail "no assembly emitted with the checker on"
cmp -s "$WORK/on_keep.s" "$WORK/off_keep.s" \
    || fail "checker perturbed codegen (on.s != off.s)"
ok "codegen byte-identical with the checker on and off"

echo "[sema] PASS"
