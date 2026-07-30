#!/usr/bin/env bash
# scripts/test_hambrowse_bgimg_url_host.sh — FAST, QEMU-free gate that a CSS
# `background-image: url(...)` is DECODED AND PAINTED on a page that contains no
# <img> at all.
#
# THE BUG THIS PINS. The host driver learns which images to decode by iterating
# the layout's <img> src registry (he_n_images/he_img_name_ptr) between two
# layout passes. A CSS background url never travels that road: the cascade
# parses it into the gradient/url registry as a gtype==3 entry. So the name was
# never offered to the decoder, htmlimg_find() missed at paint time, and
# lib/htmlpage.ad took its "otherwise leave the box transparent" branch -- the
# box rendered EMPTY and the background-color (or, in a WPT reftest, the
# reference's green) showed through.
#
# WHY A SEPARATE FIXTURE FROM hambrowse_bgsize.html. That older fixture carries
# a dummy `<img src="hb_bgsize_red.png">` whose only purpose is to seed the
# registry so the background url can reuse the decoded image -- i.e. it works
# AROUND this bug and therefore cannot detect it. This fixture deliberately has
# NO <img>, so the registration performed by _eimg_record_p() at background-fill
# emission is the only thing that can make the box red. Do not "simplify" this
# fixture by adding an <img>: that would silently disarm the gate.
#
# The image is a solid-red 2:1 PNG (shared with the bgsize gate, regenerated
# there); the box is 200x100 with background-size:cover on a white page, so the
# assertion is simply "the box interior is RED, the page beside it is WHITE".
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_bgimg_url.html"
PNGF="tests/fixtures/hb_bgsize_red.png"
mkdir -p "$OUT"
fail=0

if [ ! -f "$PNGF" ]; then
    echo "[hb-bgurl] FAIL: fixture image $PNGF missing"; exit 1
fi

echo "[hb-bgurl] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/bgurl_gfx.log"; then
    echo "[hb-bgurl] FAIL: pixel backend did not compile"; cat "$OUT/bgurl_gfx.log"; exit 1
fi
echo "[hb-bgurl] PASS pixel backend compiled -> $GFX"

PPM="$OUT/bgimg_url.ppm"; GD="$OUT/bgimg_url_dump.txt"
if ! "$GFX" "$FIX" "$PPM" 240 >"$GD" 2>&1; then
    echo "[hb-bgurl] FAIL: pixel render exited non-zero"; cat "$GD"; exit 1
fi

# The decode must have been ATTEMPTED at all -- this line is absent entirely on
# the buggy engine, because the name never reached the registry.
if grep -q '^IMGDEC "hb_bgsize_red.png" 0' "$GD"; then
    echo "[hb-bgurl] PASS background url() was registered and decoded"
else
    echo "[hb-bgurl] FAIL: background url() never reached the image registry"
    head -20 "$GD"; fail=1
fi

# ...and it must have been PAINTED. Decoding without blitting would still leave
# a white box, so assert the pixels, not the log line.
if python3 - "$PPM" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
magic, dims, _maxv, px = d.split(b"\n", 3)
w, h = map(int, dims.split())
def at(x, y):
    o = (y * w + x) * 3
    return tuple(px[o:o + 3])
# The .bg div is 200x100 starting a little below the top of the canvas; sample
# well inside it, and well outside it, rather than pinning exact edges.
inside = [(60, 50), (100, 60), (150, 90)]
outside = [(220, 50), (220, 90)]
bad = []
for p in inside:
    c = at(*p)
    if not (c[0] > 200 and c[1] < 60 and c[2] < 60):
        bad.append("inside %s is %s, want RED" % (p, c))
for p in outside:
    c = at(*p)
    if not (c[0] > 200 and c[1] > 200 and c[2] > 200):
        bad.append("outside %s is %s, want WHITE" % (p, c))
for b in bad:
    print("    " + b)
sys.exit(1 if bad else 0)
PY
then
    echo "[hb-bgurl] PASS box interior is the background image (red), page is white"
else
    echo "[hb-bgurl] FAIL: background image did not paint"
    fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-bgurl] RESULT: FAIL"; exit 1; fi
echo "[hb-bgurl] RESULT: PASS"
