#!/usr/bin/env bash
# scripts/test_hamimg_host.sh — FAST, QEMU-free host gate for the #128 scene
# IMAGE tier: a REAL PNG is decoded (lib/png.ad), registered as a named image,
# referenced from a scene display list via lib/hamscene.ad's `hamscene_image`
# (`image x y w h NAME` verb), and rasterized by lib/hamui_host.ad — the same
# `image` verb + blit path the in-kernel compositor (sys/src/9/port/devwsys.ad)
# runs on a native boot. It renders to a PNG a human/agent can LOOK at and
# asserts REAL image pixels landed (not a placeholder), then confirms the
# NATIVE demo app + kernel-facing pieces still compile for x86_64-adder-user.
# All in milliseconds, no QEMU. PNG conversion uses scripts/ppm_to_png.py
# (Python stdlib zlib only).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamimg_host"
mkdir -p "$OUT"
fail=0

echo "[hamimg-host] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamimgscene_host.ad "$BIN" 2>"$OUT/hamimg_compile.log"; then
    echo "[hamimg-host] FAIL: host harness did not compile"; cat "$OUT/hamimg_compile.log"; exit 1
fi
echo "[hamimg-host] PASS host harness compiled -> $BIN"

echo "[hamimg-host] compiling NATIVE hamimgscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamimgscene.ad "$OUT/hamimgscene_native.elf" 2>"$OUT/hamimg_native.log"; then
    echo "[hamimg-host] FAIL: native hamimgscene did not compile"; cat "$OUT/hamimg_native.log"; exit 1
fi
echo "[hamimg-host] PASS native hamimgscene still compiles"

# Generate a deterministic 24x24 test PNG (red border / green diagonal / blue
# field) via a PPM + the stdlib-only PPM->PNG converter — no image tools.
echo "[hamimg-host] generating test PNG ..."
python3 - "$OUT/test_logo.ppm" <<'PY'
import sys
w=h=24
data=bytearray()
for y in range(h):
    for x in range(w):
        if x<2 or y<2 or x>=w-2 or y>=h-2: data+=bytes((230,40,40))
        elif abs(x-y)<=1:                  data+=bytes((40,210,60))
        else:                              data+=bytes((40,80,210))
open(sys.argv[1],"wb").write(f"P6\n{w} {h}\n255\n".encode()+bytes(data))
PY
if ! python3 scripts/ppm_to_png.py "$OUT/test_logo.ppm" "$OUT/test_logo.png" 2>"$OUT/hamimg_png.log"; then
    echo "[hamimg-host] FAIL: could not build test PNG"; cat "$OUT/hamimg_png.log"; exit 1
fi
echo "[hamimg-host] PASS test PNG built ($(file -b "$OUT/test_logo.png" 2>/dev/null))"

echo "[hamimg-host] running host harness ..."
DUMP="$OUT/hamimg_dump.txt"
if ! "$BIN" "$OUT/test_logo.png" "$OUT/hamimg_out.ppm" >"$DUMP" 2>&1; then
    echo "[hamimg-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

# Render the framebuffer PPM to a PNG for eyeballing.
if python3 scripts/ppm_to_png.py "$OUT/hamimg_out.ppm" "$OUT/hamimg_out.png" 2>>"$OUT/hamimg_png.log"; then
    echo "[hamimg-host] PASS rendered $OUT/hamimg_out.png ($(file -b "$OUT/hamimg_out.png" 2>/dev/null))"
else
    echo "[hamimg-host] FAIL png conversion"; cat "$OUT/hamimg_png.log"; fail=1
fi

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hamimg-host] PASS $msg"
    else
        echo "[hamimg-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- decode + protocol ---------------------------------------------------
assert_grep '^PNG 24x24'                        "PNG decoded (24x24) via lib/png.ad"
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^image 20 40 24 24 logo'           "natural-size image verb references the named image"
assert_grep '^image 200 40 128 128 logo'        "scaled image verb (128x128) emitted"
assert_grep '^PRIMS [1-9]'                       "rasterizer drew the scene primitives"

# --- REAL image pixels landed (not a placeholder / not the backdrop) -----
# Decoded source colours: border (230,40,40)=#e62828, diagonal (40,210,60)=
# #28d23c, field (40,80,210)=#2850d2. The backdrop is #202830.
assert_grep '^PIX 2 2 #202830'                  "backdrop pixel = window fill"
assert_grep '^IMGPIX 0 0 #e62828'               "image top-left = decoded RED border pixel"
assert_grep '^IMGPIX 6 6 #28d23c'               "image (6,6) = decoded GREEN diagonal pixel"
assert_grep '^IMGPIX 12 6 #2850d2'              "image (12,6) = decoded BLUE field pixel"
assert_grep '^SCALEDPIX #(28d23c|2850d2|e62828)' "scaled copy shows a real decoded colour (scaler works)"

if [ "$fail" -ne 0 ]; then
    echo "[hamimg-host] FAIL"
    exit 1
fi
echo "[hamimg-host] method: a real PNG is decoded, blitted through the scene"
echo "[hamimg-host]   \`image\` verb, and asserted pixel-exact in the render — the"
echo "[hamimg-host]   same verb+blit path devwsys.ad runs natively. LOOK: $OUT/hamimg_out.png"
echo "[hamimg-host] PASS"
