#!/usr/bin/env bash
# scripts/test_hambrowse_gradient2_host.sh — FAST, QEMU-free gate for the SECOND
# wave of CSS image backgrounds in the native browser engine (lib/web/css/
# cascade.ad + lib/htmlpaint.ad + lib/htmlpage.ad):
#
#   * conic-gradient(from <angle>, c0..cN)          — per-pixel angle-based ramp
#     around the box centre;
#   * repeating-linear/radial/conic-gradient(...)   — the stop pattern TILES;
#   * background-image: url(<path>)                  — a decoded raster/SVG image
#     painted as the element background (border-radius clipped), matched by name
#     against the shared decoded-image store.
#
# These join linear/radial gradients (test_hambrowse_gradient_host.sh) toward
# full css-images conformance. The cascade parses each into the gradient/url
# side registry and packs the ID through the layout record set under GRAD_MARK;
# htmlpage rasterises conic/repeating via htmlpaint_fill_gradient and blits url
# backgrounds via htmlpaint_blit_image_bg. Renders the fixture to a PPM/PNG and
# asserts the PIXEL values (conic hue varies by angle; the repeating ramp
# recurs one period later; the url() box shows the 2x2 quadrant PNG's decoded
# red/green/blue/yellow pixels).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_gradient2.html"
mkdir -p "$OUT"
fail=0

echo "[hb-grad2] compiling text harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/grad2_compile.log"; then
    echo "[hb-grad2] FAIL: host harness did not compile"; cat "$OUT/grad2_compile.log"; exit 1
fi
echo "[hb-grad2] PASS text harness compiled -> $BIN"

echo "[hb-grad2] compiling pixel backend for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/grad2_gfx.log"; then
    echo "[hb-grad2] FAIL: pixel backend did not compile"; cat "$OUT/grad2_gfx.log"; exit 1
fi
echo "[hb-grad2] PASS pixel backend compiled -> $GFX"

echo "[hb-grad2] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/grad2_native.log"; then
    echo "[hb-grad2] FAIL: native hambrowse did not compile"; cat "$OUT/grad2_native.log"; exit 1
fi
echo "[hb-grad2] PASS native hambrowse still compiles"

# text-dump sanity: the engine emits one FILL record per image-background box (3).
D0="$OUT/grad2_run.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-grad2] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
nf=$(grep -c '^FILL ' "$D0")
if [ "$nf" -eq 3 ]; then
    echo "[hb-grad2] PASS 3 image-background boxes registered"
else
    echo "[hb-grad2] FAIL expected 3 FILL records, got $nf"; fail=1
fi

# pixel path: render to PPM+PNG, then assert the conic/repeat/url pixel values.
PPM="$OUT/grad2.ppm"; PNG="$OUT/grad2.png"; GD="$OUT/grad2_gfx_dump.txt"
if "$GFX" "$FIX" "$PPM" 800 >"$GD" 2>&1; then
    # the url() background requires the tile PNG to have decoded into the store.
    if grep -q '^IMGDEC "hb_bgimg_tile.png" 0' "$GD"; then
        echo "[hb-grad2] PASS bg tile PNG decoded into the image store"
    else
        echo "[hb-grad2] FAIL bg tile PNG did not decode"; grep '^IMGDEC' "$GD"; fail=1
    fi
    if python3 scripts/hb_gradient2_probe.py "$GD" "$PPM"; then
        echo "[hb-grad2] PASS pixel assertions (conic angle / repeat tiling / url image)"
    else
        echo "[hb-grad2] FAIL pixel assertions"; fail=1
    fi
    if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/grad2_png.log"; then
        echo "[hb-grad2] PASS pixel render -> $PNG ($(file -b "$PNG" 2>/dev/null))"
    else
        echo "[hb-grad2] FAIL png conversion"; cat "$OUT/grad2_png.log"; fail=1
    fi
else
    echo "[hb-grad2] FAIL: pixel render exited non-zero"; cat "$GD"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-grad2] RESULT: FAIL"; exit 1; fi
echo "[hb-grad2] RESULT: PASS"
