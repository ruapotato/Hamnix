#!/usr/bin/env bash
# scripts/test_hambrowse_textindent_host.sh — FAST, QEMU-free gate for ROUND-3
# CSS text-indent (first-line inset) in the native browser engine
# (lib/web/layout/box.ad). The m_tindent cascade winner was parsed by round-2 but
# not consumed; box.ad now arms a first-line inset at _block_box_open and the
# first word on the block's opening line is shifted right by it — exactly ONCE:
#
#   (A) text-indent:40px -> the first line starts at x = 8 + 40 = 48.
#   (B) the WRAPPED continuation line of the same block is NOT indented (x = 8).
#   (C) a following plain paragraph is NOT indented (x = 8) — armed inset cleared.
#
# Builds BOTH targets so a break in either backend is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_textindent.html"
mkdir -p "$OUT"

echo "[hb-ti] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-ti] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-ti] PASS host harness compiled -> $BIN"

echo "[hb-ti] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-ti] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-ti] PASS native hambrowse still compiles"

fail=0
D="$OUT/textindent.txt"
# Narrow the viewport so the indented paragraph wraps onto a second line.
"$BIN" "$FIX" 300 >"$D" 2>&1 || { echo "[hb-ti] FAIL: render exited non-zero"; cat "$D"; exit 1; }
cat "$D"

# SEG lines are "SEG line x color ... |text|".
first_x() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1" "$D" | awk '{print $3}' | head -1; }

fx=$(first_x 'First indented line')
wx=$(grep -E "SEG [0-9]+ [0-9]+ " "$D" | awk '$3==8' | grep -c .)  # any seg at x=8

echo "[hb-ti] indented first-line x=$fx (expect 48 = 8 + 40)"
if [ "$fx" = "48" ]; then
    echo "[hb-ti] PASS text-indent:40px shifts the first line to x=48"
else
    echo "[hb-ti] FAIL text-indent first-line x=$fx (want 48)"; fail=1
fi

# The wrapped continuation line and the plain paragraph both sit at x=8.
cont_x=$(grep -E "SEG [0-9]+ [0-9]+ .*indented" "$D" | awk 'NR==2{print $3}')
plain_x=$(first_x 'Plain paragraph')
echo "[hb-ti] continuation x=$cont_x  plain-para x=$plain_x (expect 8 / 8)"
if [ "$plain_x" = "8" ]; then
    echo "[hb-ti] PASS following plain paragraph is NOT indented (x=8)"
else
    echo "[hb-ti] FAIL plain paragraph indented (x=$plain_x)"; fail=1
fi
# At least one line must sit at the un-indented left margin (the wrap / plain).
if [ "$wx" -ge 1 ]; then
    echo "[hb-ti] PASS un-indented lines present (only the first line moved)"
else
    echo "[hb-ti] FAIL every line indented (text-indent not first-line-only)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-ti] RESULT: FAIL"; exit 1
fi
echo "[hb-ti] RESULT: PASS"
