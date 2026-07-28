#!/usr/bin/env bash
# scripts/test_paste_gnu_crosscheck.sh — FAST, QEMU-free host gate for the
# native `paste` tool (user/paste.ad): merges corresponding lines of files
# side-by-side, cross-checked byte-for-byte against GNU `paste`.
#
# It compiles user/paste.ad for the x86_64-linux Adder target (so the SAME
# source that ships on-device runs as a host process — the runtime maps
# sys_open/read/write/close to real syscalls, and the 1-arg sys_open thunk
# lets the host open real file operands), then for several fixtures compares
# our stdout against GNU paste's with the same flags. Covers 2- and 3-file
# column merge, -d LIST (single + cycled), -s serial mode, the backslash
# escape `-d'\n'` (newline delimiter), and a stdin operand ("-"). Asserts
# byte-identical stdout. Also confirms the native on-device binary still
# compiles clean. Built with the frozen Python seed compiler.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/paste_host"
FX="$OUT/paste_fx"
mkdir -p "$OUT" "$FX"
fail=0

command -v paste >/dev/null 2>&1 || { echo "[paste-host] SKIP: no system paste"; exit 0; }

echo "[paste-host] compiling user/paste.ad for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/paste.ad "$BIN" 2>"$OUT/paste_compile.log"; then
    echo "[paste-host] FAIL: host build did not compile"; cat "$OUT/paste_compile.log"; exit 1
fi
echo "[paste-host] PASS host build compiled -> $BIN"

# Native on-device binary must still compile clean.
if python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/paste.ad -o "$OUT/paste_native.elf" 2>"$OUT/paste_native.log"; then
    echo "[paste-host] PASS native paste compiles (x86_64-adder-user)"
else
    echo "[paste-host] FAIL native paste did not compile"; cat "$OUT/paste_native.log"; fail=1
fi

# ---- fixtures (uneven lengths exercise the short-file empty field) ----
printf 'a1\na2\na3\n' > "$FX/p1"
printf 'b1\nb2\n'     > "$FX/p2"     # shorter than p1
printf 'c1\nc2\nc3\n' > "$FX/p3"

# cross <label> <args...>  — args are eval'd so quoting like -d'\n' round-trips.
cross() {
    local label="$1"; shift
    local g o
    g=$(eval "paste $*" 2>/dev/null)
    o=$(eval "\"$BIN\" $*" 2>/dev/null)
    if [ "$g" != "$o" ]; then
        echo "[paste-host] FAIL $label: output differs from GNU paste"
        echo "--- GNU ---"; printf '%s\n' "$g" | cat -A
        echo "--- ours ---"; printf '%s\n' "$o" | cat -A
        fail=1; return
    fi
    echo "[paste-host] PASS $label (matches GNU)"
}

cross "2-file column merge"      "$FX/p1 $FX/p2"
cross "3-file column merge"      "$FX/p1 $FX/p2 $FX/p3"
cross "-d, single delimiter"     "-d, $FX/p1 $FX/p2"
cross "-d,: cycled delimiters"   "-d,: $FX/p1 $FX/p2 $FX/p3"
cross "-s serial"                "-s $FX/p1 $FX/p2"
cross "-s -d, serial+delim"      "-s -d, $FX/p1"
cross "-d newline escape"        "-d'\\n' $FX/p1"
cross "-s -d newline escape"     "-s -d'\\n' $FX/p1"

# stdin operand: FILE1 = "-"
g=$(printf 'x\ny\n' | paste - "$FX/p2")
o=$(printf 'x\ny\n' | "$BIN" - "$FX/p2")
if [ "$g" != "$o" ]; then
    echo "[paste-host] FAIL stdin operand: differs from GNU paste"
    echo "--- GNU ---"; printf '%s\n' "$g" | cat -A
    echo "--- ours ---"; printf '%s\n' "$o" | cat -A
    fail=1
else
    echo "[paste-host] PASS stdin operand (matches GNU)"
fi

if [ "$fail" = 0 ]; then
    echo "[paste-host] ALL PASS"; exit 0
fi
echo "[paste-host] FAILURES present"; exit 1
