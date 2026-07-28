#!/usr/bin/env bash
# scripts/test_hambrowse_flexwrap_host.sh — FAST, QEMU-free gate for the round-6
# architectural web-standards rung in the native browser engine
# (lib/htmlengine.ad):
#
#   CSS `flex-wrap:wrap`. A `display:flex` row whose items overflow the
#   container WRAPS onto additional flex lines instead of being crammed into one
#   overflowing equal-column row. Placement is ONLINE: each item is measured at
#   its own open — its resolved CSS `width` (cards) or its natural content width
#   (nav pills) — and starts a new line below the tallest item of the previous
#   line when it no longer fits. Modern responsive card grids + wrapping navbars.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_flexwrap.html"
mkdir -p "$OUT"

echo "[hb-flexwrap] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexwrap] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexwrap] PASS host harness compiled -> $BIN"

echo "[hb-flexwrap] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexwrap] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexwrap] PASS native hambrowse still compiles"

fail=0
D="$OUT/flexwrap.txt"
"$BIN" "$FIX" 800 >"$D" 2>&1 || { echo "[hb-flexwrap] FAIL: render exited non-zero"; cat "$D"; exit 1; }

seg_row() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }
seg_x()   { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $3}' | head -1; }

# ---- (1) cards lay out side-by-side honouring their CSS width:160 ------------
# advance = 160 width + 16 gap = 176 between successive card left edges.
axc=$(seg_x "Alpha card body text")
bxc=$(seg_x "Beta card body text")
gxc=$(seg_x "Gamma card body text")
ayr=$(seg_row "Alpha card body text")
byr=$(seg_row "Beta card body text")
echo "[hb-flexwrap] row1 cards: Alpha(row=$ayr x=$axc) Beta(row=$byr x=$bxc) Gamma(x=$gxc)"
# BORDER-BOX ADVANCE (re-pinned 2026-07-27): 178, not 176. A flex item's main
# size is its BORDER box, so `.card{width:160px;border:1px solid}` steps
# 160 + 2*1 border + 16 gap = 178. `chromium --headless` puts the cards at
# x = 8 / 186 / 364 / 542 (w=162 each) — a 178px step. The old 176 was the
# engine's pre-fix advance, which ignored the item's padding/border on the wrap
# path and therefore drew each card 2px into its neighbour.
if [ -n "$axc" ] && [ "$ayr" = "$byr" ] && \
   [ "$((bxc - axc))" -eq 178 ] && [ "$((gxc - bxc))" -eq 178 ]; then
    echo "[hb-flexwrap] PASS three cards share a line at their CSS border-box width (advance 160w+2border+16gap)"
else
    echo "[hb-flexwrap] FAIL cards not laid out at CSS width (advance $((bxc-axc)))"; fail=1
fi

# ---- (2) the overflowing card WRAPs to a new flex line -----------------------
# At width 800 (body content ~784px) four 160px cards + three 16px gaps = 688px
# fit on line 1 (Alpha..Delta); the FIFTH (Epsilon) overflows and wraps to line
# 2 with its x reset to the container left. This matches Chromium/Firefox exactly
# (cross-checked headless): four-up on line 1, Epsilon alone on line 2.
exr=$(seg_row "Epsilon card five"); exx=$(seg_x "Epsilon card five")
echo "[hb-flexwrap] wrap: Alpha row=$ayr  Epsilon row=$exr x=$exx"
if [ -n "$exr" ] && [ "$exr" -gt "$ayr" ] && [ "$exx" -eq "$axc" ]; then
    echo "[hb-flexwrap] PASS overflowing card wraps to a new line (Epsilon row $exr, x reset)"
else
    echo "[hb-flexwrap] FAIL card did not wrap (Epsilon row=$exr x=$exx vs Alpha row=$ayr x=$axc)"; fail=1
fi

# ---- (3) content-sized nav PILLS wrap responsively at a narrow width ---------
DN="$OUT/flexwrap_narrow.txt"
"$BIN" "$FIX" 420 >"$DN" 2>&1 || { echo "[hb-flexwrap] FAIL: narrow render nonzero"; exit 1; }
prow() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$DN" | awk '{print $2}' | head -1; }
d_row=$(prow "Dashboard"); h_row=$(prow "Help")
echo "[hb-flexwrap] narrow(420) pills: Dashboard row=$d_row  Help row=$h_row"
if [ -n "$d_row" ] && [ -n "$h_row" ] && [ "$h_row" -gt "$d_row" ]; then
    echo "[hb-flexwrap] PASS content-sized nav pills wrap onto a second line when narrow"
else
    echo "[hb-flexwrap] FAIL nav pills did not wrap at narrow width (Dashboard=$d_row Help=$h_row)"; fail=1
fi

# ---- control: at a wide width the same pills fit on ONE line -----------------
d_w=$(seg_row "Dashboard"); h_w=$(seg_row "Help")
echo "[hb-flexwrap] wide(800) pills: Dashboard row=$d_w  Help row=$h_w"
if [ -n "$d_w" ] && [ "$d_w" = "$h_w" ]; then
    echo "[hb-flexwrap] PASS at a wide width the pills all fit on one line (no needless wrap)"
else
    echo "[hb-flexwrap] FAIL pills wrapped even when they fit (Dashboard=$d_w Help=$h_w)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-flexwrap] RESULT: FAIL"; exit 1
fi
echo "[hb-flexwrap] RESULT: PASS"
