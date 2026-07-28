#!/usr/bin/env bash
# scripts/test_hamview_zoom_host.sh — FAST, QEMU-free host gate for the two
# hamview (user/hamview.ad) fixes:
#
#   BUG 1  scroll-wheel zoom: the viewer scales the image up/down on a mouse-
#          wheel notch. Verified end-to-end by user/hamview_zoom_host.ad, which
#          runs the SAME lib/imgscale fit/zoom/blit math hamview uses and
#          renders the image at 100% and 200% into two PPMs (converted to PNGs
#          to eyeball). ASSERT: the 200% frame's image is strictly wider than
#          the 100% frame's (the scale factor actually changed), and the
#          decoded raster's colour is present in BOTH frames (not blank).
#
#   BUG 2  "always stays on top": hamview must request a NORMAL app-band
#          window, not a topmost/float one. ASSERT: hamview.ad's window `z`
#          write is in the normal app band (< 10, like its peers) and it emits
#          NO topmost/ontop/float/above stacking verb.
#
# Plus: NATIVE hamview + native harness still COMPILE for x86_64-adder-user /
# x86_64-linux respectively. All in milliseconds, no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamview_zoom_host"
mkdir -p "$OUT"
fail=0

# -------------------------------------------------------------------------
# BUG 2: static assertion — hamview requests a NORMAL (not topmost) window.
# -------------------------------------------------------------------------
echo "[hamview-zoom] checking hamview requests a NORMAL (not topmost) window ..."
# The z verb hamview writes to its /dev/wsys/<wid>/ctl. Extract the integer.
ZLINE=$(grep -oE '_wctl\("z [0-9]+\\n"\)' user/hamview.ad | head -1)
ZVAL=$(echo "$ZLINE" | grep -oE '[0-9]+' | head -1)
if [ -z "$ZVAL" ]; then
    echo "[hamview-zoom] FAIL: could not find hamview's z ctl write"; fail=1
elif [ "$ZVAL" -ge 10 ]; then
    echo "[hamview-zoom] FAIL: hamview z=$ZVAL is above the normal app band (>=10) — always-on-top"; fail=1
else
    echo "[hamview-zoom] PASS hamview requests normal-band z=$ZVAL (participates in z-order)"
fi
# No topmost/override/float/ontop/above stacking verb anywhere in the app.
if grep -qiE 'topmost|override-?redirect|ontop|on-top|"float|"above|always.?top' user/hamview.ad; then
    echo "[hamview-zoom] FAIL: hamview emits a topmost/float/always-on-top verb"; fail=1
else
    echo "[hamview-zoom] PASS hamview emits no topmost/float/always-on-top verb"
fi

# -------------------------------------------------------------------------
# Compile the NATIVE viewer (proves the on-device binary still builds).
# -------------------------------------------------------------------------
echo "[hamview-zoom] compiling NATIVE hamview for x86_64-adder-user ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-adder-user user/hamview.ad "$OUT/hamview_native.elf" 2>"$OUT/hamview_native.log"; then
    echo "[hamview-zoom] FAIL: native hamview did not compile"; cat "$OUT/hamview_native.log"; exit 1
fi
echo "[hamview-zoom] PASS native hamview compiled"

# -------------------------------------------------------------------------
# Compile the host zoom harness.
# -------------------------------------------------------------------------
echo "[hamview-zoom] compiling host zoom harness for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hamview_zoom_host.ad "$BIN" 2>"$OUT/hamview_zoom_compile.log"; then
    echo "[hamview-zoom] FAIL: host harness did not compile"; cat "$OUT/hamview_zoom_compile.log"; exit 1
fi
echo "[hamview-zoom] PASS host harness compiled -> $BIN"

