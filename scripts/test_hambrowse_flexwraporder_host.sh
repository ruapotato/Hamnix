#!/usr/bin/env bash
# scripts/test_hambrowse_flexwraporder_host.sh — FAST, QEMU-free gate for the
# DEFERRED WRAP-RELOCATE in the native browser engine (lib/web/layout/box.ad +
# lib/web/dom/forms.ad). A `display:flex; flex-wrap:wrap` container whose children
# carry a real CSS `order` and/or a `width:100%` child can no longer be streamed
# left-to-right in DOM order; the engine plans each item's visual line + per-line
# justify x up front, emits each on its own provisional band, then shifts them to
# their real lines at container close. Three features combine (Google footer):
#
#   (1) `order` ACROSS wrap lines — the promo (DOM index 1, order:0) paints ABOVE
#       its earlier siblings (a LATER-DOM item lifted to the top line).
#   (2) `width:100%` on the wrap path — the promo takes a FULL line of its own.
#   (3) per-wrap-line `justify-content:space-between` — the two remaining groups
#       spread to opposite edges of the SAME line.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_flexwraporder.html"
mkdir -p "$OUT"

echo "[hb-flexwraporder] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexwraporder] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexwraporder] PASS host harness compiled -> $BIN"

echo "[hb-flexwraporder] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexwraporder] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexwraporder] PASS native hambrowse still compiles"

fail=0
D="$OUT/flexwraporder.txt"
"$BIN" "$FIX" 900 >"$D" 2>&1 || { echo "[hb-flexwraporder] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# SEG <line> <x> ... |text|
seg_line() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1" "$D" | awk '{print $2}' | head -1; }
seg_x()    { grep -E "SEG [0-9]+ [0-9]+ .*\|$1" "$D" | awk '{print $3}' | head -1; }

pl=$(seg_line BuildCreateDoMore); px=$(seg_x BuildCreateDoMore)
al=$(seg_line Advertising);       ax=$(seg_x Advertising)
cl=$(seg_line Privacy);           cx=$(seg_x Privacy)
echo "[hb-flexwraporder] promo(line/x)=$pl/$px  grpA(line/x)=$al/$ax  grpC(line/x)=$cl/$cx"

if [ -z "$pl" ] || [ -z "$al" ] || [ -z "$cl" ]; then
    echo "[hb-flexwraporder] FAIL: a group did not render"; exit 1
fi

# (1) order across wrap lines + (2) width:100% own line: promo paints ABOVE both
if [ "$pl" -lt "$al" ] && [ "$pl" -lt "$cl" ]; then
    echo "[hb-flexwraporder] PASS promo (order:0, DOM index 1) lifted ABOVE its earlier siblings"
else
    echo "[hb-flexwraporder] FAIL promo not on the top line (promo=$pl grpA=$al grpC=$cl)"; fail=1
fi

# (2) width:100% full line: promo sits at the left edge (x small)
if [ "$px" -lt 60 ]; then
    echo "[hb-flexwraporder] PASS width:100% promo spans its own full line (x=$px)"
else
    echo "[hb-flexwraporder] FAIL width:100% promo not full-width (x=$px)"; fail=1
fi

# (3) per-wrap-line space-between: the two groups share ONE line, spread apart
if [ "$al" -eq "$cl" ] && [ "$ax" -lt 60 ] && [ "$cx" -gt 400 ]; then
    echo "[hb-flexwraporder] PASS space-between: grpA flush-left, grpC flush-right on the SAME line"
else
    echo "[hb-flexwraporder] FAIL groups did not share a space-between line (grpA line/x=$al/$ax grpC line/x=$cl/$cx)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-flexwraporder] RESULT: FAIL"; exit 1
fi
echo "[hb-flexwraporder] RESULT: PASS"
