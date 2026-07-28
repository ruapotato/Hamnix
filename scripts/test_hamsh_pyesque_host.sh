#!/usr/bin/env bash
# scripts/test_hamsh_pyesque_host.sh — FAST, QEMU-free host gate for the hamsh
# Python-esque expressiveness surface (user/hamsh.ad): sequence arithmetic
# (list `+` concatenation, string/list `*` repeat), for-in tuple unpacking over
# a dict's items(), and the ord/chr/bool/round scalar builtins.
#
# Sibling of scripts/test_hamsh_lang_host.sh: the SAME shell source that runs as
# /init on-device is compiled for the `x86_64-linux` Adder target and driven
# DIRECTLY on the developer's host in milliseconds — no boot, no QEMU. It also
# re-compiles the NATIVE shell for x86_64-adder-user to prove the byte-identical
# /init (device) build is unaffected.
#
# We drive the shell over a stdin PIPE with `--no-echo`, exactly as the lang
# host gate does: --no-echo suppresses input echo, so every marker below is
# produced by the tree-walking evaluator, not by echo of the typed line.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_pyesque_host"
SCRIPT="$OUT/hamsh_pyesque.hsh"
mkdir -p "$OUT"
fail=0

echo "[pyesque-host] compiling hamsh for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsh.ad "$BIN" 2>"$OUT/pyesque_compile.log"; then
    echo "[pyesque-host] FAIL: host hamsh did not compile/link"
    cat "$OUT/pyesque_compile.log"; exit 1
fi
echo "[pyesque-host] PASS host hamsh compiled -> $BIN"

echo "[pyesque-host] compiling NATIVE hamsh for x86_64-adder-user (regress guard) ..."
if ! adder_bin x86_64-adder-user user/hamsh.ad "$OUT/hamsh_pyesque_native.elf" 2>"$OUT/pyesque_native.log"; then
    echo "[pyesque-host] FAIL: native (device) hamsh did not compile"
    cat "$OUT/pyesque_native.log"; exit 1
fi
echo "[pyesque-host] PASS native hamsh still compiles (device build unaffected)"

cat > "$SCRIPT" <<'HSH'
a = [1, 2]
b = [3, 4]
c = a + b
echo LISTCAT ${ join(c, ",") }
echo LISTCAT_LEN ${ len(a + b) }
echo STRREP ${ "ab" * 3 }
zeros = [0] * 4
echo LISTREP ${ join(zeros, "-") }
echo LISTREP_LEN ${ len([7] * 5) }
d = {"x": 10, "y": 20}
tot = 0
for k, v in items(d) { tot = tot + v }
echo DICT_ITER_SUM $tot
echo ORD ${ ord("A") }
echo CHR ${ chr(90) }
echo BOOL_T ${ bool(3) }
echo BOOL_F ${ bool(0) }
echo ROUND_UP ${ round(3.7) }
echo ROUND_DN ${ round(3.2) }
echo ROUND_INT ${ round(5) }
exit
HSH

DUMP="$OUT/pyesque_dump.txt"
timeout 30 "$BIN" --no-echo <"$SCRIPT" >"$DUMP" 2>"$OUT/pyesque_stderr.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[pyesque-host] FAIL: host shell exited rc=$rc (124=timeout/hung)"
    cat "$DUMP"; fail=1
fi

echo "[pyesque-host] --- shell stdout ---"
cat "$DUMP"
echo "[pyesque-host] --- end output ---"

check() {  # <expected-line> <description>
    if grep -qF -- "$1" "$DUMP"; then
        echo "[pyesque-host] OK: $2"
    else
        echo "[pyesque-host] WRONG (want '$1'): $2"; fail=1
    fi
}

check "LISTCAT 1,2,3,4"       "list '+' concatenation"
check "LISTCAT_LEN 4"          "len() of a concatenated list"
check "STRREP ababab"          "string '*' repeat"
check "LISTREP 0-0-0-0"        "list '*' repeat"
check "LISTREP_LEN 5"          "len() of a repeated list"
check "DICT_ITER_SUM 30"       "for k, v in items(d): tuple-unpack + sum"
check "ORD 65"                 "ord('A') == 65"
check "CHR Z"                  "chr(90) == 'Z'"
check "BOOL_T true"            "bool(3) truthy"
check "BOOL_F false"           "bool(0) falsy"
check "ROUND_UP 4"             "round(3.7) == 4"
check "ROUND_DN 3"             "round(3.2) == 3"
check "ROUND_INT 5"            "round(5) passes an int through"

if [ "$fail" -ne 0 ]; then
    echo "[pyesque-host] FAIL"
    exit 1
fi
echo "[pyesque-host] PASS"
