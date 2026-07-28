#!/usr/bin/env bash
# scripts/test_hambrowse_flexalign_host.sh — FAST, QEMU-free gate for CSS
# `align-items` cross-axis alignment in the native browser engine
# (lib/htmlengine.ad):
#
#   A `display:flex` container aligns each item within its line's CROSS-AXIS
#   extent (the tallest item / the line height). `flex-start` (default) pins to
#   the top; `center` centres; `flex-end` drops to the bottom; `stretch` keeps
#   content at the top but grows the item's box BACKGROUND to the full line
#   height. Implemented as a deferred coordinate fixup over each item's already-
#   emitted segments/fills at container close — no second layout pass.
#
# The fixture renders four IDENTICAL two-column flex rows (a 4-row-tall item + a
# 1-row short item with a coloured background) that differ ONLY in align-items.
# We assert on the SHORT item's actual layout coordinates (its text row relative
# to the tall item's first row = its cross-axis offset; and, for stretch, its
# FILL height) — NOT on echo.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_flexalign.html"
mkdir -p "$OUT"

echo "[hb-align] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-align] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-align] PASS host harness compiled -> $BIN"

echo "[hb-align] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-align] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-align] PASS native hambrowse still compiles"

fail=0
D="$OUT/flexalign.txt"
"$BIN" "$FIX" 620 >"$D" 2>&1 || { echo "[hb-align] FAIL: render exited non-zero"; cat "$D"; exit 1; }

seg_row() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }
seg_x()   { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $3}' | head -1; }
# FILL <top> <bot> <lx> <rx> #rgb <rad> <z> <...> b-  -> emit (bot-top) for a
# given colour. The fill dump has grown trailing fields over time; a `b-` BORDER
# field (non-numeric, appended by the border track: "...#44dd55 0 0 0 0 b-") now
# terminates the record, so the old `( [0-9]+)*$` numeric-tail anchor no longer
# matched. Anchor on the colour + a field boundary (space or EOL) instead and
# ignore all trailing fields — the geometry we read ($3-$2 = bot-top) is intact.
fill_h()  { grep -E "^FILL [0-9]+ [0-9]+ .*#$1( |$)" "$D" | awk '{print $3-$2}' | head -1; }

# tall item first row + short item row, per container
sa=$(seg_row Sa1); ss=$(seg_row Sshort); ssx=$(seg_x Sshort); sax=$(seg_x Sa1)
ca=$(seg_row Ca1); cs=$(seg_row Cshort)
ea=$(seg_row Ea1); es=$(seg_row Eshort)
ta=$(seg_row Ta1); ts=$(seg_row Tshort)
th=$(fill_h 44dd55)   # stretched item's fill height (rows)

off_s=$(( ss - sa ))
off_c=$(( cs - ca ))
off_e=$(( es - ea ))
off_t=$(( ts - ta ))
echo "[hb-align] tall-first/short rows: start=$sa/$ss(off $off_s) center=$ca/$cs(off $off_c) end=$ea/$es(off $off_e) stretch=$ta/$ts(off $off_t)"
echo "[hb-align] stretch fill height=$th rows (tall item is 4 rows)"

# ---- (0) the rows actually columnise (short item is to the RIGHT of the tall) --
if [ -n "$ssx" ] && [ -n "$sax" ] && [ "$ssx" -gt "$sax" ]; then
    echo "[hb-align] PASS flex items columnise (short x=$ssx > tall x=$sax)"
else
    echo "[hb-align] FAIL flex did not columnise (short x=$ssx tall x=$sax)"; fail=1
fi

# ---- (1) flex-start: short item pinned to the line TOP (offset 0) --------------
if [ -n "$off_s" ] && [ "$off_s" -eq 0 ]; then
    echo "[hb-align] PASS flex-start keeps the short item at the line top"
else
    echo "[hb-align] FAIL flex-start offset expected 0, got $off_s"; fail=1
fi

# ---- (2) flex-end: short item dropped to the line BOTTOM (offset = 4-1 = 3) ----
if [ -n "$off_e" ] && [ "$off_e" -eq 3 ]; then
    echo "[hb-align] PASS flex-end drops the short item to the line bottom (off 3)"
else
    echo "[hb-align] FAIL flex-end offset expected 3, got $off_e"; fail=1
fi

# ---- (3) center: strictly between top and bottom ------------------------------
if [ -n "$off_c" ] && [ "$off_c" -gt "$off_s" ] && [ "$off_c" -lt "$off_e" ]; then
    echo "[hb-align] PASS center places the short item between top and bottom (off $off_c)"
else
    echo "[hb-align] FAIL center offset $off_c not strictly between $off_s and $off_e"; fail=1
fi

# ---- (4) stretch: content stays at TOP, background grows to full line height ---
if [ -n "$off_t" ] && [ "$off_t" -eq 0 ] && [ -n "$th" ] && [ "$th" -eq 4 ]; then
    echo "[hb-align] PASS stretch keeps content at top and grows the box fill to the line height"
else
    echo "[hb-align] FAIL stretch content-off=$off_t (expect 0) fill-height=$th (expect 4)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-align] RESULT: FAIL"; exit 1
fi
echo "[hb-align] RESULT: PASS"
