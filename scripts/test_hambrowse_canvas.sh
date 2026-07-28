#!/usr/bin/env bash
# scripts/test_hambrowse_canvas.sh — FAST, QEMU-free gate for the scoped HTML
# <canvas> 2D drawing backend (lib/htmlcanvas.ad + the getContext/2D plumbing in
# lib/htmlengine.ad, blitting through lib/htmlimg + lib/htmlpaint + lib/htmlpage).
#
# A fixture's <script> gets a 2D context and draws a tiny bar chart (three
# fillRect bars in distinct colours), a stroked circle (arc + stroke), a filled
# triangle (path fill), an anti-aliased fillText label, and a clearRect hole
# punched through a filled block. We render to a real PNG (eyeball it) AND SAMPLE
# the framebuffer pixels: each fillRect region must be exactly its fillStyle
# colour, the clearRect hole must fall back to the white page, the stroked shape
# must carry ink, and the label must be non-blank. A visual gate can false-green,
# so this asserts the actual pixels.
#
# Built with the frozen Python seed compiler; PNG via scripts/ppm_to_png.py.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-canvas] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/canvas_compile.log"; then
    echo "[hb-canvas] FAIL: driver did not compile"; cat "$OUT/canvas_compile.log"; exit 1
fi
echo "[hb-canvas] PASS pixel backend compiled -> $BIN"

echo "[hb-canvas] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/canvas_native.log"; then
    echo "[hb-canvas] FAIL: native hambrowse did not compile"; cat "$OUT/canvas_native.log"; exit 1
fi
echo "[hb-canvas] PASS native hambrowse still compiles"

FIX="tests/fixtures/hambrowse_canvas.html"
DUMP="$OUT/canvas_dump.txt"
PPM="$OUT/canvas.ppm"
PNG="$OUT/canvas.png"

echo "[hb-canvas] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-canvas] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi

if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/canvas_png.log"; then
    echo "[hb-canvas] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-canvas] FAIL png conversion"; cat "$OUT/canvas_png.log"; fail=1
fi

# The <canvas> becomes an image segment carrying its 320x200 backing buffer.
seg="$(grep -E '^IMGSEG slot [0-9]+ w 320 h 200' "$DUMP" | head -1)"
if [ -n "$seg" ]; then
    echo "[hb-canvas] PASS canvas emitted a 320x200 image box ($seg)"
else
    echo "[hb-canvas] FAIL canvas did not emit a 320x200 image box"
    cat "$DUMP"; exit 1
fi
XOFF="$(echo "$seg" | sed -E 's/.* x ([0-9]+) .*/\1/')"
TOP="$(echo "$seg" | sed -E 's/.* top ([0-9]+).*/\1/')"
echo "[hb-canvas] canvas box origin = ($XOFF,$TOP)"

# Absolute framebuffer coords = box origin + canvas-local coords (see fixture).
ax() { echo $((XOFF + $1)); }
ay() { echo $((TOP + $1)); }

# canvas-local sample points: red/green/blue bar centres, circle stroke edge,
# triangle fill, navy block, the clearRect hole, an empty background cell, and a
# 'Chart' label glyph pixel.
pairs=(40 150  100 130  160 110  295 100  250 170  282 12  296 25  10 190  27 20)
args=()
i=0
while [ $i -lt ${#pairs[@]} ]; do
    args+=("$(ax "${pairs[$i]}")" "$(ay "${pairs[$((i+1))]}")")
    i=$((i+2))
done

SAMP="$OUT/canvas_samples.txt"
"$BIN" "$FIX" "$PPM" 640 "${args[@]}" >"$SAMP" 2>&1

pix_at() {  # pix_at LOCALX LOCALY -> "#rrggbb"
    local X Y
    X="$(ax "$1")"; Y="$(ay "$2")"
    grep -E "^PIX $X $Y " "$SAMP" | head -1 | awk '{print $4}'
}

assert_col() {  # assert_col LOCALX LOCALY EXPECT MSG
    local got; got="$(pix_at "$1" "$2")"
    if [ "$got" = "$3" ]; then
        echo "[hb-canvas] PASS $4 (($1,$2)=$got)"
    else
        echo "[hb-canvas] FAIL $4 (($1,$2)=$got, want $3)"; fail=1
    fi
}

assert_not_white() {  # assert_not_white LOCALX LOCALY MSG
    local got; got="$(pix_at "$1" "$2")"
    if [ -n "$got" ] && [ "$got" != "#ffffff" ]; then
        echo "[hb-canvas] PASS $3 (($1,$2)=$got)"
    else
        echo "[hb-canvas] FAIL $3 (($1,$2)=$got, wanted ink)"; fail=1
    fi
}

# fillRect regions are exactly their fillStyle colour (named + #hex forms).
assert_col 40  150 "#ff0000" "red bar is fillStyle red"
assert_col 100 130 "#00a000" "green bar is fillStyle #00a000"
assert_col 160 110 "#0000ff" "blue bar is fillStyle blue"
# arc + stroke drew orange ink on the circle outline.
assert_col 295 100 "#ff8800" "stroked circle outline is strokeStyle #ff8800"
# path moveTo/lineTo/closePath + fill drew the filled triangle.
assert_col 250 170 "#8000c0" "filled triangle is fillStyle #8000c0"
# clearRect punched a transparent hole -> the white page shows through.
assert_col 282 12  "#000080" "navy block filled before clear"
assert_col 296 25  "#ffffff" "clearRect hole composites to white page"
# an untouched canvas cell stays the opaque white background we filled.
assert_col 10  190 "#ffffff" "background fillRect covered the canvas"
# fillText put anti-aliased ink where the 'Chart' label sits.
assert_not_white 27 20 "fillText drew label ink"

if [ "$fail" -eq 0 ]; then
    echo "[hb-canvas] ALL PASS"
else
    echo "[hb-canvas] SOME FAILURES"
fi
exit "$fail"
