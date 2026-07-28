#!/usr/bin/env bash
# scripts/test_hamsh_lang_host.sh — FAST, QEMU-free host gate for the hamsh
# LANGUAGE core (user/hamsh.ad): its Python-flavored lexer, parser, and
# tree-walking evaluator — arithmetic, expression interpolation, string
# builtins, for/while loops, if/else, function def+call, and variable
# expansion.
#
# Mirrors scripts/test_hamsh_complete_host.sh and the hamXXX_host dual-target
# seam (test_ham2048_host / test_hamsdl_host / test_jsengine_*_host): the SAME
# shell source that runs as /init on-device is compiled for the `x86_64-linux`
# Adder target and run DIRECTLY on the developer's host in milliseconds — no
# boot, no QEMU. user/linux-runtime.S supplies _start + the raw Linux syscall
# wrappers, and — new here — honest host implementations for the ~30
# kernel/namespace/9P syscalls the shell binds: real Linux syscalls where a
# faithful equivalent exists (cwd/chdir/dup/mmap/getuid/yield/setpgid, plus a
# genuine non-blocking read for the line editor) and fail-closed stubs
# (return -1, or 0/empty) for the Plan 9 namespace / chan / spawn ops that have
# no host analog. A host language test never reaches those.
#
# The DEVICE build is untouched: hamsh.ad is byte-identical, and this gate also
# re-compiles the NATIVE shell for x86_64-adder-user to prove no regression.
#
# We drive the shell over a stdin PIPE with `--no-echo`: the host runtime
# reports fd 0 as a pipe read-end so ed_readline skips its console getty-flush
# (which would discard the buffered script), and --no-echo keeps the shell from
# echoing the input back (so an assertion can never false-match a command that
# was typed but whose branch did not execute). Every marker below is therefore
# produced by the tree-walking evaluator, not by input echo.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_lang_host"
SCRIPT="$OUT/hamsh_lang.hsh"
mkdir -p "$OUT"
fail=0

echo "[lang-host] compiling hamsh LANGUAGE core for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsh.ad "$BIN" 2>"$OUT/lang_compile.log"; then
    echo "[lang-host] FAIL: host hamsh did not compile/link"
    cat "$OUT/lang_compile.log"; exit 1
fi
echo "[lang-host] PASS host hamsh compiled -> $BIN"

echo "[lang-host] compiling NATIVE hamsh for x86_64-adder-user (regress guard) ..."
if ! adder_bin x86_64-adder-user user/hamsh.ad "$OUT/hamsh_native.elf" 2>"$OUT/lang_native.log"; then
    echo "[lang-host] FAIL: native (device) hamsh did not compile"
    cat "$OUT/lang_native.log"; exit 1
fi
echo "[lang-host] PASS native hamsh still compiles (device build unaffected)"

# A single script that exercises the language surface. It is fed line-by-line
# over stdin; the shell runs each line through its lexer/parser/evaluator and
# quits on `exit`.
cat > "$SCRIPT" <<'HSH'
n = 10 * 4 + 2
echo ARITH_A $n
echo ARITH_B ${ 2 + 3 * 4 }
s = "world"
echo STR_CONCAT Kpre$s.txt
echo STR_LEN ${ len("abcd") }
echo STR_REPL ${ replace("/usr/bin", "/", ":") }
cnt = 0
for x in a b c d { cnt = cnt + 1 }
echo FOR_COUNT $cnt
i = 0
acc = 0
while i < 5 { acc = acc + i ; i = i + 1 }
echo WHILE_ACC $acc
if 1 > 0 { echo IF_TRUE } else { echo IF_FALSE }
if 0 > 1 { echo IF2_THEN } else { echo IF2_ELSE }
def dbl(v) { return v + v }
echo DEF_CALL ${ dbl(21) }
exit
HSH

DUMP="$OUT/lang_dump.txt"
# Drive over a stdin pipe with --no-echo. fd 2 carries dev bringup stage
# markers; the language OUTPUT is on fd 1.
timeout 30 "$BIN" --no-echo <"$SCRIPT" >"$DUMP" 2>"$OUT/lang_stderr.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[lang-host] FAIL: host shell exited rc=$rc (124=timeout/hung)"
    cat "$DUMP"; fail=1
fi

echo "[lang-host] --- shell stdout ---"
cat "$DUMP"
echo "[lang-host] --- end output ---"

# Each assertion: a marker line that ONLY the evaluator can produce, with the
# exact computed value. A wrong value (or a hang that truncates the run) fails.
check() {  # <expected-line> <description>
    if grep -qF -- "$1" "$DUMP"; then
        echo "[lang-host] OK: $2"
    else
        echo "[lang-host] WRONG (want '$1'): $2"; fail=1
    fi
}

check "ARITH_A 42"              "arithmetic: n = 10 * 4 + 2  (precedence)"
check "ARITH_B 14"             "expression interp: \${ 2 + 3 * 4 } == 14"
check "STR_CONCAT Kpreworld.txt" "variable expansion + adjacent concat"
check "STR_LEN 4"              "string builtin len()"
check "STR_REPL :usr:bin"       "string builtin replace()"
check "FOR_COUNT 4"            "for-loop accumulator (4 iterations)"
check "WHILE_ACC 10"           "while-loop accumulator (0+1+2+3+4)"
check "IF_TRUE"                "if/else: true branch"
check "IF2_ELSE"              "if/else: false branch -> else"
check "DEF_CALL 42"            "function def + call: dbl(21) == 42"

# Guard against a false-green truncated run: a wrong branch must NOT appear.
if grep -qF "IF_FALSE" "$DUMP" || grep -qF "IF2_THEN" "$DUMP"; then
    echo "[lang-host] FAIL: wrong conditional branch was taken"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[lang-host] FAIL"
    exit 1
fi
echo "[lang-host] PASS"
