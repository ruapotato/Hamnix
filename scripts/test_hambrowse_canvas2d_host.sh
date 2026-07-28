#!/usr/bin/env bash
# scripts/test_hambrowse_canvas2d_host.sh — HOST-ONLY (QEMU-free) gate for the
# HTML Canvas 2D core: getContext('2d'), fillRect/strokeRect, a path-filled
# triangle, anti-aliased fillText, and drawImage of a <canvas> source scaled to
# a dest rect. A fixture <script> draws all of these into a <canvas width=200
# height=150>; we render the PAGE to a real PNG (eyeball it) and then pixel-
# assert the framebuffer via scripts/hb_canvas_probe.py, accounting for the
# canvas box's compositing origin in the page raster.
#
# Built with the frozen Python seed compiler; PNG via scripts/ppm_to_png.py.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-canvas2d] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/canvas2d_compile.log"; then
    echo "[hb-canvas2d] FAIL: driver did not compile"; cat "$OUT/canvas2d_compile.log"; exit 1
fi
echo "[hb-canvas2d] PASS pixel backend compiled -> $BIN"

echo "[hb-canvas2d] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/canvas2d_native.log"; then
    echo "[hb-canvas2d] FAIL: native hambrowse did not compile"; cat "$OUT/canvas2d_native.log"; exit 1
fi
echo "[hb-canvas2d] PASS native hambrowse still compiles"

FIX="tests/fixtures/hambrowse_canvas2d.html"
DUMP="$OUT/canvas2d_dump.txt"
PPM="$OUT/canvas2d.ppm"
PNG="$OUT/canvas2d.png"

echo "[hb-canvas2d] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-canvas2d] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi

if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/canvas2d_png.log"; then
    echo "[hb-canvas2d] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-canvas2d] FAIL png conversion"; cat "$OUT/canvas2d_png.log"; fail=1
fi

# The main <canvas> composites as a 200x150 image box; grab its page origin.
seg="$(grep -E '^IMGSEG slot [0-9]+ w 200 h 150' "$DUMP" | head -1)"
if [ -n "$seg" ]; then
    echo "[hb-canvas2d] PASS canvas emitted a 200x150 image box ($seg)"
else
    echo "[hb-canvas2d] FAIL canvas did not emit a 200x150 image box"
    cat "$DUMP"; exit 1
fi
XOFF="$(echo "$seg" | sed -E 's/.* x ([0-9]+) .*/\1/')"
TOP="$(echo "$seg" | sed -E 's/.* top ([0-9]+).*/\1/')"
echo "[hb-canvas2d] canvas box origin = ($XOFF,$TOP)"

if python3 scripts/hb_canvas_probe.py "$PPM" "$XOFF" "$TOP"; then
    echo "[hb-canvas2d] pixel assertions passed"
else
    echo "[hb-canvas2d] pixel assertions FAILED"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-canvas2d] ALL PASS"
else
    echo "[hb-canvas2d] SOME FAILURES"
fi
exit "$fail"
