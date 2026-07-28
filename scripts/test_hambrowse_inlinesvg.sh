#!/usr/bin/env bash
# scripts/test_hambrowse_inlinesvg.sh — FAST, QEMU-free gate for INLINE <svg>
# rendering in the native browser.
#
# Real HTML pages embed SVG icons/logos DIRECTLY as an <svg width= height=>...
# </svg> subtree (not via <img src=*.svg>). This gate proves hambrowse now flows
# such an inline <svg> as a REPLACED element: the whole subtree is rasterised
# through the SAME lib/svg.ad rasterizer that decodes <img src=*.svg> (no
# parallel parser), copied into lib/htmlimg.ad, and blitted exactly like a
# bitmap image — while its shape CHILDREN (<rect>/<circle>/<path>/<polygon>) are
# skipped from the text flow. Surrounding HTML text flows before and after it.
#
# The fixture tests/fixtures/hambrowse_inlinesvg.html carries a 96x64 viewBox
# <svg> with four distinctly-coloured shapes — a stroked red <rect>, a green
# <circle>, a blue <path> triangle, and an orange <polygon> diamond — between
# two prose paragraphs. The gate asserts:
#   * the inline <svg> reserves ONE 96x64 replaced image box (IMGSEG);
#   * each shape's interior samples its EXACT fill colour in the page pixels;
#   * the red rect's black stroke edge carries ink (proves stroke rendering);
#   * the prose before and after the SVG both reach the render (flow preserved).
# It also renders build/host/gfx_inlinesvg.png for eyeballing and re-compiles the
# NATIVE browser to prove the wiring is dual-target (host AND x86_64-adder-user).
#
# Built with the frozen Python seed compiler (no self-host bootstrap).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-isvg] compiling pixel backend (inline-svg wiring) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/isvg_compile.log"; then
    echo "[hb-isvg] FAIL: driver did not compile"; cat "$OUT/isvg_compile.log"; exit 1
fi
echo "[hb-isvg] PASS pixel backend compiled -> $BIN"

echo "[hb-isvg] compiling native hambrowse (dual-target) ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse.native" 2>"$OUT/isvg_native.log"; then
    echo "[hb-isvg] FAIL: native hambrowse did not compile"
    cat "$OUT/isvg_native.log"; exit 1
fi
echo "[hb-isvg] PASS native hambrowse compiled"

FIX="tests/fixtures/hambrowse_inlinesvg.html"
[ -s "$FIX" ] || { echo "[hb-isvg] FAIL: missing fixture $FIX"; exit 1; }

PPM="$OUT/gfx_inlinesvg.ppm"
PNG="$OUT/gfx_inlinesvg.png"
DUMP="$OUT/isvg_dump.txt"

echo "[hb-isvg] rendering $FIX (pass 1: geometry) ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-isvg] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-isvg] PASS $msg"
    else
        echo "[hb-isvg] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# The inline <svg> becomes ONE replaced image box at its 96x64 natural size.
assert_grep '^IMGSEG slot 0 w 96 h 64 ' \
    "inline <svg> reserves a 96x64 replaced image box (slot 0)"
# Prose before and after the SVG both reach the render (flow preserved).
assert_grep '^SEGTXT Text before the inline vector graphic' \
    "prose BEFORE the inline SVG flows into the render"
assert_grep '^SEGTXT Text after the inline vector graphic' \
    "prose AFTER the inline SVG flows into the render"

# ---- pixel-colour assertions inside the blitted inline-SVG box (EXACT) ----
read PX PTOP < <(awk '/^IMGSEG slot 0 w 96 h 64 /{print $9, $11; exit}' "$DUMP")
if [ -z "${PX:-}" ] || [ -z "${PTOP:-}" ]; then
    echo "[hb-isvg] FAIL could not read inline-SVG box geometry"; fail=1
else
    RX=$((PX + 16)); RY=$((PTOP + 32))    # red   rect  interior (x4-28,y20-44)
    KX=$((PX + 4));  KY=$((PTOP + 32))    # red   rect  BLACK STROKE left edge
    GX=$((PX + 48)); GY=$((PTOP + 32))    # green circle centre (cx48 cy32 r14)
    BX=$((PX + 80)); BY=$((PTOP + 38))    # blue  path  triangle interior
    OX=$((PX + 30)); OY=$((PTOP + 14))    # orange polygon diamond centre
    SDUMP="$OUT/isvg_samples.txt"
    echo "[hb-isvg] rendering (pass 2: pixel samples) ..."
    "$BIN" "$FIX" "$PPM" 640 "$RX" "$RY" "$KX" "$KY" "$GX" "$GY" \
        "$BX" "$BY" "$OX" "$OY" >"$SDUMP" 2>&1
    assert_pix() {
        local x="$1" y="$2" want="$3" msg="$4" hexline hex
        hexline=$(grep -E "^PIX $x $y #" "$SDUMP" | head -1)
        if [ -z "$hexline" ]; then
            echo "[hb-isvg] FAIL $msg: no sample at $x,$y"; fail=1; return
        fi
        hex=${hexline##*#}
        if [ "$hex" = "$want" ]; then
            echo "[hb-isvg] PASS $msg (#$hex at $x,$y)"
        else
            echo "[hb-isvg] FAIL $msg (#$hex want #$want at $x,$y)"; fail=1
        fi
    }
    assert_pix "$RX" "$RY" dc2828 "red <rect> fill blitted (exact)"
    assert_pix "$KX" "$KY" 000000 "red <rect> BLACK stroke edge has ink (exact)"
    assert_pix "$GX" "$GY" 28c83c "green <circle> fill blitted (exact)"
    assert_pix "$BX" "$BY" 325adc "blue <path> triangle fill blitted (exact)"
    assert_pix "$OX" "$OY" ffa500 "orange <polygon> diamond fill blitted (exact)"
fi

# Render the PPM to a PNG for eyeballing.
if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/isvg_png.log"; then
    echo "[hb-isvg] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-isvg] FAIL png conversion"; cat "$OUT/isvg_png.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-isvg] PASS"
else
    echo "[hb-isvg] FAIL"; exit 1
fi
