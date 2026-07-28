#!/usr/bin/env bash
# scripts/test_hamsh_parser2_host.sh — FAST, QEMU-free host gate for two hamsh
# parser gaps closed in user/hamsh.ad:
#
#   1. LITERAL / expression method receiver.  Previously only a VARIABLE or the
#      function form worked (`x="abc"; x.upper()` / `upper("abc")`); a quoted
#      string LITERAL as the receiver (`"abc".upper()`) was silently dropped by
#      the parser. parse_postfix now desugars `<value>.method(args)` to
#      `method(value, args)` for ANY already-parsed receiver — string, list,
#      dict, or a parenthesised expression — and chains (`s.split(",")[0].upper()`).
#
#   2. `**` power operator.  Only `pow(a, b)` existed. `**` is now a real
#      operator: right-associative (`2**3**2 == 512`), binding tighter than a
#      unary minus on its left (`-2**2 == -4`) and than `*` (`2*3**2 == 18`),
#      with a signed exponent allowed (`2**-1 == 0.5`). int**non-neg-int stays
#      an exact int; a float base/exp or negative exp promotes to float — the
#      same value semantics as pow() (shared _ipow/_fpow helpers).
#
# Sibling of scripts/test_hamsh_pystr_host.sh / test_hamsh_pyesque_host.sh: the
# SAME shell source that runs as /init on-device is compiled for x86_64-linux
# and driven DIRECTLY on the host in milliseconds — no boot, no QEMU. It also
# re-compiles the NATIVE (device) build to prove /init is byte-unaffected.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_parser2_host"
SCRIPT="$OUT/hamsh_parser2.hsh"
mkdir -p "$OUT"
fail=0

echo "[parser2-host] compiling hamsh for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsh.ad "$BIN" 2>"$OUT/parser2_compile.log"; then
    echo "[parser2-host] FAIL: host hamsh did not compile/link"
    cat "$OUT/parser2_compile.log"; exit 1
fi
echo "[parser2-host] PASS host hamsh compiled -> $BIN"

echo "[parser2-host] compiling NATIVE hamsh for x86_64-adder-user (regress guard) ..."
if ! adder_bin x86_64-adder-user user/hamsh.ad "$OUT/hamsh_parser2_native.elf" 2>"$OUT/parser2_native.log"; then
    echo "[parser2-host] FAIL: native (device) hamsh did not compile"
    cat "$OUT/parser2_native.log"; exit 1
fi
echo "[parser2-host] PASS native hamsh still compiles (device build unaffected)"

cat > "$SCRIPT" <<'HSH'
# --- gap 1: literal / expression method receiver ---
echo LOWER ${ "Hello".lower() }
echo UPPER ${ "Hello".upper() }
echo SPLITLEN ${ len("a,b,c".split(",")) }
echo SPLITHEAD ${ "a,b,c".split(",")[0] }
echo LISTSORT ${ join([3,1,2].sorted(), ",") }
echo DICTKEYS ${ join({"b": 2, "a": 1}.keys(), ",") }
echo CHAIN ${ "a,b".split(",")[0].upper() }
echo INTPAREN ${ (255).hex() }
# variable / function forms MUST still work exactly as before
v = "abc"
echo VARFORM ${ v.upper() }
echo FNFORM ${ upper("abc") }
# --- gap 2: ** power operator ---
echo POW ${ 2**10 }
echo RASSOC ${ 2**3**2 }
echo PREC ${ -2**2 }
echo PRECMUL ${ 2*3**2 }
echo NEGEXP ${ 2**-1 }
echo FLOATBASE ${ 2.0**3 }
echo POWFN ${ pow(2, 10) }
exit
HSH

DUMP="$OUT/parser2_dump.txt"
timeout 30 "$BIN" --no-echo <"$SCRIPT" >"$DUMP" 2>"$OUT/parser2_stderr.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[parser2-host] FAIL: host shell exited rc=$rc (124=timeout/hung)"
    cat "$DUMP"; fail=1
fi

echo "[parser2-host] --- shell stdout ---"
cat "$DUMP"
echo "[parser2-host] --- end output ---"

check() {  # <expected-line> <description>
    if grep -qF -- "$1" "$DUMP"; then
        echo "[parser2-host] OK: $2"
    else
        echo "[parser2-host] WRONG (want '$1'): $2"; fail=1
    fi
}

# gap 1
check "LOWER hello"    "\"Hello\".lower() == 'hello' (string literal receiver)"
check "UPPER HELLO"    "\"Hello\".upper() == 'HELLO'"
check "SPLITLEN 3"     "\"a,b,c\".split(\",\") has length 3"
check "SPLITHEAD a"    "\"a,b,c\".split(\",\")[0] == 'a' (method then index)"
check "LISTSORT 1,2,3" "[3,1,2].sorted() == [1,2,3] (list literal receiver)"
check "DICTKEYS b,a"   "{...}.keys() (dict literal receiver, insertion order)"
check "CHAIN A"        "\"a,b\".split(\",\")[0].upper() == 'A' (chained method)"
check "INTPAREN 0xff"  "(255).hex() == '0xff' (parenthesised int receiver)"
check "VARFORM ABC"    "x.upper() variable receiver STILL works"
check "FNFORM ABC"     "upper('abc') function form STILL works"
# gap 2
check "POW 1024"       "2**10 == 1024 (int power)"
check "RASSOC 512"     "2**3**2 == 512 (right-associative)"
check "PREC -4"        "-2**2 == -4 (unary minus binds looser than **)"
check "PRECMUL 18"     "2*3**2 == 18 (** binds tighter than *)"
check "NEGEXP 0.5"     "2**-1 == 0.5 (signed exponent -> float)"
check "FLOATBASE 8"    "2.0**3 == 8 (float base)"
check "POWFN 1024"     "pow(2, 10) == 1024 (builtin unchanged)"

if [ "$fail" -ne 0 ]; then
    echo "[parser2-host] FAIL"
    exit 1
fi
echo "[parser2-host] PASS"
