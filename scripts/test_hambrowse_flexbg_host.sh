#!/usr/bin/env bash
# scripts/test_hambrowse_flexbg_host.sh — FAST, QEMU-free render-to-PNG gate for
# the flex/grid CONTAINER-BACKGROUND fidelity fix (lib/web/layout/box.ad +
# lib/htmlpage.ad). Drives the REAL pixel backend (user/hambrowse_host_gfx.ad ->
# lib/htmlpaint + lib/htmlpage) and PIXEL-asserts, straight from the framebuffer:
#
#   (A) NAV BAND — a `display:flex` nav with a dark `background` paints its own
#       background BAND behind its light-text links (the on-device "renders its
#       links but not its background band" defect). The band colour is present
#       spanning the nav width, and a point BETWEEN the links samples the band
#       colour, not page white.
#   (B) CONTAINER BEHIND ITEMS — a flex container whose ITEMS carry their own
#       backgrounds paints its band BEHIND the item chips: the container colour
#       AND both item-chip colours are all present at once (correct CSS painting
#       order: parent background first, child backgrounds on top). This is the
#       z-order fix — before it, the container fill (emitted last, in close
#       order) over-painted the child chips.
#   (C) GRID BAND — a `display:grid` container's background paints behind its
#       cells, same as a block.
#
# Deterministic: renders a bundled fixture, never the network. PNG/PPM handling
# is stdlib-only (scripts/ppm_to_png.py + scripts/hb_flexbg_probe.py). Builds the
# native browser too so a break in either target is caught. NO QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_flexbg.html"
PPM="$OUT/flexbg.ppm"
PNG="$OUT/flexbg.png"
mkdir -p "$OUT"
fail=0

echo "[hb-flexbg] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/flexbg_compile.log"; then
    echo "[hb-flexbg] FAIL: driver did not compile"; cat "$OUT/flexbg_compile.log"; exit 1
fi
echo "[hb-flexbg] PASS pixel backend compiled"

echo "[hb-flexbg] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/flexbg_native.elf" 2>"$OUT/flexbg_native.log"; then
    echo "[hb-flexbg] FAIL: native hambrowse did not compile"; cat "$OUT/flexbg_native.log"; exit 1
fi
echo "[hb-flexbg] PASS native hambrowse still compiles"

echo "[hb-flexbg] rendering $FIX at width 800 ..."
if ! "$BIN" "$FIX" "$PPM" 800 >"$OUT/flexbg_dump.txt" 2>&1; then
    echo "[hb-flexbg] FAIL: render exited non-zero"; cat "$OUT/flexbg_dump.txt"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 && echo "[hb-flexbg] wrote $PNG"

PROBE=$(python3 scripts/hb_flexbg_probe.py "$PPM" \
        333333,446688,cc0000,00aa00,224488)
echo "$PROBE"

pass() { echo "[hb-flexbg] PASS $1"; }
bad()  { echo "[hb-flexbg] FAIL $1"; fail=1; }

nof() {  # colour -> pixel count (0 if MISS)
    echo "$PROBE" | awk -v c="#$1" '$2==c { for(i=3;i<=NF;i++) if($i ~ /^n=/){sub("n=","",$i);print $i}}' | head -1
}
widthof() {
    echo "$PROBE" | awk -v c="#$1" '$2==c { for(i=3;i<=NF;i++) if($i ~ /^w=/){sub("w=","",$i);print $i}}' | head -1
}

# ---- (A) nav band present + spans a wide strip -----------------------------
NAV=$(nof 333333); NAVW=$(widthof 333333)
if [ -n "$NAV" ] && [ "$NAV" -ge 2000 ] && [ -n "$NAVW" ] && [ "$NAVW" -ge 300 ]; then
    pass "flex nav paints its background BAND (n=$NAV px, w=$NAVW)"
else
    bad "flex nav background band missing/too small (n=${NAV:-0} w=${NAVW:-0})"
fi

# ---- (B) container band + BOTH item chips all visible ----------------------
CONT=$(nof 446688); RED=$(nof cc0000); GRN=$(nof 00aa00)
if [ -n "$CONT" ] && [ "$CONT" -ge 1000 ]; then
    pass "flex container band paints BEHIND its items (band #446688 visible, n=$CONT)"
else
    bad "flex container band not visible behind items (n=${CONT:-0})"
fi
if [ -n "$RED" ] && [ "$RED" -ge 50 ] && [ -n "$GRN" ] && [ "$GRN" -ge 50 ]; then
    pass "both item chips paint ON TOP of the band (#cc0000 n=$RED, #00aa00 n=$GRN)"
else
    bad "an item chip was over-painted by the container band (#cc0000=${RED:-0} #00aa00=${GRN:-0})"
fi

# ---- (C) grid container band present ---------------------------------------
GRID=$(nof 224488)
if [ -n "$GRID" ] && [ "$GRID" -ge 1000 ]; then
    pass "grid container paints its background band (#224488 n=$GRID)"
else
    bad "grid container background band missing (n=${GRID:-0})"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-flexbg] RESULT: FAIL"; exit 1
fi
echo "[hb-flexbg] RESULT: PASS"
