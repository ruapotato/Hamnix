#!/usr/bin/env bash
# scripts/test_hambrowse_inlineblock_host.sh — FAST, QEMU-free gate for the
# round-6 architectural web-standards rung in the native browser engine
# (lib/htmlengine.ad):
#
#   TRUE `display:inline-block` INLINE FLOW. inline-block chips / badges /
#   buttons / nav-pills flow INLINE on a text line (advancing the pen) and WRAP
#   to the next line when they overflow — they do NOT each claim their own
#   full-width block row (the old behaviour). Each chip is a fixed-width box
#   (inner text + horizontal padding) that paints a NARROW background FILL over
#   exactly its box and insets its text by the left padding. THE biggest
#   remaining layout gap for modern pages (button rows, tag/chip clouds, nav
#   pills, inline cards).
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_inlineblock.html"
mkdir -p "$OUT"

echo "[hb-inlb] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-inlb] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-inlb] PASS host harness compiled -> $BIN"

echo "[hb-inlb] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-inlb] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-inlb] PASS native hambrowse still compiles"

fail=0
D="$OUT/inlineblock.txt"
"$BIN" "$FIX" 800 >"$D" 2>&1 || { echo "[hb-inlb] FAIL: render exited non-zero"; cat "$D"; exit 1; }

seg_row() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }
seg_x()   { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $3}' | head -1; }

# ---- (1) chips flow INLINE (same row, increasing x) --------------------------
ar=$(seg_row "alpha"); ax=$(seg_x "alpha")
br=$(seg_row "beta");  bx=$(seg_x "beta")
gr=$(seg_row "gamma"); gx=$(seg_x "gamma")
echo "[hb-inlb] tag chips: alpha(row=$ar x=$ax) beta(row=$br x=$bx) gamma(row=$gr x=$gx)"
if [ -n "$ar" ] && [ "$ar" = "$br" ] && [ "$br" = "$gr" ] && \
   [ "$bx" -gt "$ax" ] && [ "$gx" -gt "$bx" ]; then
    echo "[hb-inlb] PASS inline-block chips flow inline on one line (not stacked rows)"
else
    echo "[hb-inlb] FAIL chips did not flow inline (rows a=$ar b=$br g=$gr)"; fail=1
fi

# ---- (2) chips WRAP to a new line when the row overflows ----------------------
# Prose now spans the full viewport (Chrome parity), so the chip cloud is long
# enough (a..omega) to overflow the ~784px row and wrap: a later chip (omicron)
# lands on a row below alpha's with its x reset to the left margin.
ar2=$(seg_row "alpha"); or=$(seg_row "omicron"); ox=$(seg_x "omicron")
echo "[hb-inlb] wrap: alpha(row=$ar2) omicron(row=$or x=$ox)"
if [ -n "$ar2" ] && [ -n "$or" ] && [ "$or" -gt "$ar2" ] && [ "$ox" -lt 200 ]; then
    echo "[hb-inlb] PASS overflowing chips wrap to the next line (omicron row $or, x reset)"
else
    echo "[hb-inlb] FAIL chips did not wrap (alpha=$ar2 omicron=$or x=$ox)"; fail=1
fi

# ---- (3) each chip paints a NARROW box FILL (not a full-width block row) ------
# A full-width blockified span would be `FILL r r+1 100 700`; an inline chip is a
# short box. Assert a green (#22aa66) fill on row 0 whose width is < 120px.
narrow=0
while read -r t b lx rx col; do
    if [ "$col" = "#22aa66" ] && [ "$t" = "0" ] && [ "$((rx - lx))" -lt 120 ] && [ "$((rx - lx))" -gt 8 ]; then
        narrow=1
    fi
done < <(grep -E '^FILL ' "$D" | awk '{print $2, $3, $4, $5, $6}')
if [ "$narrow" -eq 1 ]; then
    echo "[hb-inlb] PASS chips paint narrow inline box fills (not full-width block rows)"
else
    echo "[hb-inlb] FAIL no narrow chip FILL found (chips still blockified?)"; grep '#22aa66' "$D" | grep FILL; fail=1
fi

# ---- (4) second chip row (buttons) flows inline too --------------------------
hr=$(seg_row "Home"); hx=$(seg_x "Home")
pr=$(seg_row "Profile"); px=$(seg_x "Profile")
echo "[hb-inlb] buttons: Home(row=$hr x=$hx) Profile(row=$pr x=$px)"
if [ -n "$hr" ] && [ "$hr" = "$pr" ] && [ "$px" -gt "$hx" ]; then
    echo "[hb-inlb] PASS inline-block buttons flow inline (Home -> Profile same row)"
else
    echo "[hb-inlb] FAIL buttons did not flow inline (Home=$hr Profile=$pr)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-inlb] RESULT: FAIL"; exit 1
fi
echo "[hb-inlb] RESULT: PASS"
