#!/usr/bin/env bash
# scripts/test_join_gnu_crosscheck.sh — FAST, QEMU-free host gate for the
# native `join` tool (user/join.ad): relational join of two SORTED files on
# a common key field, cross-checked byte-for-byte against GNU `join`.
#
# It compiles user/join.ad for the x86_64-linux Adder target (so the SAME
# source that ships on-device runs as a host process — the runtime maps
# sys_open/read/write/close to real syscalls, and the 1-arg sys_open thunk
# lets the host open real file operands), then for a battery of fixtures
# compares our stdout against GNU join's with the same flags. Covers plain
# join, per-file join fields (-1/-2/-j), -t separator, -a left/right/full
# outer, -o output format with -e empty-field replacement, -i ignore-case,
# duplicate-key cartesian product, and a "-" stdin operand. Asserts
# byte-identical stdout. Also confirms the native on-device binary still
# compiles clean. Built with the frozen Python seed.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/join_host"
FX="$OUT/join_fx"
mkdir -p "$OUT" "$FX"
fail=0

command -v join >/dev/null 2>&1 || { echo "[join-host] SKIP: no system join"; exit 0; }

echo "[join-host] compiling user/join.ad for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/join.ad "$BIN" 2>"$OUT/join_compile.log"; then
    echo "[join-host] FAIL: host build did not compile"; cat "$OUT/join_compile.log"; exit 1
fi
echo "[join-host] PASS host build compiled -> $BIN"

# Native on-device binary must still compile clean.
if python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/join.ad -o "$OUT/join_native.elf" 2>"$OUT/join_native.log"; then
    echo "[join-host] PASS native join compiles (x86_64-adder-user)"
else
    echo "[join-host] FAIL native join did not compile"; cat "$OUT/join_native.log"; fail=1
fi

# ---- fixtures (must be SORTED on the join field — join does not sort) ----
printf '1 alice\n2 bob\n3 carol\n5 eve\n'   > "$FX/names"    # id -> name
printf '1 90\n2 75\n3 88\n4 60\n'           > "$FX/scores"   # id -> score
printf 'x 1\ny 2\nz 3\n'                     > "$FX/a2"       # key in field 2
printf '1 90\n2 75\n3 88\n'                 > "$FX/b1"
printf '1,alice\n2,bob\n3,carol\n'           > "$FX/cn"       # comma-separated
printf '1,90\n2,75\n4,60\n'                 > "$FX/cs"
printf 'Apple 1\nBanana 2\n'                 > "$FX/ci1"      # mixed case keys
printf 'apple x\nbanana y\n'                 > "$FX/ci2"
printf '1 a\n1 b\n2 c\n'                     > "$FX/dup1"     # duplicate keys
printf '1 x\n1 y\n2 z\n'                     > "$FX/dup2"

# cross <label> <join-args...>  — the last two args are the file operands.
cross() {
    local label="$1"; shift
    local g o
    g=$(LC_ALL=C join "$@" 2>&1)
    o=$("$BIN" "$@" 2>&1)
    if [ "$g" != "$o" ]; then
        echo "[join-host] FAIL $label: output differs from GNU join"
        echo "--- GNU ---"; printf '%s\n' "$g" | cat -A
        echo "--- ours ---"; printf '%s\n' "$o" | cat -A
        fail=1; return
    fi
    echo "[join-host] PASS $label (matches GNU)"
}

cross "plain join"              "$FX/names" "$FX/scores"
cross "-1 2 -2 1"               -1 2 -2 1 "$FX/a2" "$FX/b1"
cross "-j 1 (both fields)"      -j 1 "$FX/names" "$FX/scores"
cross "-t, comma separator"     -t, "$FX/cn" "$FX/cs"
cross "-a 1 (left outer)"       -a 1 "$FX/names" "$FX/scores"
cross "-a 2 (right outer)"      -a 2 "$FX/names" "$FX/scores"
cross "-a 1 -a 2 (full outer)"  -a 1 -a 2 "$FX/names" "$FX/scores"
cross "-o 1.1,2.2 -e NULL"      -o 1.1,2.2 -e NULL "$FX/names" "$FX/scores"
cross "-o full outer -e NULL"   -a 1 -a 2 -o 1.1,1.2,2.2 -e NULL "$FX/names" "$FX/scores"
cross "-i ignore case"          -i "$FX/ci1" "$FX/ci2"
cross "duplicate-key cartesian" "$FX/dup1" "$FX/dup2"

# stdin operand: FILE2 = "-"
g=$(LC_ALL=C join "$FX/names" - < "$FX/scores" 2>&1)
o=$("$BIN" "$FX/names" - < "$FX/scores" 2>&1)
if [ "$g" != "$o" ]; then
    echo "[join-host] FAIL stdin operand: differs from GNU join"
    echo "--- GNU ---"; printf '%s\n' "$g" | cat -A
    echo "--- ours ---"; printf '%s\n' "$o" | cat -A
    fail=1
else
    echo "[join-host] PASS stdin operand (matches GNU)"
fi

# Show a concrete match: joining an id->name file with an id->score file.
echo "[join-host] concrete match (names JOIN scores on id):"
"$BIN" "$FX/names" "$FX/scores" | sed 's/^/    /'

if [ "$fail" = 0 ]; then
    echo "[join-host] ALL PASS"; exit 0
fi
echo "[join-host] FAILURES present"; exit 1
