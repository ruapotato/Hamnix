#!/usr/bin/env bash
# scripts/test_vk_2d_host.sh — FAST, QEMU-free host gate for the vk 2D
# primitive layer (lib/vk/vk_2d.ad), GPU track #181 Phase A: unifying the
# desktop compositor + hamSDL onto the native Vulkan-shaped spine.
#
# Mirrors scripts/test_hamsdl_host.sh: it compiles a HOST harness
# (user/vk2d_host.ad, x86_64-linux) that draws every vk2d primitive into a
# 64x64 RGBA8888 vk-style COLOR IMAGE (the same backing the vk render pass
# and present path use), dumps it as a PPM a human/agent can LOOK at, and
# asserts UNFORGEABLE pixels at known coordinates — all in milliseconds, no
# QEMU. vk_2d is EXTERN-FREE, so it also compiles into the kernel spine
# (lib/vk/vk_core.ad imports it) — that dual-target build is covered by the
# kernel build gate + scripts/test_vk_software_raster.sh; this gate stays a
# fast, QEMU-free host render/assert.
#
# UNFORGEABLE assertions (each a pixel only the real rasterizer produces):
#   * background clear color                          -> fill_rect (opaque)
#   * a filled rect's interior == the fill color      -> vk2d_fill_rect
#   * an alpha rect over a known bg == the exact
#     source-over blended value (#878b93)             -> vk2d_fill_rect_alpha
#   * a blit reproduces distinct source pixels
#     (green body + a blue corner pixel), natural
#     size AND 2x-scaled                              -> vk2d_blit
#   * a thick line covers y and y+1 but not y+3       -> vk2d_draw_line
#
# Pass marker:  [test_vk_2d] PASS   Fail marker:  [test_vk_2d] FAIL

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/vk2d_host"
mkdir -p "$OUT"
fail=0

echo "[test_vk_2d] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/vk2d_host.ad "$BIN" 2>"$OUT/vk2d_compile.log"; then
    echo "[test_vk_2d] FAIL: host harness did not compile"; cat "$OUT/vk2d_compile.log"; exit 1
fi
echo "[test_vk_2d] PASS host harness compiled -> $BIN"

echo "[test_vk_2d] running host harness ..."
DUMP="$OUT/vk2d_dump.txt"
PPM="$OUT/vk2d.ppm"
if ! "$BIN" "$PPM" >"$DUMP" 2>&1; then
    echo "[test_vk_2d] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

if python3 scripts/ppm_to_png.py "$PPM" "$OUT/vk2d.png" 2>"$OUT/vk2d_png.log"; then
    echo "[test_vk_2d] PASS rendered $OUT/vk2d.png ($(file -b "$OUT/vk2d.png" 2>/dev/null))"
else
    echo "[test_vk_2d] FAIL png conversion"; cat "$OUT/vk2d_png.log"; fail=1
fi

assert_pix() {
    local label="$1" line="$2" want="$3"
    local got
    got=$(awk -v k="$line" '$0 ~ ("^" k " ") {print $NF}' "$DUMP")
    if [ "$got" = "$want" ]; then
        echo "[test_vk_2d] PASS $label ($line = $want)"
    else
        echo "[test_vk_2d] FAIL $label ($line: got '$got' want '$want')"; fail=1
    fi
}

assert_ne() {
    local label="$1" line="$2" notwant="$3"
    local got
    got=$(awk -v k="$line" '$0 ~ ("^" k " ") {print $NF}' "$DUMP")
    if [ -n "$got" ] && [ "$got" != "$notwant" ]; then
        echo "[test_vk_2d] PASS $label ($line = $got, not $notwant)"
    else
        echo "[test_vk_2d] FAIL $label ($line: got '$got', should not be '$notwant')"; fail=1
    fi
}

echo "[test_vk_2d] --- sampled pixels ---"; cat "$DUMP"; echo "[test_vk_2d] --- end ---"

assert_pix "background clear (fill_rect opaque)"     "PIX_BG 0 0"          "#101828"
assert_pix "solid rect interior (vk2d_fill_rect)"    "PIX_RECT 10 10"      "#ff0000"
assert_pix "alpha rect source-over blend value"      "PIX_ALPHA 30 10"     "#878b93"
assert_ne  "alpha rect is blended (not opaque src)"  "PIX_ALPHA 30 10"     "#ffffff"
assert_pix "blit reproduces source green (natural)"  "PIX_BLIT 44 4"       "#00ff00"
assert_pix "blit reproduces distinct source pixel"   "PIX_BLIT_BLUE 47 7"  "#0000ff"
assert_pix "scaled blit reproduces source green"     "PIX_BLIT_SCALED 44 20" "#00ff00"
assert_pix "line hits the expected pixel"            "PIX_LINE 20 40"      "#ffff00"
assert_pix "line thickness covers y+1"               "PIX_LINE_THICK 20 41" "#ffff00"
assert_pix "line does not bleed to y+3 (bg)"         "PIX_LINE_BELOW 20 43" "#101828"
assert_pix "roundrect interior is solid (fill_roundrect)" "PIX_RR_IN 52 52"  "#00ffff"
assert_pix "roundrect corner rounded away to bg"     "PIX_RR_CORNER 44 44" "#101828"
assert_pix "cov-mask full coverage == ink color"     "PIX_COV_FULL 4 46"   "#ff0000"
assert_pix "cov-mask half coverage source-over blend" "PIX_COV_HALF 5 47"  "#870b13"
assert_ne  "cov-mask half coverage is blended (not bg)" "PIX_COV_HALF 5 47" "#101828"

if [ "$fail" -eq 0 ]; then
    echo "[test_vk_2d] PASS — vk 2D primitive layer rendered fill/alpha/blit/line into a vk color image"
    exit 0
fi
echo "[test_vk_2d] FAIL"
exit 1
