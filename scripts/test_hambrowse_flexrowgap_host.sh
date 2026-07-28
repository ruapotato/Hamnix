#!/usr/bin/env bash
# scripts/test_hambrowse_flexrowgap_host.sh — FAST, QEMU-free gate for the round-7
# modern-layout rung in the native browser engine (lib/htmlengine.ad):
#
#   CSS `row-gap` / the `gap: <row> <col>` shorthand for WRAPPED flex lines. When
#   a `display:flex; flex-wrap:wrap` container wraps items onto additional lines,
#   `row-gap` inserts vertical space between those lines (rounded to whole LINE_H
#   rows). Modern responsive card grids get real breathing room between rows
#   instead of packing the wrapped line flush against the one above.
#
# The fixture renders two identical wrapping card grids that differ ONLY in
# row-gap (tight = column-gap only; spaced = `gap:48px 16px`, i.e. 48px row-gap =
# 3 rows at LINE_H=16). The wrapped (2nd) line of the spaced grid must sit exactly
# 3 rows LOWER (relative to its own first line) than the tight grid's, isolating
# the row-gap contribution.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_flexrowgap.html"
mkdir -p "$OUT"

echo "[hb-rowgap] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-rowgap] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-rowgap] PASS host harness compiled -> $BIN"

echo "[hb-rowgap] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-rowgap] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-rowgap] PASS native hambrowse still compiles"

fail=0
D="$OUT/flexrowgap.txt"
"$BIN" "$FIX" 620 >"$D" 2>&1 || { echo "[hb-rowgap] FAIL: render exited non-zero"; cat "$D"; exit 1; }

seg_row() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }
seg_x()   { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $3}' | head -1; }

# first line + wrapped line of each grid
at=$(seg_row "Alpha");  gt=$(seg_row "Gamma");  dt=$(seg_row "Delta");  dtx=$(seg_x "Delta"); atx=$(seg_x "Alpha")
as=$(seg_row "Uno");    gs=$(seg_row "Tres");   ds=$(seg_row "Cuatro"); dsx=$(seg_x "Cuatro"); asx=$(seg_x "Uno")
echo "[hb-rowgap] tight : line1 Alpha=$at Gamma=$gt | wrapped Delta=$dt(x=$dtx) vs Alpha x=$atx"
echo "[hb-rowgap] spaced: line1 Uno=$as  Tres=$gs  | wrapped Cuatro=$ds(x=$dsx) vs Uno x=$asx"

# ---- (1) both grids actually WRAP (2nd line strictly below the 1st) ----------
if [ -n "$at" ] && [ -n "$dt" ] && [ "$at" = "$gt" ] && [ "$dt" -gt "$at" ] && \
   [ -n "$as" ] && [ -n "$ds" ] && [ "$as" = "$gs" ] && [ "$ds" -gt "$as" ]; then
    echo "[hb-rowgap] PASS both grids wrap onto a second flex line"
else
    echo "[hb-rowgap] FAIL a grid did not wrap (tight d=$dt a=$at / spaced d=$ds a=$as)"; fail=1
fi

# ---- (2) the wrapped card x still resets to the line start (no h-shift) -------
if [ "$dtx" = "$atx" ] && [ "$dsx" = "$asx" ]; then
    echo "[hb-rowgap] PASS wrapped cards reset to the line's left edge"
else
    echo "[hb-rowgap] FAIL wrapped card x not reset (tight $dtx/$atx spaced $dsx/$asx)"; fail=1
fi

# ---- (3) row-gap drops the SPACED wrapped line exactly 3 rows lower ----------
# tight offset = column-gap-only baseline; spaced offset = baseline + row-gap rows.
off_t=$((dt - at))
off_s=$((ds - as))
extra=$((off_s - off_t))
echo "[hb-rowgap] wrapped-line offset: tight=$off_t spaced=$off_s  row-gap contribution=$extra rows (expect 3)"
if [ "$extra" -eq 3 ]; then
    echo "[hb-rowgap] PASS row-gap:48px inserts exactly 3 rows between wrapped flex lines"
else
    echo "[hb-rowgap] FAIL row-gap did not add 3 rows (got $extra)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-rowgap] RESULT: FAIL"; exit 1
fi
echo "[hb-rowgap] RESULT: PASS"
