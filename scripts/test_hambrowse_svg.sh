#!/usr/bin/env bash
# scripts/test_hambrowse_svg.sh — FAST, QEMU-free gate for SVG <img> support in
# the native browser (#101). Real-web logos/icons (e.g. debian.org's feature
# icons) are SVG; before this they drew as broken-image boxes.
#
# lib/svg.ad is a from-scratch, pure-Adder, INTEGER-ONLY minimal SVG rasterizer:
# a tiny XML tag scanner (root <svg> width/height/viewBox; <rect> <circle>
# <ellipse> <line> <polygon> <polyline> <path>), presentation attributes (fill
# named + #rgb/#rrggbb + none, fill-opacity, fill-rule, basic stroke), a path
# mini-language (M m L l H h V v C c Q q Z z, beziers flattened), and an
# anti-aliased scanline polygon fill (nonzero / even-odd winding, straight-alpha
# compositing). SVG has NO binary magic, so the two hambrowse decode sites
# dispatch to it by CONTENT via svg_sniff() and feed the RGBA into lib/htmlimg.ad
# exactly like PNG/JPEG/GIF.
#
# The gate renders tests/fixtures/hambrowse_svg.html — a hand-written shapes SVG
# (red rect + green circle + blue path-triangle + orange polygon-diamond in
# distinct colors), a small real-world-style logo SVG, and a MALFORMED SVG (no
# <svg> root) — and asserts:
#   * the shapes SVG decodes to its natural 48x32 with the EXACT solid colors at
#     each shape's center (fills are solid at the interior; AA only at edges);
#   * the logo SVG decodes to 64x64;
#   * svg_sniff() accepts XML/SVG text and rejects non-SVG bytes;
#   * a malformed SVG reports rc<0 and draws the grey placeholder, no crash;
#   * the blitted <img> boxes show those exact colors in the page.
# It also runs lib/svg.ad's standalone probe for direct per-pixel accuracy, and
# renders build/host/gfx_svg.png for eyeballing.
#
# Built with the frozen Python seed compiler (no self-host bootstrap). Fixtures
# are hand-written checked-in SVG/HTML text (SVG needs no binary generator).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
PROBE="$OUT/svg_probe"
mkdir -p "$OUT"
fail=0

echo "[hb-svg] compiling pixel backend (with SVG decode) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/svg_compile.log"; then
    echo "[hb-svg] FAIL: driver did not compile"; cat "$OUT/svg_compile.log"; exit 1
fi
echo "[hb-svg] PASS pixel backend compiled -> $BIN"

echo "[hb-svg] compiling standalone svg probe ..."
if ! adder_bin x86_64-linux user/svg_probe.ad "$PROBE" 2>"$OUT/svg_probe_compile.log"; then
    echo "[hb-svg] FAIL: svg_probe did not compile"; cat "$OUT/svg_probe_compile.log"; exit 1
fi
echo "[hb-svg] PASS svg probe compiled -> $PROBE"

# Also confirm the NATIVE browser still compiles with the SVG dispatch wired in.
echo "[hb-svg] compiling native hambrowse (dispatch wiring) ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse.native" 2>"$OUT/svg_native_compile.log"; then
    echo "[hb-svg] FAIL: native hambrowse did not compile"
    cat "$OUT/svg_native_compile.log"; exit 1
fi
echo "[hb-svg] PASS native hambrowse compiled"

FSHAPES="tests/fixtures/hambrowse_svg_shapes.svg"
FLOGO="tests/fixtures/hambrowse_svg_logo.svg"
FBAD="tests/fixtures/hambrowse_svg_bad.svg"
for f in "$FSHAPES" "$FLOGO" "$FBAD"; do
    [ -s "$f" ] || { echo "[hb-svg] FAIL: missing fixture $f"; exit 1; }
done

# ---- standalone probe: direct per-pixel render accuracy (EXACT centers) ----
DUMP="$OUT/svg_probe_shapes.txt"
"$PROBE" "$FSHAPES" 12 8 36 8 12 26 36 24 2>&1 >"$DUMP"

