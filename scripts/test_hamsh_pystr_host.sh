#!/usr/bin/env bash
# scripts/test_hamsh_pystr_host.sh — FAST, QEMU-free host gate for a NEW slice
# of hamsh Python-esque expressiveness (user/hamsh.ad):
#
#   * string classification predicates:  isdigit / isalpha / isalnum /
#     isspace / isupper / islower  (empty string is False for all; isupper /
#     islower require >=1 cased char and no char of the opposite case).
#   * integer base formatters:  hex(n) / oct(n) / bin(n)  with Python's
#     '0x'/'0o'/'0b' prefix and leading '-' for negatives.
#   * pow(base, exp)  (int**int>=0 stays int; float base or negative exp -> float)
#   * divmod(a, b)  with Python FLOOR semantics (remainder carries divisor sign).
#   * str.partition(sep) / str.rpartition(sep)  -> [head, sep, tail].
#
# Sibling of scripts/test_hamsh_pyesque_host.sh / test_hamsh_lang_host.sh: the
# SAME shell source that runs as /init on-device is compiled for x86_64-linux
# and driven DIRECTLY on the host in milliseconds — no boot, no QEMU. It also
# re-compiles the NATIVE (device) build to prove /init is byte-unaffected.
#
# Receivers here are VARIABLES / function-form. Quoted-literal method receivers
# (`"abc".upper()`) are now ALSO supported — covered by test_hamsh_parser2_host.sh.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsh_pystr_host"
SCRIPT="$OUT/hamsh_pystr.hsh"
mkdir -p "$OUT"
fail=0

echo "[pystr-host] compiling hamsh for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsh.ad "$BIN" 2>"$OUT/pystr_compile.log"; then
    echo "[pystr-host] FAIL: host hamsh did not compile/link"
    cat "$OUT/pystr_compile.log"; exit 1
fi
echo "[pystr-host] PASS host hamsh compiled -> $BIN"

echo "[pystr-host] compiling NATIVE hamsh for x86_64-adder-user (regress guard) ..."
if ! adder_bin x86_64-adder-user user/hamsh.ad "$OUT/hamsh_pystr_native.elf" 2>"$OUT/pystr_native.log"; then
    echo "[pystr-host] FAIL: native (device) hamsh did not compile"
    cat "$OUT/pystr_native.log"; exit 1
fi
echo "[pystr-host] PASS native hamsh still compiles (device build unaffected)"

cat > "$SCRIPT" <<'HSH'
digs = "12345"
mixed = "12a45"
empty = ""
echo ISDIGIT_T ${ isdigit(digs) }
echo ISDIGIT_F ${ isdigit(mixed) }
echo ISDIGIT_E ${ isdigit(empty) }
name = "Hello"
echo ISALPHA_T ${ isalpha(name) }
echo ISALPHA_F ${ isalpha(digs) }
echo ISALNUM_T ${ isalnum("abc123") }
echo ISALNUM_F ${ isalnum("abc 123") }
echo ISSPACE_T ${ isspace("  ") }
echo ISSPACE_F ${ isspace(" x ") }
upcase = "ABC123"
echo ISUPPER_T ${ isupper(upcase) }
echo ISUPPER_F ${ isupper("Abc") }
echo ISUPPER_NOCASE ${ isupper("123") }
locase = "abc9"
echo ISLOWER_T ${ islower(locase) }
echo ISLOWER_F ${ islower("aBc") }
echo HEX_POS ${ hex(255) }
echo HEX_NEG ${ hex(-255) }
echo HEX_ZERO ${ hex(0) }
echo OCT_8 ${ oct(8) }
echo BIN_5 ${ bin(5) }
echo POW_INT ${ pow(2, 10) }
echo POW_NEG ${ pow(2, -1) }
echo POW_ZERO ${ pow(7, 0) }
echo DIVMOD_POS ${ join(divmod(17, 5), ",") }
echo DIVMOD_NEG ${ join(divmod(-17, 5), ",") }
kv = "a=b=c"
echo PART_HIT ${ join(partition(kv, "="), "|") }
echo PART_MISS ${ join(partition("abc", "="), "|") }
echo RPART_HIT ${ join(rpartition(kv, "="), "|") }
echo RPART_MISS ${ join(rpartition("abc", "="), "|") }
line = "key=val"
echo PART_METHOD ${ join(line.partition("="), "|") }
exit
HSH

DUMP="$OUT/pystr_dump.txt"
timeout 30 "$BIN" --no-echo <"$SCRIPT" >"$DUMP" 2>"$OUT/pystr_stderr.txt"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[pystr-host] FAIL: host shell exited rc=$rc (124=timeout/hung)"
    cat "$DUMP"; fail=1
fi

echo "[pystr-host] --- shell stdout ---"
cat "$DUMP"
echo "[pystr-host] --- end output ---"

check() {  # <expected-line> <description>
    if grep -qF -- "$1" "$DUMP"; then
        echo "[pystr-host] OK: $2"
    else
        echo "[pystr-host] WRONG (want '$1'): $2"; fail=1
    fi
}

check "ISDIGIT_T true"        "isdigit('12345') is True"
check "ISDIGIT_F false"       "isdigit('12a45') is False"
check "ISDIGIT_E false"       "isdigit('') is False (empty)"
check "ISALPHA_T true"        "isalpha('Hello') is True"
check "ISALPHA_F false"       "isalpha('12345') is False"
check "ISALNUM_T true"        "isalnum('abc123') is True"
check "ISALNUM_F false"       "isalnum('abc 123') is False (space)"
check "ISSPACE_T true"        "isspace('  ') is True"
check "ISSPACE_F false"       "isspace(' x ') is False"
check "ISUPPER_T true"        "isupper('ABC123') is True"
check "ISUPPER_F false"       "isupper('Abc') is False"
check "ISUPPER_NOCASE false"  "isupper('123') is False (no cased char)"
check "ISLOWER_T true"        "islower('abc9') is True"
check "ISLOWER_F false"       "islower('aBc') is False"
check "HEX_POS 0xff"          "hex(255) == '0xff'"
check "HEX_NEG -0xff"         "hex(-255) == '-0xff'"
check "HEX_ZERO 0x0"          "hex(0) == '0x0'"
check "OCT_8 0o10"            "oct(8) == '0o10'"
check "BIN_5 0b101"           "bin(5) == '0b101'"
check "POW_INT 1024"          "pow(2, 10) == 1024 (int)"
check "POW_NEG 0.5"           "pow(2, -1) == 0.5 (float)"
check "POW_ZERO 1"            "pow(7, 0) == 1"
check "DIVMOD_POS 3,2"        "divmod(17, 5) == (3, 2)"
check "DIVMOD_NEG -4,3"       "divmod(-17, 5) == (-4, 3) (Python floor)"
check "PART_HIT a|=|b=c"      "partition splits at FIRST sep"
check "PART_MISS abc||"       "partition miss -> [s, '', '']"
check "RPART_HIT a=b|=|c"     "rpartition splits at LAST sep"
check "RPART_MISS ||abc"      "rpartition miss -> ['', '', s]"
check "PART_METHOD key|=|val" "d.partition() method form works"

if [ "$fail" -ne 0 ]; then
    echo "[pystr-host] FAIL"
    exit 1
fi
echo "[pystr-host] PASS"
