#!/usr/bin/env bash
# scripts/test_hamsh_nosilentwrong_host.sh — FAST, QEMU-free host gate for the
# hamsh rule that matters most: **hamsh never returns a confidently wrong
# value.** When the evaluator hits a hard limit or an undefined operation it
# must raise a DIAGNOSABLE error (stderr message + $status=1 + $errstr), not
# quietly hand back 0 / None / "".
#
# Every case below is a REPRO from docs/hamsh_review_2026-07-25.md (§6.1,
# §6.2, §6.3) plus the two extra silent-wrong classes found while fixing them
# (the COMP_MAX collection cap, and glued arithmetic lexing as one bare word).
# For each, the "before" behaviour is quoted in the case comment.
#
# Drive seam: the SAME shell source that runs as /init, compiled for
# x86_64-linux and fed over a stdin pipe with --no-echo — identical to
# scripts/test_hamsh_lang_host.sh. (The host build's namespace open() is a
# fail-closed stub, so FILE sourcing cannot be exercised here; every case runs
# through the REPL/stdin path, which is the same lexer/parser/evaluator.)

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_nosilent_host"
mkdir -p "$OUT"
fail=0

echo "[nosilent-host] compiling hamsh for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamsh.ad -o "$BIN" 2>"$OUT/nosilent_compile.log"; then
    echo "[nosilent-host] FAIL: host hamsh did not compile/link"
    cat "$OUT/nosilent_compile.log"; exit 1
fi
echo "[nosilent-host] PASS host hamsh compiled -> $BIN"

echo "[nosilent-host] compiling NATIVE hamsh for x86_64-adder-user (regress guard) ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamsh.ad -o "$OUT/hamsh_nosilent_native.elf" \
        2>"$OUT/nosilent_native.log"; then
    echo "[nosilent-host] FAIL: native (device) hamsh did not compile"
    cat "$OUT/nosilent_native.log"; exit 1
fi
echo "[nosilent-host] PASS native hamsh still compiles (device build unaffected)"

# run <name> <script-text> ; leaves combined output in $DUMP
DUMP="$OUT/nosilent_dump.txt"
run() {
    printf '%s\nexit\n' "$2" | timeout 60 "$BIN" --no-echo >"$DUMP" 2>&1
}

# want <marker> <description>   — the exact line/substring must appear
want() {
    if grep -qF -- "$1" "$DUMP"; then
        echo "[nosilent-host] OK: $2"
    else
        echo "[nosilent-host] WRONG (want '$1'): $2"
        sed -n '1,40p' "$DUMP"
        fail=1
    fi
}
# nowant <marker> <description> — the wrong answer must NOT appear
nowant() {
    if grep -qF -- "$1" "$DUMP"; then
        echo "[nosilent-host] WRONG (must not contain '$1'): $2"
        sed -n '1,40p' "$DUMP"
        fail=1
    else
        echo "[nosilent-host] OK: $2"
    fi
}

# ---------------------------------------------------------------- case 1
# review §6.2: SCOPE_MAX was 128 but the backing arrays were Array[64].
# BEFORE: the 65th binding's sc_name[64] overwrote sc_val[0..1] —
#   "RESULT 65 first= second=" (v1 and v2 silently destroyed).
# AFTER: 65 (and 128) bindings are intact; the 129th RAISES.
scope_script() {
    local n="$1" i
    echo 'v1 = 1'
    echo 'v2 = 2'
    for ((i = 3; i <= n; i++)); do echo "v$i = $i"; done
    echo 'echo SCOPE first=$v1 second=$v2'
}
run scope65 "$(scope_script 65)"
want "SCOPE first=1 second=2" "case 1a: the 65th binding no longer corrupts v1/v2"
run scope128 "$(scope_script 128)"
want "SCOPE first=1 second=2" "case 1b: a full 128-binding table is intact"
run scope140 "$(scope_script 140)"
want "runtime error: scope: too many variables" \
     "case 1c: overflowing the scope table ERRORS (never corrupts)"