probe_field() {  # $1=pattern-x $2=pattern-y -> echoes "r g b a"
    grep -E "^PIX $1 $2 " "$DUMP" | head -1 | awk '{print $4, $5, $6, $7}'
}
assert_probe() {  # $1=x $2=y $3=r $4=g $5=b $6=a $7=msg
    read -r gr gg gb ga <<<"$(probe_field "$1" "$2")"
    if [ "$gr" = "$3" ] && [ "$gg" = "$4" ] && [ "$gb" = "$5" ] && [ "$ga" = "$6" ]; then
        echo "[hb-svg] PASS $7 (exact $gr,$gg,$gb,a$ga)"
    else
        echo "[hb-svg] FAIL $7 (got ${gr:-?},${gg:-?},${gb:-?},a${ga:-?} want $3,$4,$5,a$6)"; fail=1
    fi
}
if grep -Eq '^DIM 48 32$' "$DUMP"; then
    echo "[hb-svg] PASS shapes SVG renders to natural 48x32"
else
    echo "[hb-svg] FAIL shapes SVG dimensions"; cat "$DUMP"; fail=1
fi
if grep -Eq '^SNIFF 1$' "$DUMP"; then
    echo "[hb-svg] PASS svg_sniff accepts XML/SVG text"
else
    echo "[hb-svg] FAIL svg_sniff rejected valid SVG"; fail=1
fi
assert_probe 12 8  220 40 40  255 "red <rect> center"
assert_probe 36 8  40 200 60  255 "green <circle> center"
assert_probe 12 26 50 90 220  255 "blue <path> triangle center"
assert_probe 36 24 255 165 0  255 "orange <polygon> diamond center"

# logo renders to 64x64
LDUMP="$OUT/svg_probe_logo.txt"
"$PROBE" "$FLOGO" 32 32 2>&1 >"$LDUMP"
if grep -Eq '^DIM 64 64$' "$LDUMP"; then
    echo "[hb-svg] PASS logo SVG renders to 64x64"
else
    echo "[hb-svg] FAIL logo SVG dimensions"; cat "$LDUMP"; fail=1
fi

# malformed SVG (no <svg> root): sniff rejects OR decode fails cleanly, no crash
BDUMP="$OUT/svg_probe_bad.txt"
"$PROBE" "$FBAD" 4 4 2>&1 >"$BDUMP"
if grep -Eq '^RC -[0-9]' "$BDUMP"; then
    echo "[hb-svg] PASS malformed SVG rejected (rc<0, no crash)"
else
    echo "[hb-svg] FAIL malformed SVG not rejected"; cat "$BDUMP"; fail=1
fi

# non-SVG bytes must NOT sniff as SVG (so the dispatch never mis-routes them)
GDUMP="$OUT/svg_probe_nonsvg.txt"
printf '%s' 'plain text, definitely not markup 123' > "$OUT/nonsvg.txt"
"$PROBE" "$OUT/nonsvg.txt" 2>&1 >"$GDUMP"
if grep -Eq '^SNIFF 0$' "$GDUMP"; then
    echo "[hb-svg] PASS svg_sniff rejects non-SVG bytes"
else
    echo "[hb-svg] FAIL svg_sniff mis-accepted non-SVG"; cat "$GDUMP"; fail=1
fi

# ---- elliptical arcs (A/a), smooth curves (S/T), rounded rect (rx/ry) -------
# hambrowse_svg_arcs.svg packs one of each real-icon feature into a 96x64 board:
#   * a GREEN rounded <rect rx=10 ry=10> at (4,4,40,24) — its quarter-ellipse
#     corners cut the extreme corner pixel to TRANSPARENT while the centre is
#     solid green;
#   * a NAVY square <rect> at (4,36,40,24) — identical box, square corners, so
#     its extreme corner pixel IS filled: the corner contrast proves rx/ry;
#   * a RED elliptical-arc pie (<path ... A 18 18 0 0 1 ...>) — interior filled,
#     the far bounding-box corner beyond the radius stays empty (proves it is a
#     curve, not a square);
#   * an ORANGE smooth-cubic S wave (<path ... C ... S ...>) stroked.
FARC="tests/fixtures/hambrowse_svg_arcs.svg"
FARC2="tests/fixtures/hambrowse_svg_arcs2.svg"
for f in "$FARC" "$FARC2"; do
    [ -s "$f" ] || { echo "[hb-svg] FAIL: missing fixture $f"; exit 1; }
