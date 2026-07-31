#!/usr/bin/env bash
# scripts/test_adder_app_sugar.sh — Adder app-ergonomics sugar
# (language roadmap increment 7): DEFAULT PARAMETER VALUES + KEYWORD
# ARGUMENTS. HOST-ONLY, NO QEMU.
#
# A DIRECT call to an in-unit `def` may:
#   * omit trailing arguments      -> filled from the parameter's declared
#     default (`def f(x, y=10)`; `f(5)` == `f(5, 10)`), and/or
#   * pass arguments by name        -> `f(y=2, x=1)`, in any order.
# Both DESUGAR at the call site into a plain positional argument list — no
# ABI change, no runtime cost. See docs/adder_language_roadmap.md (item 7).
#
# Verifies end to end:
#   (1) DEFAULT OMITTED / PASSED + KEYWORD ARGS: a program that mixes all
#       three compiles + runs to the exact expected exit code.
#   (2) ERRORS: unknown keyword, missing required arg, duplicate arg, and a
#       default-valued parameter preceding a required one are all COMPILE
#       ERRORS with a clear diagnostic (BOTH backends reject the bad decl).
#   (3) LOCKSTEP: seed and native emit byte-identical machine code for the
#       sugar program on x86_64-adder-user (the differential objdiff),
#       including NESTED normalized calls (the re-entrant window stack).
#   (4) BYTE-INERT-OFF: a call that supplies EVERY argument positionally
#       compiles to bytes IDENTICAL whether or not the callee declares a
#       trailing default — declaring/using the sugar never perturbs code
#       that doesn't use it.
#
# Deferred this increment (honest — see the roadmap STATUS): string methods
# (need a heap-backed string type; strings are raw Ptr[uint8] today),
# default/keyword args on METHODS and externs, and *args/**kwargs.
#
# Usage:  bash scripts/test_adder_app_sugar.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[sugar] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/app_sugar"
WORK="build/app_sugar"
mkdir -p "$WORK"

seedc() { # seedc <src> <out> ; compile with the Python seed to a host ELF
    python3 -m compiler.adder compile "$1" --target=x86_64-linux \
        -o "$2" >/dev/null 2>"$WORK/cerr"
}

echo "[sugar] (1) default-omitted + default-passed + keyword args -> runs to 40"
seedc "$FIX/sugar_ok.ad" "$WORK/ok" || { cat "$WORK/cerr"; fail "sugar_ok did not compile"; }
"$WORK/ok"; rc=$?
echo "[sugar]   sugar_ok exit = $rc (expect 40)"
[ "$rc" -eq 40 ] || fail "sugar_ok returned $rc, expected 40"

echo "[sugar] (1b) nested normalized calls (re-entrant window stack) -> 26"
seedc "$FIX/nested.ad" "$WORK/nested" || { cat "$WORK/cerr"; fail "nested did not compile"; }
"$WORK/nested"; rc=$?
echo "[sugar]   nested exit = $rc (expect 26)"
[ "$rc" -eq 26 ] || fail "nested returned $rc, expected 26"

echo "[sugar] (2) invalid uses must be COMPILE ERRORS"
# 2026-07-31: these are EXTENDED-REGEX patterns, not fixed strings, and they are
# deliberately phase-agnostic. Each of these four mistakes used to be caught by
# the x86 codegen call-normalizer ("x86: missing argument 'x' in call ...").
# a37d8f42 added a real sema pass that rejects the same programs EARLIER, with
# its own wording ("too few arguments to 'f': 1 given, 2 expected (missing
# 'x')"), so compilation now stops before codegen ever runs and the old fixed
# string never appears. The gate was pinning the phase, not the rule. What the
# gate actually guards is that the bad call is REJECTED and that the diagnostic
# names the offending parameter -- so match that, from either phase.
declare -A want=(
    [err_unknown_kw]="(no parameter named|unexpected keyword argument) 'z'"
    [err_missing_arg]="missing (argument )?'x'"
    [err_dup_arg]="'x'.*(given twice|multiple values)|(given twice|multiple values).*'x'"
    [err_default_before_required]="non-default parameter"
)
for e in err_unknown_kw err_missing_arg err_dup_arg err_default_before_required; do
    if seedc "$FIX/$e.ad" "$WORK/$e"; then
        fail "$e compiled clean (should be rejected)"
    fi
    grep -Eq "${want[$e]}" "$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "$e rejected without the expected diagnostic '${want[$e]}'"; }
    echo "[sugar]   rejected $e: $(grep -m1 -E '(^|: )error:|^x86:' "$WORK/cerr" | sed 's/^Error: //')"
done

echo "[sugar] (3) seed<->native byte-lockstep (objdiff) on sugar_ok + nested"
source scripts/_adder_cc.sh
ADDER_CC=adder adder_cc_bootstrap >/dev/null 2>&1 || fail "native bootstrap failed"
for f in sugar_ok nested; do
    ADDER_CC=python adder_cc_compile compile --target=x86_64-adder-user \
        "$FIX/$f.ad" -o "$WORK/$f.seed.elf" >/dev/null 2>&1 || fail "seed adder-user compile failed ($f)"
    ADDER_CC=adder adder_cc_compile compile --target=x86_64-adder-user \
        "$FIX/$f.ad" -o "$WORK/$f.nat.elf" >/dev/null 2>&1 || fail "native adder-user compile failed ($f)"
    python3 scripts/objdiff_normalize.py "$WORK/$f.seed.elf" "$WORK/$f.nat.elf" "$f" \
        || fail "seed<->native DIVERGED on $f"
    echo "[sugar]   objdiff CLEAN ($f)"
done

echo "[sugar] (3b) native ALSO rejects the bad default-before-required decl"
if ADDER_CC=adder adder_cc_compile compile --target=x86_64-adder-user \
        "$FIX/err_default_before_required.ad" -o "$WORK/edbr.nat.elf" >/dev/null 2>&1; then
    fail "native accepted a default-before-required declaration"
fi
echo "[sugar]   native rejects it too (backend parity)"

echo "[sugar] (4) byte-inert-off: an all-positional call is identical with/without a declared default"
seedc "$FIX/inert_with_default.ad" "$WORK/iwd" || { cat "$WORK/cerr"; fail "inert_with_default did not compile"; }
seedc "$FIX/inert_no_default.ad"   "$WORK/ind" || { cat "$WORK/cerr"; fail "inert_no_default did not compile"; }
cmp -s "$WORK/iwd" "$WORK/ind" \
    || fail "declaring a default perturbed a fully-explicit call site (NOT byte-inert)"
echo "[sugar]   fully-explicit call byte-identical with/without a declared default"

echo "[sugar] ALL PASS"