# ---------------------------------------------------------------- case 2
# review §6.1: summing 0..19999 printed a plausible wrong total with an
# EMPTY $status and $errstr. (The measured 4096-iteration cut-off is the
# COMP_MAX range cap; the value arena is the next wall behind it.)
# BEFORE: "RES 8386560 STATUS  ERRSTR" — wrong, and claimed success.
# AFTER: a named runtime error, and the session still works afterwards.
run sum20000 's = 0
for i in range(20000) { s = s + i }
echo RES $s status=$status
echo STILLALIVE ${ 2 + 2 }'
want "runtime error: collection too large" "case 2a: range(20000) raises instead of truncating"
nowant "RES 8386560" "case 2b: the confidently-wrong total is gone"
want "status=1" "case 2c: \$status reports the failure"
want "STILLALIVE 4" "case 2d: the session survives the fault"

# A loop that fits the caps must still compute the RIGHT answer.
run sum3000 's = 0
for i in range(3000) { s = s + i }
echo RES3000 $s status=$status'
want "RES3000 4498500 status=0" "case 2e: an in-budget loop is exact and clean"

# The value arena (VAL_MAX) is the other exhaustion wall — also loud now.
run valarena 'i = 0
s = 0
while i < 5000 { s = s + i ; i = i + 1 }
echo RESW $s status=$status'
want "runtime error: value arena exhausted" "case 2f: value-cell exhaustion raises"

# ---------------------------------------------------------------- case 3
# review §6.3: `f(20)` on a recursive f returned 12 — the CALL_DEPTH_MAX
# truncation, reported as a number.
# BEFORE: "REC 12" with empty $errstr.
# AFTER: recursion inside the cap is exact; past it, an error.
run recursion 'def s(n) { if n <= 0 { return 0 } return n + s(n - 1) }
echo S10 ${ s(10) } status=$status
echo S20 ${ s(20) }
echo AFTER status=$status errstr=$errstr'
want "S10 55 status=0"  "case 3a: recursion within the cap is exact"
want "runtime error: call: recursion too deep" "case 3b: past the cap it RAISES"
want "errstr=call: recursion too deep" "case 3c: \$errstr names the cap"