done
ADUMP="$OUT/svg_probe_arcs.txt"
"$PROBE" "$FARC" \
    24 16  5 5  24 48  5 47  76 22  90 36  74 52 2>&1 >"$ADUMP"

adump_field() { grep -E "^PIX $1 $2 " "$ADUMP" | head -1 | awk '{print $4,$5,$6,$7}'; }
assert_arc() {  # $1=x $2=y $3=r $4=g $5=b $6=a $7=msg
    read -r gr gg gb ga <<<"$(adump_field "$1" "$2")"
    if [ "$gr" = "$3" ] && [ "$gg" = "$4" ] && [ "$gb" = "$5" ] && [ "$ga" = "$6" ]; then
        echo "[hb-svg] PASS $7 ($gr,$gg,$gb,a$ga)"
    else
        echo "[hb-svg] FAIL $7 (got ${gr:-?},${gg:-?},${gb:-?},a${ga:-?} want $3,$4,$5,a$6)"; fail=1
    fi
}
if grep -Eq '^DIM 96 64$' "$ADUMP"; then
    echo "[hb-svg] PASS arcs SVG renders to 96x64"
else
    echo "[hb-svg] FAIL arcs SVG dimensions"; cat "$ADUMP"; fail=1
fi
assert_arc 24 16 40 200 60 255 "rounded <rect rx/ry> centre solid green"
assert_arc 5  5  0  0   0  0   "rounded-rect corner cut away (transparent)"
assert_arc 24 48 16 48 160 255 "square <rect> centre solid navy"
assert_arc 5  47 16 48 160 255 "square-rect corner FILLED (rx/ry contrast)"
assert_arc 76 22 220 40 40 255 "elliptical-arc pie interior filled red"
assert_arc 90 36 0  0  0  0    "arc pie far corner empty (curve, not square)"
assert_arc 74 52 255 165 0 255 "smooth-cubic S stroke on the curve (orange)"

# arcs2: RELATIVE arcs with PACKED flags ("a12 12 0 016 12") + smooth-quad T.
A2DUMP="$OUT/svg_probe_arcs2.txt"
"$PROBE" "$FARC2" 32 20  16 32  36 48 2>&1 >"$A2DUMP"
adump2_field() { grep -E "^PIX $1 $2 " "$A2DUMP" | head -1 | awk '{print $4,$5,$6,$7}'; }
assert_arc2() {
    read -r gr gg gb ga <<<"$(adump2_field "$1" "$2")"
    if [ "$gr" = "$3" ] && [ "$gg" = "$4" ] && [ "$gb" = "$5" ] && [ "$ga" = "$6" ]; then
        echo "[hb-svg] PASS $7 ($gr,$gg,$gb,a$ga)"
    else
        echo "[hb-svg] FAIL $7 (got ${gr:-?},${gg:-?},${gb:-?},a${ga:-?} want $3,$4,$5,a$6)"; fail=1
    fi
}
if grep -Eq '^RC 0$' "$A2DUMP"; then
    echo "[hb-svg] PASS relative packed-flag arcs decode (no crash)"
else
    echo "[hb-svg] FAIL relative packed-flag arcs failed to decode"; cat "$A2DUMP"; fail=1
fi
assert_arc2 32 20 112 48 192 255 "capsule of relative packed-flag arcs filled purple"
assert_arc2 16 32 0 128 128 255 "smooth-quad T first hump (teal stroke, up)"
assert_arc2 36 48 0 128 128 242 "smooth-quad T reflected hump (teal stroke, down)"

# render the arcs board to a viewable PNG (build/host/gfx_svg_arcs.png)
APPM="$OUT/gfx_svg_arcs.ppm"
APNG="$OUT/gfx_svg_arcs.png"
"$PROBE" "$FARC" --ppm "$APPM" 6 >/dev/null 2>&1
if python3 scripts/ppm_to_png.py "$APPM" "$APNG" 2>"$OUT/svg_arcs_png.log"; then
    echo "[hb-svg] PASS rendered $APNG ($(file -b "$APNG" 2>/dev/null))"
