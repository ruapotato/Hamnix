#!/usr/bin/env bash
# scripts/test_awk_gnu_crosscheck.sh — FAST, QEMU-free host gate for the
# native `awk` interpreter (user/awk.ad): a lexer -> recursive-descent
# tree-walk interpreter over the program text, extern-free apart from the
# syscall thunks and lib/regex.ad. It compiles user/awk.ad for the
# x86_64-linux Adder target (so the SAME source that ships on-device runs
# as a host process; the 1-arg sys_open thunk opens real FILE operands),
# then cross-checks its stdout BYTE-FOR-BYTE against GNU awk on fixtures
# exercising exactly the implemented common subset:
#
#   fields/$N, NF, NR, FS (-F single-char + regex), OFS, print/printf,
#   patterns (/re/, relational, &&/||/!), BEGIN/END, arithmetic + string
#   concat, if/else/while/for, assoc arrays, length/substr/index/split/
#   toupper/tolower/int, and the -F / -v / -f flags.
#
# Also confirms the native on-device binary (x86_64-adder-user) compiles
# clean. Built with the frozen Python seed compiler.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/awk_host"
FX="$OUT/awk_fx"
mkdir -p "$OUT" "$FX"
fail=0

command -v awk >/dev/null 2>&1 || { echo "[awk-host] SKIP: no system awk"; exit 0; }

echo "[awk-host] compiling user/awk.ad for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/awk.ad "$BIN" 2>"$OUT/awk_compile.log"; then
    echo "[awk-host] FAIL: host build did not compile"; cat "$OUT/awk_compile.log"; exit 1
fi
echo "[awk-host] PASS host build compiled -> $BIN"

# Native on-device binary must still compile clean.
if python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/awk.ad -o "$OUT/awk_native.elf" 2>"$OUT/awk_native.log"; then
    echo "[awk-host] PASS native awk compiles (x86_64-adder-user)"
else
    echo "[awk-host] FAIL native awk did not compile"; cat "$OUT/awk_native.log"; fail=1
fi

# ---- fixtures ----
printf 'alpha 10 100\nbeta 5 20\ngamma 25 7\nfoobar 3 3\n' > "$FX/d1"
printf 'x,1,foo\ny,2,bar\nz,30,baz\n'                       > "$FX/d2"
printf 'a12b345c\n'                                         > "$FX/d3"

matches_shown=0

# cross <label> <file> -- <awk args...>
cross() {
    local label="$1"; local file="$2"; shift 2
    # remaining args: the awk program + any flags, passed verbatim
    local g o
    g=$(LC_ALL=C awk "$@" "$file" 2>/dev/null)
    o=$(LC_ALL=C timeout 20 "$BIN" "$@" "$file" 2>/dev/null)
    if [ "$g" != "$o" ]; then
        echo "[awk-host] FAIL $label: output differs from GNU awk"
        echo "--- GNU ---"; printf '%s\n' "$g" | cat -A
        echo "--- ours ---"; printf '%s\n' "$o" | cat -A
        fail=1; return
    fi
    echo "[awk-host] PASS $label (matches GNU)"
    if [ "$matches_shown" -lt 3 ]; then
        echo "         e.g. -> $(printf '%s' "$o" | head -1)"
        matches_shown=$((matches_shown+1))
    fi
}

