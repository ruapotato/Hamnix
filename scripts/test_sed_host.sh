#!/usr/bin/env bash
# scripts/test_sed_host.sh — FAST, QEMU-free host gate for the native
# `sed` tool (user/sed.ad): the everyday stream-editor subset, cross-
# checked byte-for-byte against GNU `sed` with the SAME script.
#
# It compiles user/sed.ad for the x86_64-linux Adder target (so the SAME
# source that ships on-device runs as a host process — the runtime maps
# sys_open/read/write/close to real syscalls), then for each fixture it
# asserts our stdout AND exit status are identical to GNU sed's.
#
# Fixtures cover EXACTLY the implemented subset:
#   s/foo/bar/ , s/o/0/g , & whole-match backref, 2,4d range-delete,
#   -n '2,3p' , $d last-line delete, anchored s/^x/y/ , end anchor $,
#   `.` any, `*` star, [..]/[^..] char classes, p command, multi-cmd
#   (`;` and repeated -e), a FILE operand, and \-escaped delim/metachar.
# Features NOT implemented (hold/append/insert/branch, back-references,
# +/?/{n,m}) are deliberately NOT gated.
#
# Also confirms the native on-device binary still compiles clean.
# Built with the frozen Python seed compiler.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/sed_host"
FX="$OUT/sed_fx"
mkdir -p "$OUT" "$FX"
fail=0

command -v sed >/dev/null 2>&1 || { echo "[sed-host] SKIP: no system sed"; exit 0; }

echo "[sed-host] compiling user/sed.ad for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/sed.ad "$BIN" 2>"$OUT/sed_compile.log"; then
    echo "[sed-host] FAIL: host build did not compile"; cat "$OUT/sed_compile.log"; exit 1
fi
echo "[sed-host] PASS host build compiled -> $BIN"

# Native on-device binary must still compile clean.
if python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/sed.ad -o "$OUT/sed_native.elf" 2>"$OUT/sed_native.log"; then
    echo "[sed-host] PASS native sed compiles (x86_64-adder-user)"
else
    echo "[sed-host] FAIL native sed did not compile"; cat "$OUT/sed_native.log"; fail=1
fi

# ---- fixtures ----
printf 'foo bar\nfoobar\nno foo here\n'        > "$FX/foo"
printf 'oooo\nhello world\n'                   > "$FX/oo"
printf 'a\nb\nc\nd\ne\nf\n'                     > "$FX/abc"
printf 'xray\nyellow\naxe\n'                    > "$FX/xy"
printf 'cat\ncot\ncut\ndog\n'                   > "$FX/pets"
printf 'a1b2c3\nx9y8\n'                         > "$FX/mix"
printf 'end.\nmiddle end here\nthe end\n'       > "$FX/anchor"
printf 'a/b\n1.5\n'                             > "$FX/esc"

# cross STDIN: $1=label, $2=fixture, then the sed arg vector.
cross() {
    local label="$1"; local fx="$2"; shift 2
    local g o grc orc
    g=$(sed "$@" < "$FX/$fx"); grc=$?
    o=$("$BIN" "$@" < "$FX/$fx"); orc=$?
    if [ "$g" != "$o" ]; then
        echo "[sed-host] FAIL $label: stdout differs from GNU sed"
        echo "--- GNU ---"; printf '%s\n' "$g"
        echo "--- ours ---"; printf '%s\n' "$o"
        fail=1; return
    fi
    if [ "$grc" != "$orc" ]; then
        echo "[sed-host] FAIL $label: exit=$orc want=$grc"; fail=1; return
    fi
    echo "[sed-host] PASS $label (matches GNU, exit=$orc)"
}

# The seven required subset cases.
cross "s/foo/bar/"          foo    's/foo/bar/'
cross "s/o/0/g"             oo     's/o/0/g'
cross "& whole-match"       foo    's/foo/[&]/'
cross "2,4d range-delete"   abc    '2,4d'
cross "-n 2,3p"             abc    -n '2,3p'
cross '$d last-line delete' abc    '$d'
cross "anchored s/^x/y/"    xy     's/^x/y/'

# Extended subset.
cross "end anchor s/end\$/"  anchor 's/end$/E/'
cross "dot c.t"             pets   's/c.t/X/'
cross "star co*t"           pets   's/co*t/Z/'
cross "class [0-9] g"       mix    's/[0-9]/#/g'
cross "neg class [^0-9] g"  mix    's/[^0-9]/_/g'
cross "class range [a-c]"   mix    's/[a-c]/*/g'
cross "p prints extra"      pets   '2p'
cross "-n p only"           pets   -n '2p'
cross "multi ; commands"    pets   's/cat/CAT/;s/dog/DOG/'
cross "-e repeated"         pets   -e 's/cat/CAT/' -e 's/dog/DOG/'
cross "range to \$"         pets   -n '3,$p'
cross "escaped delim"       esc    's/a\/b/SLASH/'
cross "escaped dot"         esc    's/1\.5/NUM/'
cross "gp flags combined"   oo     -n 's/o/0/gp'

# FILE operand (no stdin) — must match GNU too, incl. exit status.
g=$(sed 's/cat/CAT/' "$FX/pets"); grc=$?
o=$("$BIN" 's/cat/CAT/' "$FX/pets"); orc=$?
if [ "$g" = "$o" ] && [ "$grc" = "$orc" ]; then
    echo "[sed-host] PASS file operand (matches GNU, exit=$orc)"
else
    echo "[sed-host] FAIL file operand: out or exit differs (GNU exit=$grc, ours=$orc)"; fail=1
fi

if [ "$fail" = 0 ]; then
    echo "[sed-host] ALL PASS"; exit 0
fi
echo "[sed-host] FAILURES present"; exit 1
