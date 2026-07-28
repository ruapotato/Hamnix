#!/usr/bin/env bash
# scripts/test_hambrowse_svg_transform.sh — FAST, QEMU-free gate for SVG
# transform= support (the CTM) in lib/svg.ad, exercised by BOTH the standalone
# svg_probe AND the full inline-<svg> browser path.
#
# Real icons/logos position their shapes with transforms, not just raw coords:
#   <g transform="translate(...) scale(...)">, per-shape rotate(a cx cy),
#   matrix(...), and NESTED <g> that stack. Before this, lib/svg.ad ignored
#   transform= entirely (only <g fill> inheritance) so every transformed shape
#   drew at its untransformed user coordinates — logos landed in the wrong place.
#
# lib/svg.ad now carries an affine CTM (a,b,c,d Q16 + e,f Q8) applied in user
# space in FRONT of the viewBox map. translate / scale / rotate(+centre) /
# matrix / skewX / skewY compose left-to-right and stack through nested <g>
# (saved/restored on </g>); a shape's own transform= composes on top for that
# element only. Identity CTM leaves the viewBox-only mapping bit-for-bit intact
# (the two pre-existing SVG gates stay green — proven by running them in CI).
#
# The fixture tests/fixtures/hambrowse_svg_xform.svg is a 100x100 viewBox board:
#   A  red    rect in <g translate(40,40)>              -> device (40,40)-(60,60)
#   B  green  rect in <g translate(5,70) scale(2)>      -> device (5,70)-(25,90)
#   C  blue   rect transform="rotate(90 50 25)"         -> horiz bar x35..65 y20..30
#   D  orange rect transform="matrix(1 0 0 1 70 5)"     -> device (70,5)-(85,20)
#   E  purple rect in NESTED <g translate(50,50)><g translate(20,20)> -> (70,70)-(78,78)
# Each assertion samples a pixel that is filled ONLY IF the transform is applied,
# plus a control pixel that must stay empty (proving the shape actually moved /
# scaled / rotated rather than drawing at its raw coordinates too).
#
# It also drives the full browser (hambrowse_host_gfx) over an inline-<svg>
# variant to prove the transform survives the inline-<svg> replaced-box path,
# and renders build/host/gfx_svg_xform.png for eyeballing.
#
# Built with the frozen Python seed compiler (no self-host bootstrap). The SVG /
# HTML fixtures are hand-written checked-in text (SVG needs no binary generator).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
PROBE="$OUT/svg_probe"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-xform] compiling standalone svg probe (with transform CTM) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/svg_probe.ad "$PROBE" 2>"$OUT/xform_probe_compile.log"; then
    echo "[hb-xform] FAIL: svg_probe did not compile"; cat "$OUT/xform_probe_compile.log"; exit 1
fi
echo "[hb-xform] PASS svg probe compiled -> $PROBE"

echo "[hb-xform] compiling pixel backend (inline-svg + transform) ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/xform_gfx_compile.log"; then
    echo "[hb-xform] FAIL: pixel backend did not compile"; cat "$OUT/xform_gfx_compile.log"; exit 1
fi
echo "[hb-xform] PASS pixel backend compiled -> $BIN"

echo "[hb-xform] compiling native hambrowse (dual-target) ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse.native" 2>"$OUT/xform_native.log"; then
    echo "[hb-xform] FAIL: native hambrowse did not compile"
    cat "$OUT/xform_native.log"; exit 1
fi
echo "[hb-xform] PASS native hambrowse compiled"

FSVG="tests/fixtures/hambrowse_svg_xform.svg"
FHTML="tests/fixtures/hambrowse_svg_xform.html"
for f in "$FSVG" "$FHTML"; do
    [ -s "$f" ] || { echo "[hb-xform] FAIL: missing fixture $f"; exit 1; }
done

# ---- standalone probe: direct per-pixel transform accuracy (EXACT) ----
DUMP="$OUT/svg_probe_xform.txt"
"$PROBE" "$FSVG" \
    50 50  10 10 \
    15 80  20 85 \
    50 25  60 25  50 15 \
    77 12 \
    74 74 2>&1 >"$DUMP"

if grep -Eq '^DIM 100 100$' "$DUMP"; then
    echo "[hb-xform] PASS transform SVG renders to natural 100x100"
else
    echo "[hb-xform] FAIL transform SVG dimensions"; cat "$DUMP"; fail=1
fi

