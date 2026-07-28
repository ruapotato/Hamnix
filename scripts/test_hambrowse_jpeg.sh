#!/usr/bin/env bash
# scripts/test_hambrowse_jpeg.sh — FAST, QEMU-free gate for baseline JPEG <img>
# support in the native browser (task: "the web is mostly JPEG").
#
# lib/jpeg.ad is a from-scratch, pure-Adder, INTEGER-ONLY baseline JPEG decoder
# (SOI/APP0/DQT/SOF0/DHT/DRI/SOS marker walk + canonical Huffman entropy decode +
# dequant/de-zigzag + a fixed-point separable 8x8 inverse DCT + chroma upsampling
# + integer YCbCr->RGB). The two hambrowse decode call sites dispatch by magic
# (PNG signature 89 50 -> png_decode, JPEG SOI FF D8 -> jpeg_decode) and feed the
# resulting RGBA into lib/htmlimg.ad exactly like PNG, so <img src="photo.jpg">
# decodes + blits at natural size.
#
# This gate renders tests/fixtures/hambrowse_jpeg.html — which references three
# checked-in JPEGs (a 48x32 quadrant photo in 4:4:4 and in 4:2:0 subsampling, and
# a PROGRESSIVE JPEG that must fail cleanly to the placeholder) — and asserts:
#   * baseline 4:4:4 and 4:2:0 both decode to their true 48x32 dimensions;
#   * the KNOWN quadrant colours (red/green/blue/white) land inside the blitted
#     box within a small lossy tolerance (JPEG is lossy — NOT an exact match);
#   * a progressive JPEG reports rc<0 and draws the grey placeholder, no crash.
# It also runs lib/jpeg.ad's standalone probe for direct per-pixel accuracy, and
# renders build/host/gfx_jpeg.png for eyeballing.
#
# Built with the frozen Python seed compiler (no self-host bootstrap). PPM->PNG
# uses scripts/ppm_to_png.py (stdlib only). Fixtures are checked in; if Pillow is
# present they are regenerated to guard against silent drift.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
PROBE="$OUT/jpeg_probe"
mkdir -p "$OUT"
fail=0

echo "[hb-jpeg] compiling pixel backend (with JPEG decode) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/jpeg_compile.log"; then
    echo "[hb-jpeg] FAIL: driver did not compile"; cat "$OUT/jpeg_compile.log"; exit 1
fi
echo "[hb-jpeg] PASS pixel backend compiled -> $BIN"

echo "[hb-jpeg] compiling standalone jpeg probe ..."
if ! adder_bin x86_64-linux user/jpeg_probe.ad "$PROBE" 2>"$OUT/jpeg_probe_compile.log"; then
    echo "[hb-jpeg] FAIL: jpeg_probe did not compile"; cat "$OUT/jpeg_probe_compile.log"; exit 1
fi
echo "[hb-jpeg] PASS jpeg probe compiled -> $PROBE"

# Regenerate the checked-in JPEG fixtures IFF Pillow is available (drift guard);
# otherwise fall back to the committed files so the gate is self-contained.
F444="tests/fixtures/hambrowse_jpeg_444.jpg"
F420="tests/fixtures/hambrowse_jpeg_420.jpg"
FPROG="tests/fixtures/hambrowse_jpeg_prog.jpg"
python3 - "$F444" "$F420" "$FPROG" <<'PY' 2>/dev/null || echo "[hb-jpeg] (Pillow absent — using committed JPEG fixtures)"
import sys
try:
    from PIL import Image
except Exception:
    sys.exit(1)
f444, f420, fprog = sys.argv[1], sys.argv[2], sys.argv[3]
w, h = 48, 32
img = Image.new("RGB", (w, h))
px = img.load()
for y in range(h):
    for x in range(w):
        if   x < 24 and y < 16:  px[x, y] = (220, 40, 40)    # red   TL
        elif x >= 24 and y < 16: px[x, y] = (40, 200, 60)    # green TR
        elif x < 24 and y >= 16: px[x, y] = (50, 90, 220)    # blue  BL
        else:                    px[x, y] = (240, 240, 240)  # white BR
