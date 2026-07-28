#!/usr/bin/env bash
# scripts/test_hamsh_lambda_host.sh — FAST, QEMU-free host gate for hamsh
# `lambda` expressions (user/hamsh.ad) and their integration with the
# higher-order builtins map / filter / sorted.
#
# What this proves:
#   * `lambda p1, p2: expr` parses to a callable VT_FUNC value (closure over
#     params + defaults);
#   * map / filter / sorted(key=…) accept an INLINE lambda, a NAMED builtin
#     (`map(len, …)`), and a VAR holding a lambda (`f = lambda …; map(f, …)`);
#   * a bare `(lambda a, b: a + b)(2, 3)` calls the function value directly;
#   * default lambda params (`lambda x, y=100: …`);
#   * the language-layer fix that unlocks `key=lambda e: e[1]` — a GLUED
#     subscript READ (`p[1]`, `c[0][1]`) in expression position (previously
#     only a space-separated `p [1]` or a list-literal index worked).
#
# hamsh spacing conventions exercised here (they are NOT lambda-specific):
#   * binary `+` / `*` are SPACE-FLANKED (`x * x`, `a + b`) — glued `x*x` is a
#     glob/`+arg` word, by long-standing lexer design;
#   * `lambda P: BODY` needs a space after the colon (the colon fuses onto a
#     bare word otherwise). Comparison (`x > 1`) and subscript (`p[1]`) glue
#     fine.
#
# Sibling of scripts/test_hamsh_pyesque_host.sh: the SAME shell source that
# runs as /init on-device is compiled for `x86_64-linux` and driven on the
# host in milliseconds — no boot, no QEMU. It also re-compiles the NATIVE
# shell for x86_64-adder-user to prove the /init (device) build is unaffected.
#
# Driven over a stdin PIPE with `--no-echo`: every marker below is produced by
# the tree-walking evaluator, not by echo of the typed line.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_lambda_host"
SCRIPT="$OUT/hamsh_lambda.hsh"
mkdir -p "$OUT"
fail=0

echo "[lambda-host] compiling hamsh for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsh.ad "$BIN" 2>"$OUT/lambda_compile.log"; then
    echo "[lambda-host] FAIL: host hamsh did not compile/link"
    cat "$OUT/lambda_compile.log"; exit 1
fi
echo "[lambda-host] PASS host hamsh compiled -> $BIN"

echo "[lambda-host] compiling NATIVE hamsh for x86_64-adder-user (regress guard) ..."
if ! adder_bin x86_64-adder-user user/hamsh.ad "$OUT/hamsh_lambda_native.elf" 2>"$OUT/lambda_native.log"; then
    echo "[lambda-host] FAIL: native (device) hamsh did not compile"
    cat "$OUT/lambda_native.log"; exit 1
fi
echo "[lambda-host] PASS native hamsh still compiles (device build unaffected)"

cat > "$SCRIPT" <<'HSH'
echo SORTKEY ${ sorted([[1,3],[2,1]], key=lambda p: p[1]) }
echo MAPSQ ${ map(lambda x: x * x, [1,2,3]) }
echo FILTERGT ${ filter(lambda x: x > 1, [1,2,3]) }
echo CALLV ${ (lambda a, b: a + b)(2, 3) }
echo MAPBUILTIN ${ map(len, ["a","bb","ccc"]) }
f = lambda x: x + 10
echo VARLAM ${ f(5) }
echo MAPVAR ${ map(f, [1,2,3]) }
g = lambda x, y=100: x + y
echo LAMDEF1 ${ g(1) }
echo LAMDEF2 ${ g(1, 2) }
echo NESTKEY ${ sorted([[3,1],[1,2],[2,3]], key=lambda r: r[0]) }
a = [10, 20, 30]
echo GLUEDIDX ${ a[1] }
echo CHAINIDX ${ [[1,3],[2,1]][0][1] }
exit
HSH

DUMP="$OUT/lambda_dump.txt"
timeout 30 "$BIN" --no-echo <"$SCRIPT" >"$DUMP" 2>"$OUT/lambda_stderr.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[lambda-host] FAIL: host shell exited rc=$rc (124=timeout/hung)"
    cat "$DUMP"; fail=1
fi

echo "[lambda-host] --- shell stdout ---"
cat "$DUMP"
echo "[lambda-host] --- end output ---"

check() {  # <expected-line> <description>
    if grep -qF -- "$1" "$DUMP"; then
        echo "[lambda-host] OK: $2"
    else
        echo "[lambda-host] WRONG (want '$1'): $2"; fail=1
    fi
}

check "SORTKEY [2, 1] [1, 3]"   "sorted(key=lambda p: p[1]) reorders by 2nd elem"
check "MAPSQ 1 4 9"             "map(lambda x: x * x, …)"
check "FILTERGT 2 3"           "filter(lambda x: x > 1, …)"
check "CALLV 5"                "(lambda a, b: a + b)(2, 3) == 5"
check "MAPBUILTIN 1 2 3"       "map(len, …) named-builtin callable still works"
check "VARLAM 15"              "call a var holding a lambda: f(5) == 15"
check "MAPVAR 11 12 13"        "map(f, …) with f a var-lambda"
check "LAMDEF1 101"            "lambda default param: g(1) == 1+100"
check "LAMDEF2 3"              "lambda default param overridden: g(1, 2) == 3"
check "NESTKEY [1, 2] [2, 3] [3, 1]" "sorted(key=lambda r: r[0]) on nested lists"
check "GLUEDIDX 20"            "glued subscript read a[1] in expression position"
check "CHAINIDX 3"             "chained glued subscript [[…]][0][1]"

if [ "$fail" -ne 0 ]; then
    echo "[lambda-host] FAIL"
    exit 1
fi
echo "[lambda-host] PASS"
