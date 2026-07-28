#!/usr/bin/env bash
# scripts/test_diff_host.sh — FAST, QEMU-free host gate for the native
# `diff` tool (user/diff.ad): proper LCS line alignment + unified (-u)
# and normal output, cross-checked byte-for-byte against GNU `diff`.
#
# It compiles user/diff.ad for the x86_64-linux Adder target (so the
# SAME source that ships on-device runs as a host process — the runtime
# maps sys_open/read/write/close to real syscalls), then for several
# fixture pairs it compares our output against GNU diff's, ignoring only
# the a/b path-label header lines (the first two lines of unified
# output). The fixtures include a mid-file insertion — a case a naive
# line-by-line compare mis-aligns but a correct LCS handles — plus a
# two-hunk case with a change, a deletion and an append, so the @@ hunk
# headers, the 3 lines of context, and the +/-/space bodies must all
# match GNU exactly. Exit status is asserted too (0 identical, 1 differ).
#
# Also confirms the native on-device binary still compiles clean.
# Built with the frozen Python seed compiler.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/diff_host"
FX="$OUT/diff_fx"
mkdir -p "$OUT" "$FX"
fail=0

command -v diff >/dev/null 2>&1 || { echo "[diff-host] SKIP: no system diff"; exit 0; }

echo "[diff-host] compiling user/diff.ad for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/diff.ad "$BIN" 2>"$OUT/diff_compile.log"; then
    echo "[diff-host] FAIL: host build did not compile"; cat "$OUT/diff_compile.log"; exit 1
fi
echo "[diff-host] PASS host build compiled -> $BIN"

# Native on-device binary must still compile clean.
if python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/diff.ad -o "$OUT/diff_native.elf" 2>"$OUT/diff_native.log"; then
    echo "[diff-host] PASS native diff compiles (x86_64-adder-user)"
else
    echo "[diff-host] FAIL native diff did not compile"; cat "$OUT/diff_native.log"; fail=1
fi

# ---- fixtures ----
printf 'alpha\nbeta\ngamma\ndelta\nepsilon\n'                 > "$FX/a"
printf 'alpha\nbeta\nINSERTED\ngamma\ndelta\nepsilon\n'       > "$FX/b"   # mid-file insert
seq 1 20                                                       > "$FX/c"
{ echo HEAD; seq 2 5; echo CHANGED6; seq 7 14; seq 16 20; echo TAIL; } > "$FX/d"  # 2 hunks: change+del+append
printf 'one\ntwo\nthree\n'                                    > "$FX/e"   # identical pair source
cp "$FX/e" "$FX/f"

# strip the two path-label header lines from unified output so only the
# hunk headers + bodies are compared (task allows differing a/b labels).
strip_uhdr() { tail -n +3; }

cross() {
    # $1 = mode ("" | "-u"), $2 = fileL, $3 = fileR, $4 = expected exit
    local mode="$1" L="$2" R="$3" want="$4" label="$5"
    local g o grc orc
    if [ "$mode" = "-u" ]; then
        g=$(diff -u "$FX/$L" "$FX/$R" | strip_uhdr); grc=${PIPESTATUS[0]}
        o=$("$BIN" -u "$FX/$L" "$FX/$R" | strip_uhdr); orc=${PIPESTATUS[0]}
    else
        g=$(diff "$FX/$L" "$FX/$R"); grc=$?
        o=$("$BIN" "$FX/$L" "$FX/$R"); orc=$?
    fi
    if [ "$g" != "$o" ]; then
        echo "[diff-host] FAIL $label: output differs from GNU diff"
        echo "--- GNU ---"; printf '%s\n' "$g"
        echo "--- ours ---"; printf '%s\n' "$o"
        fail=1; return
    fi
    if [ "$orc" != "$want" ]; then
        echo "[diff-host] FAIL $label: exit=$orc want=$want (GNU=$grc)"; fail=1; return
    fi
    echo "[diff-host] PASS $label (matches GNU, exit=$orc)"
}

# unified mode
cross "-u" a b 1 "unified mid-file-insert"
cross "-u" b a 1 "unified mid-file-delete"
cross "-u" c d 1 "unified two-hunk change+del+append"
cross "-u" d c 1 "unified two-hunk reverse"
cross "-u" e f 0 "unified identical"
# normal mode
cross ""   a b 1 "normal mid-file-insert"
cross ""   c d 1 "normal two-hunk change+del+append"
cross ""   e f 0 "normal identical"

# Explicit: identical input produces NO output on stdout.
if [ -n "$("$BIN" -u "$FX/e" "$FX/f")" ]; then
    echo "[diff-host] FAIL identical files produced output"; fail=1
else
    echo "[diff-host] PASS identical files -> empty output"
fi

if [ "$fail" = 0 ]; then
    echo "[diff-host] ALL PASS"; exit 0
fi
echo "[diff-host] FAILURES present"; exit 1