# -------------------------------------------------------------------------
# Generate a deterministic test PNG (green/blue checker, red border) and run.
# -------------------------------------------------------------------------
echo "[hamview-zoom] generating test PNG ..."
python3 - "$OUT/hv_zoom_src.ppm" <<'PY'
import sys
w,h=200,150
data=bytearray()
for y in range(h):
    for x in range(w):
        if x<4 or y<4 or x>=w-4 or y>=h-4: data+=bytes((230,40,40))
        elif (x//20+y//20)%2==0:           data+=bytes((0,200,0))
        else:                              data+=bytes((40,80,210))
open(sys.argv[1],"wb").write(f"P6\n{w} {h}\n255\n".encode()+bytes(data))
PY
if ! python3 scripts/ppm_to_png.py "$OUT/hv_zoom_src.ppm" "$OUT/hv_zoom_src.png" 2>"$OUT/hv_zoom_png.log"; then
    echo "[hamview-zoom] FAIL: could not build test PNG"; cat "$OUT/hv_zoom_png.log"; exit 1
fi

echo "[hamview-zoom] running host zoom harness ..."
DUMP="$OUT/hv_zoom_dump.txt"
if ! "$BIN" "$OUT/hv_zoom_src.png" "$OUT/hv_zoom_100.ppm" "$OUT/hv_zoom_200.ppm" >"$DUMP" 2>&1; then
    echo "[hamview-zoom] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

# Convert both frames to PNG for eyeballing.
for z in 100 200; do
    if [ -s "$OUT/hv_zoom_$z.ppm" ]; then
        python3 scripts/ppm_to_png.py "$OUT/hv_zoom_$z.ppm" "$OUT/hv_zoom_$z.png" 2>/dev/null || true
    fi
done

# -------------------------------------------------------------------------
# BUG 1: assert the scale factor changed + the image is visible at both zooms.
# -------------------------------------------------------------------------
if grep -q 'ZOOM OK' "$DUMP"; then
    echo "[hamview-zoom] PASS scroll-wheel zoom scales the image (200% wider than 100%)"
else
    echo "[hamview-zoom] FAIL zoom did not change the scale factor"; fail=1
fi

# Pixel proof: the fixture's GREEN (0,200,0) must be present in BOTH frames
# (the decoded raster is on screen at each zoom, not a blank canvas).
pixcount() {  # $1 ppm  $2,$3,$4 rgb
    python3 - "$@" <<'PYPIX'
import sys
ppm, tr, tg, tb = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
data = open(ppm, "rb").read()
if not data.startswith(b"P6"):
    print(0); sys.exit(0)
idx = 2; fields = []
while len(fields) < 3 and idx < len(data):
    while idx < len(data) and data[idx:idx+1].isspace(): idx += 1
    s = idx
    while idx < len(data) and not data[idx:idx+1].isspace(): idx += 1
    fields.append(int(data[s:idx]))
idx += 1
pix = data[idx:]; TOL = 55; hits = 0; i = 0; n = (len(pix)//3)*3
while i < n:
    if abs(pix[i]-tr)<=TOL and abs(pix[i+1]-tg)<=TOL and abs(pix[i+2]-tb)<=TOL: hits += 1
    i += 3
print(hits)
PYPIX
}
for z in 100 200; do
    if [ -s "$OUT/hv_zoom_$z.ppm" ]; then
        G=$(pixcount "$OUT/hv_zoom_$z.ppm" 0 200 0)
        echo "[hamview-zoom] zoom $z% green pixels: ${G:-0}"
        if [ "${G:-0}" -ge 400 ]; then
            echo "[hamview-zoom] PASS image visible at $z% zoom"
        else
            echo "[hamview-zoom] FAIL image not visible at $z% zoom (green=${G:-0})"; fail=1
        fi
    else
        echo "[hamview-zoom] FAIL no $z% frame captured"; fail=1
    fi
done

# The 200% frame should carry MORE green than the 100% frame (bigger image).
G100=$(pixcount "$OUT/hv_zoom_100.ppm" 0 200 0)
G200=$(pixcount "$OUT/hv_zoom_200.ppm" 0 200 0)
if [ "${G200:-0}" -gt "${G100:-0}" ]; then
    echo "[hamview-zoom] PASS 200% frame has more image pixels than 100% ($G200 > $G100)"
else
    echo "[hamview-zoom] FAIL 200% frame not larger than 100% ($G200 vs $G100)"; fail=1
fi

echo "[hamview-zoom] artifacts in $OUT (hv_zoom_100.png / hv_zoom_200.png)"
if [ "$fail" -eq 0 ]; then
    echo "[hamview-zoom] RESULT: PASS"
    exit 0
else
    echo "[hamview-zoom] RESULT: FAIL"
    exit 1
fi
