#!/usr/bin/env bash
# scripts/test_hambrowse_borderradius_host.sh — FAST, QEMU-free gate for
# css-backgrounds-borders in the native browser engine:
#
#   1. border-COLOUR on non-table boxes. Before this the `border` shorthand was
#      reduced to a boolean (d_bd=1) and the block-box registry hardcoded
#      bbox_rgb=0 (black), so `border:3px solid #c00` painted a BLACK frame. The
#      cascade now captures the declared colour (from `border`, `border-color`
#      and `border-<side>-color`, incl. named / rgb() / hex tokens in any order)
#      and threads it through box_bordc_stack -> bbox_rgb, so the frame paints
#      its real colour. A later `border-color` overrides the shorthand colour.
#   2. border-RADIUS. Previously matched-and-dropped. It is now parsed into
#      d_bordr/m_bordr and threaded through to BOTH the background fill and the
#      1px border stroke, which round their corners (square when radius==0).
#
# Builds BOTH the text-dump host harness (x86_64-linux) AND the pixel backend
# (user/hambrowse_host_gfx.ad) so a break in the cascade OR the paint rasteriser
# is caught with no QEMU boot. Also confirms native hambrowse still compiles.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_borderradius.html"
mkdir -p "$OUT"
fail=0

echo "[hb-br] compiling text harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/br_compile.log"; then
    echo "[hb-br] FAIL: host harness did not compile"; cat "$OUT/br_compile.log"; exit 1
fi
echo "[hb-br] PASS text harness compiled -> $BIN"

echo "[hb-br] compiling pixel backend for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/br_gfx.log"; then
    echo "[hb-br] FAIL: pixel backend did not compile"; cat "$OUT/br_gfx.log"; exit 1
fi
echo "[hb-br] PASS pixel backend compiled -> $GFX"

echo "[hb-br] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/br_native.log"; then
    echo "[hb-br] FAIL: native hambrowse did not compile"; cat "$OUT/br_native.log"; exit 1
fi
echo "[hb-br] PASS native hambrowse still compiles"

D0="$OUT/br_run.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-br] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E '^FILL|^BBOX' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-br] PASS $2"
    else
        echo "[hb-br] FAIL $2 (missing: $1)"; fail=1
    fi
}
refute_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-br] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-br] PASS $2"
    fi
}

# BBOX lines are "BBOX top bot lx rx #hex rad".
# 1. GAP-1 border colour: the .card frame is RED (#cc0000), not the old black.
assert_grep 'BBOX [0-9]+ [0-9]+ [0-9]+ [0-9]+ #cc0000 8' \
    "border:3px solid #c00 paints a RED frame with radius 8"
refute_grep 'BBOX [0-9]+ [0-9]+ [0-9]+ [0-9]+ #000000 8' \
    "the rounded card frame is NOT hardcoded black"
# named colour keyword.
assert_grep 'BBOX [0-9]+ [0-9]+ [0-9]+ [0-9]+ #008080 0' \
    "border:2px solid teal paints a TEAL frame (named colour)"
# rgb() functional colour.
assert_grep 'BBOX [0-9]+ [0-9]+ [0-9]+ [0-9]+ #1478c8 0' \
    "border:1px solid rgb(20,120,200) paints the rgb() colour"
# a later border-color overrides the shorthand's colour.
assert_grep 'BBOX [0-9]+ [0-9]+ [0-9]+ [0-9]+ #33aa55 0' \
    "border-color:#33aa55 overrides the shorthand black"

# 2. GAP-2 border-radius on the FILL: the .card fill (#eeeeff) rounds (rad 8);
#    the square boxes keep rad 0.
assert_grep 'FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #eeeeff 8' \
    "background fill of the rounded card carries radius 8"
assert_grep 'FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #ffffee 0' \
    "background fill of the square box keeps radius 0"

# 3. Pixel path: render to a PPM so the rounded/coloured frame is exercised by
#    the real rasteriser (htmlpaint_stroke_round_rect / fill_round_rect), then
#    PROVE the corners are actually cut. hb_borderradius_probe.py samples the
#    large-radius solid #0040ff box: the four CORNER pixels must show the page
#    background (fill does NOT reach them) while the CENTRE + four edge midpoints
#    ARE the fill colour — an unambiguous "the corners are round" pixel check.
PPM="$OUT/br.ppm"; PNG="$OUT/br.png"
if "$GFX" "$FIX" "$PPM" 800 >"$OUT/br_gfx_dump.txt" 2>&1; then
    python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/br_png.log" || true
    if python3 scripts/hb_borderradius_probe.py "$OUT/br_gfx_dump.txt" "$PPM"; then
        echo "[hb-br] PASS corner-cut pixel probe (-> $PNG)"
    else
        echo "[hb-br] FAIL corner-cut pixel probe"; fail=1
    fi
else
    echo "[hb-br] FAIL: pixel render exited non-zero"; cat "$OUT/br_gfx_dump.txt"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-br] RESULT: FAIL"; exit 1
fi
echo "[hb-br] RESULT: PASS"
