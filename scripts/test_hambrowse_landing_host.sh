#!/usr/bin/env bash
# scripts/test_hambrowse_landing_host.sh — FAST, QEMU-free gate for the native
# browser engine against a REALISTIC stylesheet-driven marketing page
# (tests/fixtures/hambrowse_landing.html): a flex top bar, a card grid, and a
# two-column main/sidebar layout, all styled from an author <style> block.
#
# It pins the two regressions fixed in the 2026-07-15 compat-audit round:
#   (1) `border-radius` on a backgrounded card must NOT draw a hard 1px frame.
#       Every card here has `border-radius`+`box-shadow` but NO `border`, so the
#       BORDER count must be 0. (Before the fix, _box_decl matched the `border`
#       prefix on `border-radius` and stroked a rectangle around every card.)
#   (2) `background: rgba(r,g,b,a)` must parse (alpha ignored) instead of being
#       dropped. The .btn declares rgba(255,200,0,0.9); its background fill's
#       DECLARED colour must be #ffc800, not the inherited hero colour.
# It also asserts the three card backgrounds and the hero/bar/footer fills
# actually paint (POSFILL col == sampled pixel), and that prose does not
# overflow the viewport.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_landing.html"
DUMP="$OUT/landing_dump.txt"
PPM="$OUT/landing.ppm"
PNG="$OUT/landing.png"
mkdir -p "$OUT"
fail=0

echo "[hb-land] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/land_compile.log"; then
    echo "[hb-land] FAIL: driver did not compile"; cat "$OUT/land_compile.log"; exit 1
fi
echo "[hb-land] PASS pixel backend compiled -> $BIN"

echo "[hb-land] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/land_native.log"; then
    echo "[hb-land] FAIL: native hambrowse did not compile"; cat "$OUT/land_native.log"; exit 1
fi
echo "[hb-land] PASS native hambrowse still compiles"

echo "[hb-land] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 900 >"$DUMP" 2>&1; then
    echo "[hb-land] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^POSFILL|^BORDER n|^REFLOW' "$DUMP" || true
python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>/dev/null && \
    echo "[hb-land] wrote $PNG for eyeballing" || true

# (1) border-radius must NOT synthesise a border box.
NBORD=$(awk '$1=="BORDER" && $2=="n" {print $3; exit}' "$DUMP")
if [ "${NBORD:-x}" = "0" ]; then
    echo "[hb-land] PASS border-radius drew no spurious border (BORDER n 0)"
else
    echo "[hb-land] FAIL border-radius drew a border frame (BORDER n=$NBORD, want 0)"; fail=1
fi

# (2) rgba() background parses: the .btn fill's declared colour is #ffc800.
BTN=$(awk '$1=="POSFILL" && $14=="#ffc800" {print $14; exit}' "$DUMP")
if [ "$BTN" = "#ffc800" ]; then
    echo "[hb-land] PASS rgba(255,200,0,0.9) parsed to #ffc800"
else
    echo "[hb-land] FAIL rgba() background not parsed (no #ffc800 POSFILL)"; fail=1
fi

# (3) the three card backgrounds paint (declared col == sampled pixel).
NCARD=$(awk '$1=="POSFILL" && $14=="#f2f5f9" && $16=="#f2f5f9"' "$DUMP" | wc -l)
if [ "$NCARD" -eq 3 ]; then
    echo "[hb-land] PASS all 3 card backgrounds painted (#f2f5f9)"
else
    echo "[hb-land] FAIL expected 3 painted card backgrounds, got $NCARD"; fail=1
fi

# (4) hero + bar + footer fills paint (declared col == sampled pixel).
for col in '#0d1b2a' '#12345a' '#eef2f7'; do
    n=$(awk -v c="$col" '$1=="POSFILL" && $14==c && $16==c' "$DUMP" | wc -l)
    if [ "$n" -ge 1 ]; then
        echo "[hb-land] PASS fill $col painted"
    else
        echo "[hb-land] FAIL fill $col did not paint"; fail=1
    fi
done

# (6) the `position:fixed; left:0; right:0` flex top bar (#0d1b2a) stretches to
# the FULL content width, not its natural flex-content width. Pre-fix the bar's
# background fill ended at x1~568 (audit #6: content-width, right:0 ignored);
# with both edges anchored it now spans to the content-right (x1 >= 700 at a
# 900px viewport). Proves absolute/fixed both-edge stretch.
BARX1=$(awk '$1=="POSFILL" && $14=="#0d1b2a" {print $10; exit}' "$DUMP")
if [ -n "$BARX1" ] && [ "$BARX1" -ge 700 ]; then
    echo "[hb-land] PASS fixed bar stretched to full content width (x1=$BARX1 >= 700)"
else
    echo "[hb-land] FAIL fixed bar did not stretch to full width (x1=${BARX1:-none}, want >=700)"; fail=1
fi

# (5) prose does not overflow the viewport.
OVER=$(awk '$1=="REFLOW" {for(i=1;i<=NF;i++) if($i=="overflow") print $(i+1)}' "$DUMP")
if [ "${OVER:-1}" = "0" ]; then
    echo "[hb-land] PASS no prose overflow past the viewport"
else
    echo "[hb-land] FAIL prose overflowed the viewport (overflow=$OVER)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-land] RESULT: PASS"
else
    echo "[hb-land] RESULT: FAIL"; exit 1
fi