img.save(f444, "JPEG", quality=90, subsampling=0)   # 4:4:4
img.save(f420, "JPEG", quality=90, subsampling=2)   # 4:2:0
Image.new("RGB", (w, h), (100, 150, 200)).save(fprog, "JPEG", progressive=True, quality=85)
print("[hb-jpeg] regenerated JPEG fixtures via Pillow")
PY
for f in "$F444" "$F420" "$FPROG"; do
    [ -s "$f" ] || { echo "[hb-jpeg] FAIL: missing fixture $f"; exit 1; }
done
echo "[hb-jpeg] 4:4:4 fixture: $(file -b "$F444" 2>/dev/null)"

# ---- standalone probe: direct per-pixel decode accuracy ----
echo "[hb-jpeg] probe: baseline 4:4:4 decode + quadrant colours ..."
PDUMP="$OUT/jpeg_probe_444.txt"
"$PROBE" "$F444" 12 8 36 8 12 24 36 24 >"$PDUMP" 2>&1

probe_dim() {
    if grep -Eq '^DIM 48 32$' "$PDUMP"; then
        echo "[hb-jpeg] PASS probe decoded to natural 48x32"
    else
        echo "[hb-jpeg] FAIL probe dimensions"; cat "$PDUMP"; fail=1
    fi
}
probe_dim

# tolerance-based pixel check: "PIX x y r g b", each channel within $TOL.
TOL=10
probe_pix() {
    local x="$1" y="$2" er="$3" eg="$4" eb="$5" msg="$6"
    local line
    line=$(grep -E "^PIX $x $y " "$PDUMP" | head -1)
    if [ -z "$line" ]; then
        echo "[hb-jpeg] FAIL $msg: no PIX $x $y"; fail=1; return
    fi
    read -r _ _ _ gr gg gb <<<"$line"
    local dr=$((gr - er)); local dg=$((gg - eg)); local db=$((gb - eb))
    dr=${dr#-}; dg=${dg#-}; db=${db#-}
    if [ "$dr" -le "$TOL" ] && [ "$dg" -le "$TOL" ] && [ "$db" -le "$TOL" ]; then
        echo "[hb-jpeg] PASS $msg (got $gr,$gg,$gb vs $er,$eg,$eb, <=$TOL)"
    else
        echo "[hb-jpeg] FAIL $msg (got $gr,$gg,$gb vs $er,$eg,$eb, >$TOL)"; fail=1
    fi
}
probe_pix 12 8  220 40 40  "red quadrant decodes"
probe_pix 36 8  40 200 60  "green quadrant decodes"
probe_pix 12 24 50 90 220  "blue quadrant decodes"
probe_pix 36 24 240 240 240 "white quadrant decodes"

echo "[hb-jpeg] probe: 4:2:0 subsampling decodes ..."
"$PROBE" "$F420" 12 8 >"$OUT/jpeg_probe_420.txt" 2>&1
if grep -Eq '^DIM 48 32$' "$OUT/jpeg_probe_420.txt"; then
    echo "[hb-jpeg] PASS 4:2:0 decoded to 48x32"
else
    echo "[hb-jpeg] FAIL 4:2:0 decode"; cat "$OUT/jpeg_probe_420.txt"; fail=1
fi

echo "[hb-jpeg] probe: progressive JPEG fails cleanly (rc<0, no crash) ..."
"$PROBE" "$FPROG" 0 0 >"$OUT/jpeg_probe_prog.txt" 2>&1
if grep -Eq '^RC -[0-9]' "$OUT/jpeg_probe_prog.txt"; then
    echo "[hb-jpeg] PASS progressive JPEG rejected (rc<0)"
else
    echo "[hb-jpeg] FAIL progressive JPEG not rejected"; cat "$OUT/jpeg_probe_prog.txt"; fail=1
fi

# ---- full browser render: layout + blit ----
FIX="tests/fixtures/hambrowse_jpeg.html"
DUMP="$OUT/jpeg_dump.txt"
PPM="$OUT/gfx_jpeg.ppm"
PNG="$OUT/gfx_jpeg.png"

echo "[hb-jpeg] rendering $FIX (pass 1: geometry) ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-jpeg] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-jpeg] PASS $msg"
    else
        echo "[hb-jpeg] FAIL $msg (missing: $pat)"; fail=1
    fi
}
assert_grep '^IMGDEC "hambrowse_jpeg_444.jpg" 0 48 32' \
    "baseline 4:4:4 JPEG decodes to natural 48x32 in the browser"
