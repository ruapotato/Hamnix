#!/usr/bin/env bash
# scripts/test_hambrowse_filter_host.sh — FAST, QEMU-free gate for CSS `filter`
# (Filter Effects Module Level 1) in the native browser engine.
#
# The cascade parses `filter: grayscale()/brightness()/invert()/sepia()/
# contrast()/saturate()/opacity()/blur()` into a packed value that rides the
# layout record set (bfill_filter[], parallel to bfill_rgb[]) with ZERO reflow
# cost, and htmlpage_render runs a per-pixel POST-PASS (htmlpaint_filter_rect)
# over each filtered element's background box AFTER all fills/glyphs/borders are
# painted — so the element and its contents are filtered together (CSS subtree
# semantics).
#
# Builds BOTH the text-dump host harness AND the pixel backend so a break in the
# cascade OR the paint rasteriser is caught with no QEMU boot, then renders a
# fixture of solid colour boxes (one filter each) to a PPM and PIXEL-ASSERTS the
# transform: every box's ORIGINAL colour is gone and the EXPECTED filtered colour
# is present (a whole-image scan, robust to layout). Also confirms native
# hambrowse still compiles.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_filter.html"
mkdir -p "$OUT"
fail=0

echo "[hb-filter] compiling text harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/filter_compile.log"; then
    echo "[hb-filter] FAIL: host harness did not compile"; cat "$OUT/filter_compile.log"; exit 1
fi
echo "[hb-filter] PASS text harness compiled -> $BIN"

echo "[hb-filter] compiling pixel backend for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/filter_gfx.log"; then
    echo "[hb-filter] FAIL: pixel backend did not compile"; cat "$OUT/filter_gfx.log"; exit 1
fi
echo "[hb-filter] PASS pixel backend compiled -> $GFX"

echo "[hb-filter] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/filter_native.log"; then
    echo "[hb-filter] FAIL: native hambrowse did not compile"; cat "$OUT/filter_native.log"; exit 1
fi
echo "[hb-filter] PASS native hambrowse still compiles"

# Text harness sanity: the page renders (fills for the coloured boxes appear).
D0="$OUT/filter_run.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-filter] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

# Pixel path: render to PPM (+PNG to eyeball) and pixel-assert the filter output.
PPM="$OUT/filter.ppm"; PNG="$OUT/filter.png"
if "$GFX" "$FIX" "$PPM" 800 >"$OUT/filter_gfx_dump.txt" 2>&1; then
    if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/filter_png.log"; then
        echo "[hb-filter] PASS pixel render -> $PNG ($(file -b "$PNG" 2>/dev/null))"
    else
        echo "[hb-filter] FAIL png conversion"; cat "$OUT/filter_png.log"; fail=1
    fi
else
    echo "[hb-filter] FAIL: pixel render exited non-zero"; cat "$OUT/filter_gfx_dump.txt"; fail=1
fi

if ! python3 scripts/hb_filter_probe.py "$PPM"; then
    echo "[hb-filter] FAIL: filter pixel assertions failed"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-filter] RESULT: FAIL"; exit 1
fi
echo "[hb-filter] RESULT: PASS"
