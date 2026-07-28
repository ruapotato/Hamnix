#!/usr/bin/env bash
# scripts/test_hambrowse_objectfit_host.sh — FAST, QEMU-free gate for CSS
# REPLACED-ELEMENT sizing in the native browser engine (lib/web/css/cascade.ad +
# lib/web/layout/box.ad + lib/htmlpaint.ad + lib/htmlpage.ad):
#
#   object-fit:       fill | contain | cover | none | scale-down
#   object-position:  left/right/top/bottom/center | <%> | <px>
#   aspect-ratio:     <w> / <h>   (or a single number)
#   text-overflow:    ellipsis    (single-line overflow:hidden;white-space:nowrap)
#
# Before this, an <img> always stretched-to-fill its box, blocks had no
# aspect-ratio, and only clip/ellipsis truncation existed. The cascade now parses
# object-fit/object-position/aspect-ratio; _handle_img resolves the img cascade
# (a void element) and stores per-segment fit+position; htmlpaint_blit_image_fit
# sizes+positions the bitmap (letterbox for contain, crop for cover); and
# _block_box_open derives a definite-width box's height from aspect-ratio.
#
# The fixture uses a 40x20 (2:1) GREEN-left/RED-right PNG in four <img> boxes
# (cover/contain/none:left/none:right), a width:200 + aspect-ratio:2/1 block, and
# a narrow ellipsis block. The probe reads the rendered PIXELS + geometry dump
# and asserts crop-vs-letterbox, object-position halves, the ~100px aspect box
# height, and the trailing "..." ellipsis.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_objectfit.html"
PNGF="tests/fixtures/hb_objfit.png"
mkdir -p "$OUT"
fail=0

# Regenerate the checked-in test PNG deterministically (idempotent): 40x20,
# left half GREEN, right half RED.
python3 - "$PNGF" <<'PY'
import sys, zlib, struct
W, H = 40, 20
def chunk(t, d):
    return (struct.pack(">I", len(d)) + t + d +
            struct.pack(">I", zlib.crc32(t + d) & 0xffffffff))
raw = bytearray()
for y in range(H):
    raw.append(0)
    for x in range(W):
        if x < W // 2:
            raw += bytes((0, 200, 0, 255))       # green left half
        else:
            raw += bytes((220, 0, 0, 255))       # red right half
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
png += chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY

echo "[hb-objfit] compiling text harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/objfit_compile.log"; then
    echo "[hb-objfit] FAIL: host harness did not compile"; cat "$OUT/objfit_compile.log"; exit 1
fi
echo "[hb-objfit] PASS text harness compiled -> $BIN"

echo "[hb-objfit] compiling pixel backend for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/objfit_gfx.log"; then
    echo "[hb-objfit] FAIL: pixel backend did not compile"; cat "$OUT/objfit_gfx.log"; exit 1
fi
echo "[hb-objfit] PASS pixel backend compiled -> $GFX"

echo "[hb-objfit] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/objfit_native.log"; then
    echo "[hb-objfit] FAIL: native hambrowse did not compile"; cat "$OUT/objfit_native.log"; exit 1
fi
echo "[hb-objfit] PASS native hambrowse still compiles"

# pixel path: render to PPM+PNG, then assert the sizing/placement geometry.
PPM="$OUT/objfit.ppm"; PNG="$OUT/objfit.png"; GD="$OUT/objfit_gfx_dump.txt"
if "$GFX" "$FIX" "$PPM" 800 >"$GD" 2>&1; then
    if ! grep -q '^IMGDEC "hb_objfit.png" 0' "$GD"; then
        echo "[hb-objfit] FAIL: fixture image did not decode"; head "$GD"; fail=1
    fi
    if python3 scripts/hb_objectfit_probe.py "$GD" "$PPM"; then
        echo "[hb-objfit] PASS sizing pixel assertions (cover/contain/object-position/aspect-ratio/ellipsis)"
    else
        echo "[hb-objfit] FAIL sizing pixel assertions"; fail=1
    fi
    if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/objfit_png.log"; then
        echo "[hb-objfit] PASS pixel render -> $PNG ($(file -b "$PNG" 2>/dev/null))"
    else
        echo "[hb-objfit] FAIL png conversion"; cat "$OUT/objfit_png.log"; fail=1
    fi
else
    echo "[hb-objfit] FAIL: pixel render exited non-zero"; cat "$GD"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-objfit] RESULT: FAIL"; exit 1; fi
echo "[hb-objfit] RESULT: PASS"
