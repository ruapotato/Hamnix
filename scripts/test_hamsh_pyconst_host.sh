#!/usr/bin/env bash
# scripts/test_hamsh_pyconst_host.sh — FAST, QEMU-free host gate for the
# Python CAPITAL literals in hamsh python-mode (user/hamsh.ad):
#
#   * True  -> the same value as lowercase `true`   (VT_BOOL 1)
#   * False -> the same value as lowercase `false`  (VT_BOOL 0)
#   * None  -> hamsh's nil value (VT_NIL, renders as the empty string)
#
# These unblock Python-compatible code the prior hamsh round flagged:
#   sorted(xs, reverse=True)      and      if x is None: / x == None
#
# Also exercises the `is` / `is not` identity operators (mapped to value
# equality) with None-aware `==`/`!=` (None equals ONLY None — `0 == None`
# is False), and the lexer fix that lets a value-keyword be the LAST list
# element (`[True, False, None]`) without the `]` gluing into the word.
#
# Sibling of test_hamsh_pystr_host.sh / test_hamsh_pyesque_host.sh: the SAME
# shell source that runs as /init on-device is compiled for x86_64-linux and
# driven DIRECTLY on the host in milliseconds — no boot, no QEMU. It also
# re-compiles the NATIVE (device) build to prove /init is byte-unaffected.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_pyconst_host"
SCRIPT="$OUT/hamsh_pyconst.hsh"
mkdir -p "$OUT"
fail=0

echo "[pyconst-host] compiling hamsh for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsh.ad "$BIN" 2>"$OUT/pyconst_compile.log"; then
    echo "[pyconst-host] FAIL: host hamsh did not compile/link"
    cat "$OUT/pyconst_compile.log"; exit 1
fi
echo "[pyconst-host] PASS host hamsh compiled -> $BIN"

echo "[pyconst-host] compiling NATIVE hamsh for x86_64-adder-user (regress guard) ..."
if ! adder_bin x86_64-adder-user user/hamsh.ad "$OUT/hamsh_pyconst_native.elf" 2>"$OUT/pyconst_native.log"; then
    echo "[pyconst-host] FAIL: native (device) hamsh did not compile"
    cat "$OUT/pyconst_native.log"; exit 1
fi
echo "[pyconst-host] PASS native hamsh still compiles (device build unaffected)"

cat > "$SCRIPT" <<'HSH'
# --- capital literals equal their lowercase counterparts ---------------
echo TT ${ True == true }
echo FF ${ False == false }
echo TRUTHY ${ True }
echo FALSY ${ False }
# --- sorted(reverse=True): the headline blocked use case ---------------
echo SORT ${ join(sorted([3,1,2], reverse=True), ",") }
echo SORTF ${ join(sorted([3,1,2], reverse=False), ",") }
# --- None + identity / equality ----------------------------------------
x = None
echo NONERENDER A${ x }B
echo ISNONE ${ x is None }
echo EQNONE ${ x == None }
echo ISNOTNONE ${ 5 is not None }
echo NENONE ${ 5 != None }
echo ZERONONE ${ 0 == None }
echo EMPTYNONE ${ "" == None }
echo NONENONE ${ None == None }
# --- list construction with keyword literals (incl. trailing) ----------
lst = [True, False, None]
echo LISTLEN ${ len(lst) }
echo L0 ${ lst[0] }
echo L1 ${ lst[1] }
echo L2 X${ lst[2] }X
# --- if / not / ternary using the capital literals ---------------------
# (brace form on one line: the piped-stdin host driver cannot feed an
# indented colon-suite. The two syntaxes are interchangeable in hamsh.)
if True { echo IFTRUE taken }
if not False { echo IFNOTFALSE taken }
echo TERN ${ "yes" if True else "no" }
echo TERNF ${ "no" if False else "other" }
# --- subscripts still lex correctly after the lexer change -------------
xs = [9, 8, 7]
echo SUB ${ xs[0] }
grid = [[1,2],[3,4]]
echo NEST ${ grid[1][0] }
exit
HSH

DUMP="$OUT/pyconst_dump.txt"
timeout 30 "$BIN" --no-echo <"$SCRIPT" >"$DUMP" 2>"$OUT/pyconst_stderr.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[pyconst-host] FAIL: host shell exited rc=$rc (124=timeout/hung)"
    cat "$DUMP"; fail=1
fi

echo "[pyconst-host] --- shell stdout ---"
cat "$DUMP"
echo "[pyconst-host] --- end output ---"

check() {  # <expected-line> <description>
    if grep -qF -- "$1" "$DUMP"; then
        echo "[pyconst-host] OK: $2"
    else
        echo "[pyconst-host] WRONG (want '$1'): $2"; fail=1
    fi
}

check "TT true"            "True == true"
check "FF true"            "False == false"
check "TRUTHY true"        "True renders as true"
check "FALSY false"        "False renders as false"
check "SORT 3,2,1"         "sorted([3,1,2], reverse=True) -> 3,2,1"
check "SORTF 1,2,3"        "sorted([3,1,2], reverse=False) -> 1,2,3"
check "NONERENDER AB"      "None renders as the empty string (nil)"
check "ISNONE true"        "x is None  (x = None) is truthy"
check "EQNONE true"        "x == None  (x = None) is truthy"
check "ISNOTNONE true"     "5 is not None is truthy"
check "NENONE true"        "5 != None is truthy"
check "ZERONONE false"     "0 == None is FALSE (None equals only None)"
check "EMPTYNONE false"    "'' == None is FALSE"
check "NONENONE true"      "None == None is truthy"
check "LISTLEN 3"          "[True, False, None] constructs (3 elements)"
check "L0 true"            "list element 0 == True"
check "L1 false"           "list element 1 == False"
check "L2 XX"              "list element 2 == None (empty render)"
check "IFTRUE taken"       "if True: branch taken"
check "IFNOTFALSE taken"   "if not False: branch taken"
check "TERN yes"           "ternary condition True selects then-branch"
check "TERNF other"        "ternary condition False selects else-branch"
check "SUB 9"              "subscript xs[0] still lexes after the ']' fix"
check "NEST 3"             "nested subscript grid[1][0] still works"

if [ "$fail" -ne 0 ]; then
    echo "[pyconst-host] FAIL"
    exit 1
fi
echo "[pyconst-host] PASS"
