#!/usr/bin/env bash
# scripts/test_hambrowse_inlbpad_host.sh — FAST, QEMU-free gate for the round-7
# modern-layout rung in the native browser engine (lib/htmlengine.ad):
#
#   inline-block VERTICAL PADDING. An inline-block chip/badge/button with top+
#   bottom padding grows into a real multi-row BOX (its background FILL spans the
#   padded height and its text line is centred within it) instead of being one
#   text-line tall. Following content clears the taller box. This makes badges /
#   pills / buttons read as real controls, not one-line spans.
#
# The fixture has padded badges (`padding:12px 10px` -> one 16px text line + 24px
# vertical padding) and flat control chips (no vertical padding). A padded chip is
# ONE text line tall with PIXEL-accurate top/bottom padding grown onto its FILL
# (bfill_padt/padb) — NOT quantised up to whole LINE_H rows, which tripled a
# padding:10px button into an over-tall empty pill (the label centring naturally
# between the symmetric padding). We assert the padded box FILL is 1 row tall
# carrying 24px of vertical padding, the flat FILL is 1 row with 0 padding, and the
# following flat line CLEARS the padded badges (no overlap).
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_inlbpad.html"
mkdir -p "$OUT"

echo "[hb-inlbpad] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-inlbpad] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-inlbpad] PASS host harness compiled -> $BIN"

echo "[hb-inlbpad] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-inlbpad] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-inlbpad] PASS native hambrowse still compiles"

fail=0
D="$OUT/inlbpad.txt"
"$BIN" "$FIX" 800 >"$D" 2>&1 || { echo "[hb-inlbpad] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# ---- (1) padded badge (#cc3355): 1-row FILL carrying 24px vertical padding ----
# FILL fields: top bot lx rx colour rad z padt padb
bh=0; bpad=0
while read -r t b lx rx col rad z padt padb; do
    if [ "$col" = "#cc3355" ]; then bh=$((b - t)); bpad=$((padt + padb)); fi
done < <(grep -E '^FILL ' "$D" | awk '{print $2, $3, $4, $5, $6, $7, $8, $9, $10}')
echo "[hb-inlbpad] padded badge FILL height = $bh row(s), vpad = ${bpad}px (expect 1 row, 24px)"
if [ "$bh" -eq 1 ] && [ "$bpad" -eq 24 ]; then
    echo "[hb-inlbpad] PASS vertical padding grows the badge box by pixel-accurate 24px"
else
    echo "[hb-inlbpad] FAIL badge box not 1 row + 24px pad (got ${bh} rows, ${bpad}px)"; grep '#cc3355' "$D" | grep FILL; fail=1
fi

# ---- (2) control chip with NO vertical padding stays 1 row, 0 pad (zero-cost) -
fh=0; fpad=1
while read -r t b lx rx col rad z padt padb; do
    if [ "$col" = "#22aa66" ]; then fh=$((b - t)); fpad=$((padt + padb)); fi
done < <(grep -E '^FILL ' "$D" | awk '{print $2, $3, $4, $5, $6, $7, $8, $9, $10}')
echo "[hb-inlbpad] flat chip FILL height = $fh row(s), vpad = ${fpad}px (expect 1 row, 0px)"
if [ "$fh" -eq 1 ] && [ "$fpad" -eq 0 ]; then
    echo "[hb-inlbpad] PASS a chip without vertical padding is unchanged (1 row, no pad)"
else
    echo "[hb-inlbpad] FAIL flat chip changed (got $fh rows, ${fpad}px)"; fail=1
fi

# ---- (3) the following flat line CLEARS the tall badges (no overlap) ---------
# padded badges occupy rows [0,3); the flat tags line must start at row >= 3.
seg_row() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }
badge_top=$(seg_row "Live")
flat_row=$(seg_row "alpha")
echo "[hb-inlbpad] badges start row=$badge_top ; flat tags line row=$flat_row (must be >= 3)"
if [ -n "$flat_row" ] && [ "$flat_row" -ge 3 ]; then
    echo "[hb-inlbpad] PASS content after tall badges clears the reserved box rows"
else
    echo "[hb-inlbpad] FAIL flat line overlaps the tall badges (row=$flat_row)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-inlbpad] RESULT: FAIL"; exit 1
fi
echo "[hb-inlbpad] RESULT: PASS"
