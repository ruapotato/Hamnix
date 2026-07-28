#!/usr/bin/env bash
# scripts/test_hambrowse_canvas2d_adv_host.sh — HOST-ONLY (QEMU-free) gate for the
# ADVANCED HTML Canvas 2D surface deferred by the core round: linear/radial
# GRADIENTS as fillStyle, context TRANSFORMS (save/restore/translate/scale/rotate/
# transform/setTransform) with a per-canvas CTM, and getImageData/putImageData/
# createImageData raw RGBA pixel access. A fixture <script> exercises all of them
# into a <canvas width=240 height=180>; we render the PAGE to a real PNG (eyeball
# it) then pixel-assert the framebuffer via scripts/hb_canvas_adv_probe.py,
# accounting for the canvas box's compositing origin in the page raster.
#
# Built with the frozen Python seed compiler; PNG via scripts/ppm_to_png.py.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-adv] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/adv_compile.log"; then
    echo "[hb-adv] FAIL: driver did not compile"; cat "$OUT/adv_compile.log"; exit 1
fi
echo "[hb-adv] PASS pixel backend compiled -> $BIN"

echo "[hb-adv] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/adv_native.log"; then
    echo "[hb-adv] FAIL: native hambrowse did not compile"; cat "$OUT/adv_native.log"; exit 1
fi
echo "[hb-adv] PASS native hambrowse still compiles"

FIX="tests/fixtures/hambrowse_canvas2d_adv.html"
DUMP="$OUT/canvas2d_adv_dump.txt"
PPM="$OUT/canvas2d_adv.ppm"
PNG="$OUT/canvas2d_adv.png"

echo "[hb-adv] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-adv] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi

if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/adv_png.log"; then
    echo "[hb-adv] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-adv] FAIL png conversion"; cat "$OUT/adv_png.log"; fail=1
fi

# The main <canvas> composites as a 240x180 image box; grab its page origin.
seg="$(grep -E '^IMGSEG slot [0-9]+ w 240 h 180' "$DUMP" | head -1)"
if [ -n "$seg" ]; then
    echo "[hb-adv] PASS canvas emitted a 240x180 image box ($seg)"
else
    echo "[hb-adv] FAIL canvas did not emit a 240x180 image box"
    cat "$DUMP"; exit 1
fi
XOFF="$(echo "$seg" | sed -E 's/.* x ([0-9]+) .*/\1/')"
TOP="$(echo "$seg" | sed -E 's/.* top ([0-9]+).*/\1/')"
echo "[hb-adv] canvas box origin = ($XOFF,$TOP)"

if python3 scripts/hb_canvas_adv_probe.py "$PPM" "$XOFF" "$TOP"; then
    echo "[hb-adv] pixel assertions passed"
else
    echo "[hb-adv] pixel assertions FAILED"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-adv] ALL PASS"
else
    echo "[hb-adv] SOME FAILURES"
fi
exit "$fail"