xf_field() { grep -E "^PIX $1 $2 " "$DUMP" | head -1 | awk '{print $4,$5,$6,$7}'; }
assert_xf() {  # $1=x $2=y $3=r $4=g $5=b $6=a $7=msg
    read -r gr gg gb ga <<<"$(xf_field "$1" "$2")"
    if [ "$gr" = "$3" ] && [ "$gg" = "$4" ] && [ "$gb" = "$5" ] && [ "$ga" = "$6" ]; then
        echo "[hb-xform] PASS $7 ($gr,$gg,$gb,a$ga)"
    else
        echo "[hb-xform] FAIL $7 (got ${gr:-?},${gg:-?},${gb:-?},a${ga:-?} want $3,$4,$5,a$6)"; fail=1
    fi
}
# A: <g translate> — red rect moved to (40,40)-(60,60)
assert_xf 50 50 255 0   0   255 "<g translate> moves rect to its centre (red)"
assert_xf 10 10 0   0   0   0   "<g translate> vacates the untransformed origin (empty)"
# B: <g translate scale(2)> — green rect scaled to (5,70)-(25,90)
assert_xf 15 80 0   255 0   255 "<g translate+scale> centre filled green"
assert_xf 20 85 0   255 0   255 "scale(2) grows the rect past its unscaled 10x10 (green)"
# C: shape rotate(90 50 25) — vertical rect becomes a horizontal bar y20..30
assert_xf 50 25 0   0   255 255 "rotate(90 cx cy) keeps the pivot filled (blue)"
assert_xf 60 25 0   0   255 255 "rotate spins the bar horizontal beyond the original x (blue)"
assert_xf 50 15 0   0   0   0   "rotate vacates the original vertical extent (empty)"
# D: shape matrix(1 0 0 1 70 5) — pure translate
assert_xf 77 12 255 165 0   255 "matrix() translate places the orange rect"
# E: NESTED <g> transforms stack — purple rect at (70,70)-(78,78)
assert_xf 74 74 128 0   128 255 "nested <g> transforms compose (purple)"

# render the board to a viewable PNG (build/host/gfx_svg_xform.png)
XPPM="$OUT/gfx_svg_xform.ppm"
XPNG="$OUT/gfx_svg_xform.png"
"$PROBE" "$FSVG" --ppm "$XPPM" 4 >/dev/null 2>&1
if python3 scripts/ppm_to_png.py "$XPPM" "$XPNG" 2>"$OUT/xform_png.log"; then
    echo "[hb-xform] PASS rendered $XPNG ($(file -b "$XPNG" 2>/dev/null))"
else
    echo "[hb-xform] FAIL png conversion"; cat "$OUT/xform_png.log"; fail=1
fi

# ---- full browser: transform survives the inline-<svg> replaced-box path ----
HDUMP="$OUT/xform_html_dump.txt"
HPPM="$OUT/gfx_svg_xform_html.ppm"
echo "[hb-xform] rendering $FHTML (pass 1: geometry) ..."
if ! "$BIN" "$FHTML" "$HPPM" 640 >"$HDUMP" 2>&1; then
    echo "[hb-xform] FAIL: browser render exited non-zero"; cat "$HDUMP"; exit 1
fi
if grep -Eq '^IMGSEG slot 0 w 100 h 100 ' "$HDUMP"; then
    echo "[hb-xform] PASS inline <svg> with transforms reserves its 100x100 box"
else
    echo "[hb-xform] FAIL inline <svg> box geometry"; grep IMGSEG "$HDUMP"; fail=1
fi
read PX PTOP < <(awk '/^IMGSEG slot 0 w 100 h 100 /{print $9, $11; exit}' "$HDUMP")
if [ -z "${PX:-}" ] || [ -z "${PTOP:-}" ]; then
    echo "[hb-xform] FAIL could not read inline-SVG box geometry"; fail=1
else
    RX=$((PX + 50)); RY=$((PTOP + 50))   # A red rect centre (device 40-60,40-60)
    PXp=$((PX + 74)); PYp=$((PTOP + 74)) # E nested purple rect centre
    SDUMP="$OUT/xform_html_samples.txt"
    echo "[hb-xform] rendering (pass 2: pixel samples) ..."
    "$BIN" "$FHTML" "$HPPM" 640 "$RX" "$RY" "$PXp" "$PYp" >"$SDUMP" 2>&1
    assert_pix() {  # $1=x $2=y $3=hex $4=msg
        local x="$1" y="$2" want="$3" msg="$4" hexline hex
        hexline=$(grep -E "^PIX $x $y #" "$SDUMP" | head -1)
        if [ -z "$hexline" ]; then
            echo "[hb-xform] FAIL $msg: no sample at $x,$y"; fail=1; return
        fi
        hex=${hexline##*#}
        if [ "$hex" = "$want" ]; then
            echo "[hb-xform] PASS $msg (#$hex at $x,$y)"
        else
            echo "[hb-xform] FAIL $msg (#$hex want #$want at $x,$y)"; fail=1
        fi
    }
    assert_pix "$RX" "$RY" ff0000 "inline <svg> <g translate> red rect blitted"
    assert_pix "$PXp" "$PYp" 800080 "inline <svg> nested-<g> purple rect blitted"
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-xform] PASS"
else
    echo "[hb-xform] FAIL"; exit 1
fi