# field selection
cross "print \$2"            "$FX/d1" '{print $2}'
cross "-F, print \$1"        "$FX/d2" -F, '{print $1}'
cross "print \$1,\$3 OFS"    "$FX/d1" '{print $1, $3}'
# patterns
cross "\$3>10 relational"    "$FX/d1" '$3>10 {print $1}'
cross "/foo/ regex"          "$FX/d1" '/foo/ {print}'
cross "NF>2 bare pattern"    "$FX/d1" 'NF>2'
cross "NR%2 modulo pattern"  "$FX/d1" 'NR%2==1'
cross "&& || !"              "$FX/d1" '$2>4 && $3<100 {print $1}'
# BEGIN/END + running sum
cross "BEGIN/END sum"        "$FX/d1" 'BEGIN{s=0} {s+=$1} END{print s}'
cross "END record count"     "$FX/d1" 'END{print NR}'
cross "NR prefix concat"     "$FX/d1" '{print NR": "$0}'
# printf
cross "printf d/x/f/c"       "$FX/d1" '{printf "%d %x %X %o %5.2f %c\n", $2,$2,$2,$2,$2,65}'
cross "printf width/flags"   "$FX/d1" '{printf "%-8s|%3d|%06.2f\n", $1,$2,$3/7}'
# string builtins
cross "substr/index/length"  "$FX/d1" '{print substr($1,2,3), index($1,"a"), length($1)}'
cross "toupper/tolower"      "$FX/d1" '{print toupper($1), tolower("HeLLo")}'
cross "split count"          "$FX/d1" '{n=split($0,a," "); print n, a[1], a[n]}'
cross "split empty=chars"    "$FX/d1" '{n=split($1,a,""); print n, a[1], a[n]}'
# control flow + arrays
cross "if/else"              "$FX/d1" '{ if ($2>8) print "big"; else print "small" }'
cross "while loop"           "$FX/d1" '{ i=1; while(i<=NF){printf "%s.",$i;i++}; print "" }'
cross "for reverse"          "$FX/d1" '{ for(i=NF;i>=1;i--) printf "%s ",$i; print "" }'
cross "assoc array"          "$FX/d1" '{a[$1]=$2} END{print a["beta"]}'
cross "array count for-in"   "$FX/d1" '{c[$2]++} END{n=0; for(k in c) n++; print n}'
# OFS / FS assignment
cross "BEGIN OFS assign"     "$FX/d1" 'BEGIN{OFS="-"} {print $1,$2}'
cross "BEGIN FS assign"      "$FX/d2" 'BEGIN{FS=","} {print $2}'
# regex FS
cross "FS regex multi-char"  "$FX/d3" -F'[0-9]+' '{print $2, $3}'
# division / default float print
cross "float division print" "$FX/d1" '{print $3/$2}'

# ---- flag: -v ----
g=$(LC_ALL=C awk -v k=100 '{print $2+k}' "$FX/d1")
o=$(LC_ALL=C "$BIN" -v k=100 '{print $2+k}' "$FX/d1")
if [ "$g" != "$o" ]; then
    echo "[awk-host] FAIL -v assignment differs"; fail=1
else
    echo "[awk-host] PASS -v assignment (matches GNU)"
fi

# ---- flag: -f progfile ----
printf '{print $1"="$2}\n' > "$FX/p.awk"
g=$(LC_ALL=C awk -f "$FX/p.awk" "$FX/d1")
o=$(LC_ALL=C "$BIN" -f "$FX/p.awk" "$FX/d1")
if [ "$g" != "$o" ]; then
    echo "[awk-host] FAIL -f progfile differs"; fail=1
else
    echo "[awk-host] PASS -f progfile (matches GNU)"
fi

# ---- stdin (no file operand) ----
g=$(printf 'p q\nr s\n' | LC_ALL=C awk '{print $2}')
o=$(printf 'p q\nr s\n' | LC_ALL=C "$BIN" '{print $2}')
if [ "$g" != "$o" ]; then
    echo "[awk-host] FAIL stdin differs"; fail=1
else
    echo "[awk-host] PASS stdin (matches GNU)"
fi

# ---- multiple file operands (NR spans files) ----
g=$(LC_ALL=C awk '{print NR, $0}' "$FX/d1" "$FX/d2")
o=$(LC_ALL=C "$BIN" '{print NR, $0}' "$FX/d1" "$FX/d2")
if [ "$g" != "$o" ]; then
    echo "[awk-host] FAIL multi-file differs"; fail=1
else
    echo "[awk-host] PASS multi-file operands (matches GNU)"
fi

if [ "$fail" = 0 ]; then
    echo "[awk-host] ALL PASS"; exit 0
fi
echo "[awk-host] FAILURES present"; exit 1
