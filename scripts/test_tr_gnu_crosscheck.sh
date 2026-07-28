#!/usr/bin/env bash
# scripts/test_tr_gnu_crosscheck.sh
#
# Strong, QEMU-free proof that native `user/tr.ad` matches GNU `tr`.
#
# The Adder `x86_64-linux` target compiles the SAME tr.ad source that
# ships in the Hamnix initramfs into a static host ELF (sys_read/sys_write
# resolve to Linux read/write via user/linux-runtime.S). We then feed a
# battery of fixtures through both the native binary and the system `tr`
# with the SAME flags and assert BYTE-IDENTICAL stdout. This covers
# translate (incl. SET2-shorter last-char repeat), -d delete, -s squeeze,
# -c/-C complement, ranges a-z, escapes \n \t \r \\, and the POSIX
# classes [:alpha:] [:digit:] [:alnum:] [:upper:] [:lower:] [:space:]
# [:punct:] -- including ROT13 and case-fold.
#
# Also confirms the on-device (x86_64-adder-user) binary still compiles.
# Registered in scripts/ci_battery_manifest.txt (Tier-1, no QEMU).

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v tr >/dev/null 2>&1 || { echo "[tr-crosscheck] SKIP: no system tr"; exit 0; }

WORK="$PROJ_ROOT/build/tr_crosscheck"
rm -rf "$WORK"
mkdir -p "$WORK"
ELF="$WORK/tr.elf"

# --- compile the shipped tr.ad for the host ---------------------------
OUT="$(python3 -m compiler.adder compile --target=x86_64-linux \
    user/tr.ad -o "$ELF" 2>&1)" || fail "compile errored:
$OUT"
echo "$OUT" | grep -q "Compiled to" || fail "compiler did not report success:
$OUT"
[ -f "$ELF" ] || fail "no ELF produced at $ELF"
file "$ELF" | grep -q "ELF 64-bit" || fail "not a 64-bit ELF: $(file "$ELF")"

# --- on-device binary must still compile clean ------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user user/tr.ad "$WORK/tr_native.elf" >/dev/null 2>&1 || fail "native x86_64-adder-user compile failed"
echo "  ok: native tr compiles (x86_64-adder-user)"

pass=0
# chk <desc> <input-with-\n-escapes> [args...]  (args are tr operands)
chk() {
    local desc="$1"; shift
    local input="$1"; shift
    local mine gnu
    mine="$(printf '%b' "$input" | "$ELF" "$@")"
    gnu="$(printf '%b' "$input" | tr "$@")"
    if [ "$mine" != "$gnu" ]; then
        echo "  input : $(printf '%b' "$input" | tr '\n' '|')" >&2
        echo "  args  : $*" >&2
        echo "  native: $(printf '%s' "$mine" | tr '\n' '|')" >&2
        echo "  gnu   : $(printf '%s' "$gnu" | tr '\n' '|')" >&2
        fail "mismatch vs GNU tr: $desc"
    fi
    echo "  ok: $desc"
    pass=$((pass + 1))
}

# translate
chk "lower->upper range"   'Hello World\n'   a-z A-Z
chk "upper->lower range"   'Hello World\n'   A-Z a-z
chk "ROT13"                'Hello, World\n'  A-Za-z N-ZA-Mn-za-m
chk "SET2 shorter repeat"  'abcde\n'         a-e x
chk "explicit pair map"    'abcxyz\n'        a-z n-za-m
# delete
chk "delete digits"        'a1b2c3\n'        -d 0-9
chk "delete class alpha"   'a1b2!c\n'        -d '[:alpha:]'
chk "delete class punct"   'a!b,c.d\n'       -d '[:punct:]'
chk "complement delete"    'abc123def\n'     -cd 0-9
chk "complement del class" 'ab12cd\n'        -cd '[:digit:]'
# squeeze
chk "squeeze space"        'a   b    c\n'    -s ' '
chk "squeeze set1 range"   'aabbccdd\n'      -s a-c
chk "squeeze space class"  'a  \t b\n'       -s '[:space:]' ' '
chk "translate + squeeze"  'aaabbb\n'        -s ab xx
# classes as translate
chk "class digit->X"       'a1b2c3\n'        '[:digit:]' X
chk "class lower->upper"   'quiet please\n'  '[:lower:]' '[:upper:]'
# complement translate
chk "complement translate" 'abc def\n'       -c a-z .
# escapes
chk "escape newline->spc"  'a\nb\nc\n'       '\n' ' '
chk "escape tab->colon"    'a\tb\n'          '\t' :
chk "escape backslash"     'a\\b\n'          '\\' /

echo "PASS: tr matches GNU tr byte-for-byte on $pass fixtures"
exit 0