assert_grep '^IMGDEC "hambrowse_jpeg_420.jpg" 0 48 32' \
    "baseline 4:2:0 JPEG decodes to natural 48x32 in the browser"
assert_grep '^IMGDEC "hambrowse_jpeg_prog.jpg" -1' \
    "progressive JPEG fails to decode (drives the placeholder)"
assert_grep '^IMGSEG slot 0 w 48 h 32 ' \
    "4:4:4 <img> reserves its natural 48x32 box (slot 0)"
assert_grep '^IMGSEG slot 1 w 48 h 32 ' \
    "4:2:0 <img> reserves its natural 48x32 box (slot 1)"
assert_grep '^IMGSEG slot -2 ' \
    "progressive src -> placeholder box (slot -2), no crash"

# ---- pixel-colour assertions inside the blitted 4:4:4 box (tolerant) ----
read IMGX IMGTOP < <(awk '/^IMGSEG slot 0 w 48 /{print $9, $11; exit}' "$DUMP")
if [ -z "${IMGX:-}" ] || [ -z "${IMGTOP:-}" ]; then
    echo "[hb-jpeg] FAIL could not read image box geometry"; fail=1
else
    RX=$((IMGX + 12));  RY=$((IMGTOP + 8))    # red   TL
    GX=$((IMGX + 36));  GY=$((IMGTOP + 8))    # green TR
    BX=$((IMGX + 12));  BY=$((IMGTOP + 24))   # blue  BL
    KX=$((IMGX + 36));  KY=$((IMGTOP + 24))   # white BR
    SDUMP="$OUT/jpeg_samples.txt"
    echo "[hb-jpeg] rendering (pass 2: pixel samples) ..."
    "$BIN" "$FIX" "$PPM" 640 "$RX" "$RY" "$GX" "$GY" "$BX" "$BY" "$KX" "$KY" \
        >"$SDUMP" 2>&1

    # "PIX x y #rrggbb" — parse hex, compare each channel within tolerance.
    assert_pix_tol() {
        local x="$1" y="$2" er="$3" eg="$4" eb="$5" msg="$6"
        local hexline hex gr gg gb dr dg db
        hexline=$(grep -E "^PIX $x $y #" "$SDUMP" | head -1)
        if [ -z "$hexline" ]; then
            echo "[hb-jpeg] FAIL $msg: no sample at $x,$y"; fail=1; return
        fi
        hex=${hexline##*#}
        gr=$((16#${hex:0:2})); gg=$((16#${hex:2:2})); gb=$((16#${hex:4:2}))
        dr=$((gr - er)); dg=$((gg - eg)); db=$((gb - eb))
        dr=${dr#-}; dg=${dg#-}; db=${db#-}
        if [ "$dr" -le "$TOL" ] && [ "$dg" -le "$TOL" ] && [ "$db" -le "$TOL" ]; then
            echo "[hb-jpeg] PASS $msg (#$hex ~ $er,$eg,$eb at $x,$y)"
        else
            echo "[hb-jpeg] FAIL $msg (#$hex vs $er,$eg,$eb at $x,$y, >$TOL)"; fail=1
        fi
    }
    assert_pix_tol "$RX" "$RY" 220 40 40   "red quadrant blitted"
    assert_pix_tol "$GX" "$GY" 40 200 60   "green quadrant blitted"
    assert_pix_tol "$BX" "$BY" 50 90 220   "blue quadrant blitted"
    assert_pix_tol "$KX" "$KY" 240 240 240 "white quadrant blitted"
fi

# Render the PPM to a PNG for eyeballing.
if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/jpeg_png.log"; then
    echo "[hb-jpeg] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-jpeg] FAIL png conversion"; cat "$OUT/jpeg_png.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-jpeg] PASS"
else
    echo "[hb-jpeg] FAIL"; exit 1
fi
