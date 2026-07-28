#!/usr/bin/env bash
# scripts/test_comm_gnu_crosscheck.sh — FAST, QEMU-free host gate for the
# native `comm` tool (user/comm.ad): compares two SORTED files line-by-line
# and emits the three-column report, cross-checked byte-for-byte against GNU
# `comm`.
#
# It compiles user/comm.ad for the x86_64-linux Adder target (so the SAME
# source that ships on-device runs as a host process — the runtime maps
# sys_open/read/write/close to real syscalls, and the 1-arg sys_open thunk
# lets the host open real file operands), then for several fixtures compares
# our stdout against GNU comm's with the same flags. Covers all three
# columns, the composable -1/-2/-3 suppressors (-12, -23, -3) and a stdin
# operand ("-"). Asserts byte-identical stdout. Also confirms the native
# on-device binary still compiles clean. Built with the frozen Python seed.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/comm_host"
FX="$OUT/comm_fx"
mkdir -p "$OUT" "$FX"
fail=0

command -v comm >/dev/null 2>&1 || { echo "[comm-host] SKIP: no system comm"; exit 0; }

echo "[comm-host] compiling user/comm.ad for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/comm.ad "$BIN" 2>"$OUT/comm_compile.log"; then
    echo "[comm-host] FAIL: host build did not compile"; cat "$OUT/comm_compile.log"; exit 1
fi
echo "[comm-host] PASS host build compiled -> $BIN"

# Native on-device binary must still compile clean.
if python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/comm.ad -o "$OUT/comm_native.elf" 2>"$OUT/comm_native.log"; then
    echo "[comm-host] PASS native comm compiles (x86_64-adder-user)"
else
    echo "[comm-host] FAIL native comm did not compile"; cat "$OUT/comm_native.log"; fail=1
fi

# ---- fixtures (must be SORTED — comm does not sort) ----
printf 'apple\nbanana\ncommon\ndelta\n'                 > "$FX/f1"
printf 'banana\ncherry\ncommon\nzeta\n'                 > "$FX/f2"

# cross <label> <flags...>  — compares ./comm vs GNU comm on f1 f2.
cross() {
    local label="$1"; shift
    local g o
    g=$(LC_ALL=C comm "$@" "$FX/f1" "$FX/f2")
    o=$("$BIN" "$@" "$FX/f1" "$FX/f2")
    if [ "$g" != "$o" ]; then
        echo "[comm-host] FAIL $label: output differs from GNU comm"
        echo "--- GNU ---"; printf '%s\n' "$g" | cat -A
        echo "--- ours ---"; printf '%s\n' "$o" | cat -A
        fail=1; return
    fi
    echo "[comm-host] PASS $label (matches GNU)"
}

cross "all three columns"
cross "-12 common only"       -12
cross "-23 file1 only"        -23
cross "-3 unique only"        -3
cross "-1 suppress col1"      -1
cross "-2 suppress col2"      -2

# stdin operand: FILE2 = "-"
g=$(LC_ALL=C comm "$FX/f1" - < "$FX/f2")
o=$("$BIN" "$FX/f1" - < "$FX/f2")
if [ "$g" != "$o" ]; then
    echo "[comm-host] FAIL stdin operand: differs from GNU comm"
    echo "--- GNU ---"; printf '%s\n' "$g" | cat -A
    echo "--- ours ---"; printf '%s\n' "$o" | cat -A
    fail=1
else
    echo "[comm-host] PASS stdin operand (matches GNU)"
fi

if [ "$fail" = 0 ]; then
    echo "[comm-host] ALL PASS"; exit 0
fi
echo "[comm-host] FAILURES present"; exit 1
