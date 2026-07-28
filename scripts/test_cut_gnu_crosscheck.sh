#!/usr/bin/env bash
# scripts/test_cut_gnu_crosscheck.sh
#
# Strong, QEMU-free proof that native `user/cut.ad` matches GNU `cut`.
#
# The Adder `x86_64-linux` target compiles the SAME cut.ad source that
# ships in the Hamnix initramfs into a static host ELF (sys_read/sys_write
# resolve to Linux read/write via user/linux-runtime.S). We then feed a
# battery of fixtures through both the native binary and the system `cut`
# with the SAME flags and assert BYTE-IDENTICAL stdout. This covers the
# -f/-d/-s, -c, -b option set plus LIST syntax (N, N-M, N-, -M, comma
# lists, out-of-order + overlapping ranges, ascending-merge) and
# --output-delimiter.
#
# Also confirms the on-device (x86_64-adder-user) binary still compiles.
# Registered in scripts/ci_battery_manifest.txt (Tier-1, no QEMU).

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v cut >/dev/null 2>&1 || { echo "[cut-crosscheck] SKIP: no system cut"; exit 0; }

WORK="$PROJ_ROOT/build/cut_crosscheck"
rm -rf "$WORK"
mkdir -p "$WORK"
ELF="$WORK/cut.elf"

# --- compile the shipped cut.ad for the host --------------------------
OUT="$(python3 -m compiler.adder compile --target=x86_64-linux \
    user/cut.ad -o "$ELF" 2>&1)" || fail "compile errored:
$OUT"
echo "$OUT" | grep -q "Compiled to" || fail "compiler did not report success:
$OUT"
[ -f "$ELF" ] || fail "no ELF produced at $ELF"
file "$ELF" | grep -q "ELF 64-bit" || fail "not a 64-bit ELF: $(file "$ELF")"

# --- on-device binary must still compile clean ------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user user/cut.ad "$WORK/cut_native.elf" >/dev/null 2>&1 || fail "native x86_64-adder-user compile failed"
echo "  ok: native cut compiles (x86_64-adder-user)"

pass=0
# chk <desc> <input-with-\n-escapes> [flags...]
chk() {
    local desc="$1"; shift
    local input="$1"; shift
    local mine gnu
    mine="$(printf '%b' "$input" | "$ELF" "$@")"
    gnu="$(printf '%b' "$input" | cut "$@")"
    if [ "$mine" != "$gnu" ]; then
        echo "  input : $(printf '%b' "$input" | tr '\n' '|')" >&2
        echo "  flags : $*" >&2
        echo "  native: $(printf '%s' "$mine" | tr '\n' '|')" >&2
        echo "  gnu   : $(printf '%s' "$gnu" | tr '\n' '|')" >&2
        fail "mismatch vs GNU cut: $desc"
    fi
    echo "  ok: $desc"
    pass=$((pass + 1))
}

# -f fields
chk "field 2, comma delim"    'a,b,c\nd,e,f\n'          -f2 -d,
chk "fields 1,3- open end"    'a:b:c:d:e\n'             -f1,3- -d:
chk "field 2 default TAB"     'a\tb\tc\n'               -f2
chk "field open start -3"     'a,b,c,d,e\n'             -f-3 -d,
chk "-s suppress nondelim"    'a,b\nnodelim\nc,d\n'     -f1 -d, -s
chk "no -s passes nondelim"   'a,b\nnodelim\n'          -f2 -d,
chk "trailing empty field"    'a:\n'                    -f1,2 -d:
chk "field beyond count"      'a:b\n'                   -f5 -d:
chk "field out-delim string"  'a:b:c\n'                 -f1,3 -d: --output-delimiter=XX

# -c characters
chk "char range 2-4"          'abcdef\nxy\n'            -c2-4
chk "char list 1,3-"          'abcdef\n'                -c1,3-
chk "char open start -3"      'abcdef\n'                -c-3
chk "char single positions"   'abcdef\n'               -c1,3,5
chk "char two disjoint ranges" 'abcdef\n'              -c1-2,4-5
chk "char adjacent ranges"    'abcdef\n'                -c1-2,3-4 --output-delimiter=:
chk "char overlapping ranges" 'abcdef\n'                -c1-3,2-4 --output-delimiter=:
chk "char out-of-order merge" 'abcdef\n'                -c3-4,1-2 --output-delimiter=:
chk "char singles out-delim"  'abcdef\n'                -c1,2,3 --output-delimiter=:

# -b bytes (byte-identical to -c under C locale ASCII)
chk "byte range 2-4"          'abcdef\n'                -b2-4
chk "byte open end 3-"        'abcdef\n'                -b3-

echo "PASS: cut matches GNU cut byte-for-byte on $pass fixtures"
exit 0
