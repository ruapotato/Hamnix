#!/usr/bin/env bash
# scripts/test_hambrowse_transform_host.sh — FAST, QEMU-free gate for CSS 2D
# `transform` in the native browser engine (lib/web/css/cascade.ad +
# lib/htmlpaint.ad + lib/htmlpage.ad):
#
#   transform: translate(x[,y]) / translateX / translateY / scale(sx[,sy]) /
#              scaleX / scaleY / rotate(deg|rad|turn) / matrix(a,b,c,d,e,f)
#              and whitespace-separated composition applied left-to-right, with
#              transform-origin (default 50% 50% = centre).
#
#   The cascade composes the function list into a 2x3 affine matrix (12-bit
#   fixed point; Bhaskara sin/cos — EXACT at 0/90/180/270), binds it with the
#   fill the box paints and packs the reference through the background channel
#   (XFORM_MARK) so it flows to htmlpage UNCHANGED through the layout record set.
#   htmlpage repaints the box's border-box as a transformed QUAD via
#   htmlpaint_fill_box_xform: translate/scale are pixel-exact and rotation is a
#   real filled quad (not a bounding box).
#
# A modern-web staple (menus, cards, badges, hero art), so a regression must
# fail here without a QEMU boot. Builds the text-dump host harness, the pixel
# backend, and confirms native hambrowse still compiles; renders the fixture to
# a PPM/PNG and asserts the transformed PIXEL POSITIONS (a box that shifted
# +50,+30; a box doubled about its centre; a wide box turned tall by rotate(90);
# a matrix() equal to a known translate) plus the page background where each box
# vacated.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_transform.html"
mkdir -p "$OUT"
fail=0

echo "[hb-xform] compiling text harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/xform_compile.log"; then
    echo "[hb-xform] FAIL: host harness did not compile"; cat "$OUT/xform_compile.log"; exit 1
fi
echo "[hb-xform] PASS text harness compiled -> $BIN"

echo "[hb-xform] compiling pixel backend for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/xform_gfx.log"; then
    echo "[hb-xform] FAIL: pixel backend did not compile"; cat "$OUT/xform_gfx.log"; exit 1
fi
echo "[hb-xform] PASS pixel backend compiled -> $GFX"

echo "[hb-xform] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/xform_native.log"; then
    echo "[hb-xform] FAIL: native hambrowse did not compile"; cat "$OUT/xform_native.log"; exit 1
fi
echo "[hb-xform] PASS native hambrowse still compiles"

# text-dump sanity: the engine emits one FILL record per transformed block (4).
D0="$OUT/xform_run.txt"
"$BIN" "$FIX" 460 >"$D0" 2>&1 || { echo "[hb-xform] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
nf=$(grep -c '^FILL ' "$D0")
if [ "$nf" -eq 4 ]; then
    echo "[hb-xform] PASS 4 transformed background boxes registered"
else
    echo "[hb-xform] FAIL expected 4 FILL records, got $nf"; fail=1
fi

# pixel path: render to PPM+PNG, then assert transformed pixel positions.
PPM="$OUT/xform.ppm"; PNG="$OUT/xform.png"; GD="$OUT/xform_gfx_dump.txt"
if "$GFX" "$FIX" "$PPM" 460 >"$GD" 2>&1; then
    if python3 scripts/hb_transform_probe.py "$GD" "$PPM"; then
        echo "[hb-xform] PASS transformed-pixel assertions (translate/scale/rotate/matrix)"
    else
        echo "[hb-xform] FAIL transformed-pixel assertions"; fail=1
    fi
    if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/xform_png.log"; then
        echo "[hb-xform] PASS pixel render -> $PNG ($(file -b "$PNG" 2>/dev/null))"
    else
        echo "[hb-xform] FAIL png conversion"; cat "$OUT/xform_png.log"; fail=1
    fi
else
    echo "[hb-xform] FAIL: pixel render exited non-zero"; cat "$GD"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-xform] RESULT: FAIL"; exit 1; fi
echo "[hb-xform] RESULT: PASS"
