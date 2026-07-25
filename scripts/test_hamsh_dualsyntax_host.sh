#!/usr/bin/env bash
# scripts/test_hamsh_dualsyntax_host.sh — FAST, QEMU-free host gate proving
# that hamsh accepts BOTH block syntaxes and MIXES them freely.
#
# hamsh (user/hamsh.ad) chooses a block's syntax PER BLOCK, from the token
# that opens the body (parse_suite, user/hamsh.ad:2416):
#     if pk_is_op(OP_LBRACE) != 0: return parse_block()      #  HEADER { ... }
#     if pk_is_op(OP_COLON)  != 0: return parse_colon_suite() #  HEADER: <indent>
#     ps_set_err("expected '{' or ':' to open block")
#
# This is the QEMU-free companion to scripts/test_hamsh_dualsyntax.sh (which
# proves the same thing on-device over the serial console, including the
# file-sourcing case that the host build cannot reach — the host runtime's
# namespace open() is a fail-closed stub, so `source` / rc-file dispatch
# always reports "cannot open file" here). Everything below therefore drives
# the shell over a stdin PIPE with --no-echo, exactly like
# scripts/test_hamsh_lang_host.sh: the same lexer/parser/evaluator, no boot.
#
# Cases:
#   A. pure Python-indent  (def / if / elif / else / for suites)
#   B. pure brace          (same program, one-liner brace form)
#   C. MIXED — brace `def` whose body uses indented if/else, AND an indented
#      `def` whose if/else bodies are braces. This is the load-bearing case:
#      it proves the choice is per-block, not per-file.
#   D. inline single-statement colon suite (`if 1: echo X`)
#   E. brace block whose body is spread over indented lines (the INDENT/DEDENT
#      emitted inside `{ }` must be swallowed as separators — _skip_seps)
#   F. a header with NEITHER opener is a clean parse error, not a hang
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_dualsyntax_host"
mkdir -p "$OUT"
fail=0

echo "[dualsyntax-host] compiling hamsh for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamsh.ad -o "$BIN" 2>"$OUT/dualsyntax_compile.log"; then
    echo "[dualsyntax-host] FAIL: host hamsh did not compile"
    cat "$OUT/dualsyntax_compile.log"; exit 1
fi

# Feed a script on stdin, strip the boot/stage/prompt chrome, return output.
run_hamsh() { timeout 30 "$BIN" --no-echo 2>&1 \
    | grep -v '^\[hamsh\|^hamsh — \|loop-enter\|ed-readline-first'; }

want() { # want <case> <expected-substring> <script>
    local name="$1" expect="$2" script="$3" got
    got="$(printf '%s' "$script" | run_hamsh)"
    if printf '%s' "$got" | grep -q -- "$expect"; then
        echo "[dualsyntax-host] PASS $name ($expect)"
    else
        echo "[dualsyntax-host] FAIL $name: expected '$expect'"
        printf '%s\n' "$got" | sed 's/^/    | /'
        fail=1
    fi
}

# --- A. pure Python-indent -------------------------------------------
want A-indent 'INDENT 5 pos' 'def classify(n):
    if n < 0:
        return "neg"
    elif n == 0:
        return "zero"
    else:
        return "pos"

for v in [-2, 0, 5]:
    echo INDENT ${v} ${classify(v)}

exit
'

# --- B. pure brace ---------------------------------------------------
want B-brace 'BRACE 5 pos' 'def classify(n) { if n < 0 { return "neg" } elif n == 0 { return "zero" } else { return "pos" } }
for v in [-2, 0, 5] { echo BRACE ${v} ${classify(v)} }
exit
'

# --- C. MIXED (the load-bearing case) --------------------------------
MIXED='def outer(n) {
    if n > 0:
        echo MIX_A pos ${n}
    else:
        echo MIX_A nonpos ${n}
    return n * 2
}
def inner(x):
    if x > 10 { return "big" }
    else { return "small" }

for v in [1, -1] { r = outer(v); echo MIX_B doubled ${r} }
echo MIX_C ${inner(3)} ${inner(30)}
exit
'
want C-mixed-brace-outer-indent-inner 'MIX_A pos 1'      "$MIXED"
want C-mixed-indent-outer-brace-inner 'MIX_C small big'  "$MIXED"
want C-mixed-negative-branch          'MIX_B doubled -2' "$MIXED"

# --- D. inline single-statement colon suite --------------------------
want D-inline-colon 'INLINE_TAKEN' 'if 1: echo INLINE_TAKEN
exit
'

# --- E. brace block with an indented multi-line body ------------------
want E-brace-indented-body 'E2_B' 'if 1 {
    echo E2_A
    echo E2_B
}
exit
'

# --- F. neither opener -> clean parse error --------------------------
want F-no-opener "expected '{' or ':' to open block" 'if 1 echo NOPE
exit
'

if [ "$fail" -eq 0 ]; then
    echo "[dualsyntax-host] VERDICT: PASS — indent and brace are interchangeable per block"
else
    echo "[dualsyntax-host] VERDICT: FAIL"
fi
exit "$fail"