else
    echo "[hb-svg] FAIL arcs png conversion"; cat "$OUT/svg_arcs_png.log"; fail=1
fi

# ---- full browser render: layout + blit ----
FIX="tests/fixtures/hambrowse_svg.html"
BDUMP2="$OUT/svg_dump.txt"
PPM="$OUT/gfx_svg.ppm"
PNG="$OUT/gfx_svg.png"

echo "[hb-svg] rendering $FIX (pass 1: geometry) ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$BDUMP2" 2>&1; then
    echo "[hb-svg] FAIL: render exited non-zero"; cat "$BDUMP2"; exit 1
fi

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$BDUMP2"; then
        echo "[hb-svg] PASS $msg"
    else
        echo "[hb-svg] FAIL $msg (missing: $pat)"; fail=1
    fi
}
assert_grep '^IMGDEC "hambrowse_svg_shapes.svg" 0 48 32' \
    "shapes SVG decodes to natural 48x32 in the browser"
assert_grep '^IMGDEC "hambrowse_svg_logo.svg" 0 64 64' \
    "logo SVG decodes to natural 64x64 in the browser"
assert_grep '^IMGDEC "hambrowse_svg_bad.svg" -1' \
    "malformed SVG fails to decode (drives the placeholder)"
assert_grep '^IMGSEG slot 0 w 48 h 32 ' \
    "shapes <img> reserves its natural 48x32 box (slot 0)"
assert_grep '^IMGSEG slot 1 w 64 h 64 ' \
    "logo <img> reserves its natural 64x64 box (slot 1)"
assert_grep '^IMGSEG slot -2 ' \
    "malformed src -> placeholder box (slot -2), no crash"

# ---- pixel-colour assertions inside the blitted shapes box (EXACT) ----
read PX PTOP < <(awk '/^IMGSEG slot 0 w 48 /{print $9, $11; exit}' "$BDUMP2")
if [ -z "${PX:-}" ] || [ -z "${PTOP:-}" ]; then
    echo "[hb-svg] FAIL could not read shapes image box geometry"; fail=1
else
    RX=$((PX + 12));  RY=$((PTOP + 8))    # red   rect
    GX=$((PX + 36));  GY=$((PTOP + 8))    # green circle
    BX=$((PX + 12));  BY=$((PTOP + 26))   # blue  triangle
    OX=$((PX + 36));  OY=$((PTOP + 24))   # orange diamond
    SDUMP="$OUT/svg_samples.txt"
    echo "[hb-svg] rendering (pass 2: pixel samples) ..."
    "$BIN" "$FIX" "$PPM" 640 "$RX" "$RY" "$GX" "$GY" "$BX" "$BY" "$OX" "$OY" \
        >"$SDUMP" 2>&1
    assert_pix() {
        local x="$1" y="$2" want="$3" msg="$4" hexline hex
        hexline=$(grep -E "^PIX $x $y #" "$SDUMP" | head -1)
        if [ -z "$hexline" ]; then
            echo "[hb-svg] FAIL $msg: no sample at $x,$y"; fail=1; return
        fi
        hex=${hexline##*#}
        if [ "$hex" = "$want" ]; then
            echo "[hb-svg] PASS $msg (#$hex at $x,$y)"
        else
            echo "[hb-svg] FAIL $msg (#$hex want #$want at $x,$y)"; fail=1
        fi
    }
    assert_pix "$RX" "$RY" dc2828 "red rect blitted (exact)"
    assert_pix "$GX" "$GY" 28c83c "green circle blitted (exact)"
    assert_pix "$BX" "$BY" 325adc "blue triangle blitted (exact)"
    assert_pix "$OX" "$OY" ffa500 "orange diamond blitted (exact)"
fi

# Render the PPM to a PNG for eyeballing.
if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/svg_png.log"; then
    echo "[hb-svg] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-svg] FAIL png conversion"; cat "$OUT/svg_png.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-svg] PASS"
else
    echo "[hb-svg] FAIL"; exit 1
fi