# ---------------------------------------------------------------- case 4
# review §6.3: `1 / 0` and `5 % 0` returned 0.
# BEFORE: "DIV 0 STATUS  ERRSTR".
run div0 'echo DIV ${ 1 / 0 }
echo AFTER status=$status errstr=$errstr'
want "runtime error: division by zero" "case 4a: 1/0 raises"
nowant "DIV 0"                         "case 4b: the command does not run with the bogus 0"
want "errstr=division by zero"         "case 4c: \$errstr carries it"
run mod0 'echo MOD ${ 5 % 0 }
echo M2 ${ 7 // 0 }'
want "runtime error: integer division or modulo by zero" "case 4d: 5 % 0 and 7 // 0 raise"
# ...while ordinary division is untouched (Python-3 true division).
run divok 'echo OK ${ 7 / 2 } ${ 7 // 2 } ${ 7 % 2 }'
want "OK 3.5 3 1" "case 4e: normal division/floordiv/mod are unchanged"

# ---------------------------------------------------------------- case 5
# review §6.3: int bitwise `& | ^` fell through _arith to 0; `~` was not
# even lexed (silently dropped).
# BEFORE: "BIT 0 0 0 5".
run bitwise 'echo BIT ${ 6 & 3 } ${ 6 | 3 } ${ 6 ^ 3 } ${ ~5 }'
want "BIT 2 7 5 -6" "case 5a: integer & | ^ ~ compute real bit arithmetic"
run setops 'echo SETS ${ {1,2} | {2,3} } ${ {1,2} & {2,3} }'
want "SETS {1, 2, 3} {2}" "case 5b: set algebra on the same operators still works"
run bitbad 'echo BAD ${ "a" & 3 }'
want "runtime error: unsupported operand type for bitwise" \
     "case 5c: a non-integer operand raises instead of yielding 0"

# ---------------------------------------------------------------- case 6
# review §4/§6.3: POSIX parameter expansion rendered as nothing.
# BEFORE: "${x:-zz}" -> empty, "${#y}" -> empty.
run pexp 'echo DEF1 ${x:-zz}
y = "abc"
echo DEF2 ${y:-zz} LEN ${#y} LEN0 ${#x}
echo PLUS ${y:+yes} NOPLUS ${x:+yes} END
echo EQ ${z:=dflt} then $z
echo EXPR ${ 2 + 3 } ${y}'
want "DEF1 zz"            "case 6a: \${x:-zz} yields the default"
want "DEF2 abc LEN 3 LEN0 0" "case 6b: \${y:-zz} keeps the value; \${#y} is its length"
want "PLUS yes NOPLUS  END"    "case 6c: \${y:+word} / \${x:+word}"
want "EQ dflt then dflt"  "case 6d: \${z:=dflt} assigns as well as expands"
want "EXPR 5 abc"         "case 6e: ordinary \${ expr } / \${var} are untouched"
run pexpq 'echo Q ${q:?q is required}
echo AFTER status=$status'
want "runtime error: q is required" "case 6f: \${q:?msg} raises with the message"

# ---------------------------------------------------------------- case 7
# Found while re-testing the review's recursion case: `s(n-1)` lexes `n-1`
# as ONE bare word ('-' is a word character), so it reached the evaluator
# as an undefined NAME and evaluated to nil == 0.
# BEFORE: `def s(n) { ... return n + s(n-1) }` ; s(3) -> 3, silently.
run glued 'def s(n) { if n <= 0 { return 0 } return n + s(n-1) }
x = s(3)
echo RES $x status=$status'
want "undefined name 'n-1'" "case 7a: glued arithmetic is reported, not substituted"
nowant "RES 3 status=0"     "case 7b: the wrong answer 3 is not produced"
# ...but an ordinary unset shell variable stays empty (the boot rc relies on it).
run unsetvar 'if $nosuchvar { echo BAD_TRUE } else { echo GOOD_EMPTY }
echo E $nosuchvar status=$status'
want "GOOD_EMPTY"    "case 7c: an unset \$VAR is still falsy/empty, not an error"
want "E  status=0"   "case 7d: ...and does not set a failure status"

# ---------------------------------------------------------------- case 8
# The faults are ordinary hamsh exceptions: catchable, and an error inside a
# called def propagates out of the calling EXPRESSION (it used to be swallowed,
# handing the caller a nil that read as 0).
run catch 'try { echo T ${ 1 / 0 } } except as e { echo CAUGHT $e }
echo AFTER ok status=$status'
want "CAUGHT division by zero" "case 8a: try/except catches a runtime fault"
want "AFTER ok status=0"       "case 8b: the shell continues normally after catching"
run raisefn 'def boom() { raise "ValueError: nope" }
try { x = boom() ; echo NOTREACHED $x } except as e { echo CAUGHT2 $e }'
want "CAUGHT2 ValueError: nope" "case 8c: a raise inside a def propagates to the caller"
nowant "NOTREACHED"             "case 8d: the caller does not run on with a nil result"

# ---------------------------------------------------------------- case 9
# review P1 #4/#5: the two bash spellings a new user reaches for first were
# PARSE ERRORS. `$?` is now an alias for $status; `$(cmd)` lexes to the same
# token as Plan 9's `` `{cmd} ``. (Capture returns empty on the host — external
# spawn is a fail-closed stub there — so this asserts they PARSE and evaluate,
# which is what used to fail outright.)
run bashisms 'true
echo Q1 $?
false
echo Q2 $? status=$status
v = $(echo hi)
echo CAP done'
want "Q1 0"     "case 9a: \$? reads the last status"
want "Q2 1 status=1" "case 9b: \$? tracks a failing command, same as \$status"
want "CAP done" "case 9c: \$(cmd) parses as command substitution"
nowant "parse error" "case 9d: neither spelling is a parse error any more"

if [ "$fail" -ne 0 ]; then
    echo "[nosilent-host] FAIL"
    exit 1
fi
echo "[nosilent-host] PASS — no silent wrong answers in any reviewed case"
