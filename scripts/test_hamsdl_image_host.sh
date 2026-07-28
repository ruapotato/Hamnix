#!/usr/bin/env bash
# scripts/test_hamsdl_image_host.sh — FAST, QEMU-free host gate for the hamSDL/
# hamGame IMAGE LOADER (the pygame.image.load gap: hamSDL could draw registered
# images but had no way to DECODE a sprite file into a Surface).
#
# It adds a pure-Adder BMP decoder (lib/bmp.ad) wired through hamGame's
# game_load_bmp / game_load_image (format sniff) and the host file loader
# game_host_load_image (lib/hamgame_host.ad, pygame.image.load's path form).
# The gate GENERATES two tiny BMP fixtures (a 24-bit coordinate-coded sprite and
# a 32-bit sprite with per-pixel alpha), loads them off disk, blits them onto a
# red display Surface, rasterizes to a PPM/PNG a human/agent can LOOK at, and
# asserts UNFORGEABLE pixels: correct channel order (BGR->RGB), correct bottom-up
# row order, and honoured 32-bit alpha (source-over blend over the background) —
# both straight off the decoded Surface AND after the raster. It also recompiles
# the NATIVE x86_64-adder-user build so the dual-target seam can't rot. All in
# milliseconds, no QEMU.
#
# Built with the frozen Python seed compiler. PNG conversion uses
# scripts/ppm_to_png.py (Python stdlib zlib only).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsdl_image_host"
FIX24="$OUT/hamsdl_fix24.bmp"
FIX32="$OUT/hamsdl_fix32.bmp"
PPM="$OUT/hamsdl_image.ppm"
PNG="$OUT/hamsdl_image.png"
DUMP="$OUT/hamsdl_image_dump.txt"
mkdir -p "$OUT"
fail=0

# ---- 1. Generate the BMP fixtures (raw bytes, Python stdlib only) --------
python3 - "$FIX24" "$FIX32" <<'PY'
import struct, sys

def bmp_file(width, height, bitcount, pixel_bgra):
    # pixel_bgra(x, y) -> (B, G, R, A); y=0 is the TOP row.
    bpp = bitcount // 8
    row_bytes = width * bpp
    stride = (row_bytes + 3) & ~3
    pad = stride - row_bytes
    rows = bytearray()
    # BMP is bottom-up: write image bottom row first.
    for fy in range(height):
        y = height - 1 - fy
        for x in range(width):
            b, g, r, a = pixel_bgra(x, y)
            if bpp == 4:
                rows += bytes((b, g, r, a))
            else:
                rows += bytes((b, g, r))
        rows += b'\x00' * pad
    offbits = 14 + 40
    filesize = offbits + len(rows)
    fh = b'BM' + struct.pack('<IHHI', filesize, 0, 0, offbits)
    ih = struct.pack('<IiiHHIIiiII', 40, width, height, 1, bitcount,
                     0, len(rows), 2835, 2835, 0, 0)
    return fh + ih + bytes(rows)

# 24-bit: coordinate-coded so a sample nails channel + row order.
#   (x,y) -> R=16+x*24  G=16+y*24  B=200
def px24(x, y):
    r = 16 + x * 24
    g = 16 + y * 24
    return (200, g, r, 255)      # stored B,G,R

# 32-bit: green everywhere; opaque (a=255) for x<4, semi (a=128) for x>=4.
def px32(x, y):
    a = 255 if x < 4 else 128
    return (0, 255, 0, a)        # B,G,R,A

open(sys.argv[1], 'wb').write(bmp_file(8, 8, 24, px24))
open(sys.argv[2], 'wb').write(bmp_file(8, 8, 32, px32))
print("[img-host] generated 24-bit + 32-bit BMP fixtures")
PY
if [ ! -s "$FIX24" ] || [ ! -s "$FIX32" ]; then
    echo "[img-host] FAIL: could not generate BMP fixtures"; exit 1
fi

# ---- 2. Compile the host harness -----------------------------------------
echo "[img-host] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsdl_image_host.ad "$BIN" 2>"$OUT/hamsdl_image_compile.log"; then
    echo "[img-host] FAIL: host harness did not compile"; cat "$OUT/hamsdl_image_compile.log"; exit 1
fi
echo "[img-host] PASS host harness compiled -> $BIN"

# ---- 3. Native dual-target compile (lib/bmp.ad + hamgame on device) ------
echo "[img-host] compiling NATIVE hamgamedemo (exercises lib/bmp + hamgame) ..."
if ! adder_bin x86_64-adder-user user/hamgamedemo.ad "$OUT/hamgamedemo_img_native.elf" 2>"$OUT/hamsdl_image_native.log"; then
    echo "[img-host] FAIL: native build did not compile"; cat "$OUT/hamsdl_image_native.log"; exit 1
fi
echo "[img-host] PASS native build still compiles (device dual-target intact)"

# ---- 4. Run the harness --------------------------------------------------
echo "[img-host] running image-load harness ..."
if ! "$BIN" "$FIX24" "$FIX32" "$PPM" >"$DUMP" 2>&1; then
    echo "[img-host] FAIL: harness exited non-zero"; cat "$DUMP"; exit 1
fi

if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/hamsdl_image_png.log"; then
    echo "[img-host] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[img-host] FAIL png conversion"; cat "$OUT/hamsdl_image_png.log"; fail=1
fi

kv() { awk -v k="$1" '$1==k{print $2}' "$DUMP"; }

assert_eq() {
    local key="$1" want="$2" msg="$3" got
    got="$(kv "$key")"
    if [ "$got" = "$want" ]; then
        echo "[img-host] PASS $msg ($key=$got)"
    else
        echo "[img-host] FAIL $msg ($key: want $want, got '$got')"; fail=1
    fi
}

# --- Surface decode: dimensions + channel order + bottom-up row order ------
assert_eq S24  0        "24-bit BMP loaded into a Surface"
assert_eq S24W 8        "24-bit sprite width decoded"
assert_eq S24H 8        "24-bit sprite height decoded"
# TL=(0,0) R16 G16 B200 ; TR=(7,0) R184 ; BL=(0,7) G184 -> proves channel+rows.
assert_eq S24_TL "#1010c8ff" "24-bit top-left pixel (channel order R!=B, top row)"
assert_eq S24_TR "#b810c8ff" "24-bit top-right pixel (R tracks x, not B)"
assert_eq S24_BL "#10b8c8ff" "24-bit bottom-left pixel (bottom-up row order)"

# --- 32-bit per-pixel alpha decoded straight off the Surface ---------------
assert_eq S32 1              "32-bit BMP loaded into a second Surface"
assert_eq S32_OPAQUE "#00ff00ff" "32-bit opaque-half pixel (alpha=255 decoded)"
assert_eq S32_ALPHA  "#00ff0080" "32-bit alpha-half pixel (alpha=128 decoded)"

# --- Rasterized framebuffer: blit -> present -> PNG is byte-correct ---------
assert_eq PRIMS 1            "frame rasterized one image primitive"
assert_eq FB_BG      "#ff0000" "background stays pure red where unblitted"
assert_eq FB_S24_TL  "#1010c8" "24-bit sprite blitted at its offset (top-left)"
assert_eq FB_S24_TR  "#b810c8" "24-bit sprite blitted (top-right)"
assert_eq FB_S24_BL  "#10b8c8" "24-bit sprite blitted (bottom-left, rows intact)"
assert_eq FB_S32_OPAQUE "#00ff00" "32-bit opaque half blitted as solid green"

# Alpha half: green@128 over red -> ~(126,128,0). Assert the SOURCE-OVER blend
# (green rose, red fell, blue stayed 0) rather than either pure colour.
ABLEND="$(kv FB_S32_ALPHA)"
AR=$((16#${ABLEND:1:2})); AG=$((16#${ABLEND:3:2})); AB=$((16#${ABLEND:5:2}))
if [ "$AR" -ge 110 ] && [ "$AR" -le 142 ] && [ "$AG" -ge 118 ] && [ "$AG" -le 138 ] && [ "$AB" -le 8 ]; then
    echo "[img-host] PASS 32-bit alpha half source-over blended over red ($ABLEND ~ #7e8000)"
else
    echo "[img-host] FAIL 32-bit alpha blend wrong (got $ABLEND, want ~#7e8000)"; fail=1
fi

# --- Non-blank PNG (a healthy count of non-background pixels) ---------------
if python3 - "$PPM" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
assert d[:2]==b'P6'
i=2; vals=[]
while len(vals)<3:
    while i<len(d) and d[i] in b' \t\n\r': i+=1
    if d[i:i+1]==b'#':
        while i<len(d) and d[i] not in b'\n': i+=1
        continue
    s=i
    while i<len(d) and d[i] not in b' \t\n\r': i+=1
    vals.append(int(d[s:i]))
w,h,mx=vals; i+=1; px=d[i:]
bg=(0xff,0x00,0x00); n=0
for k in range(0,len(px)-2,3):
    if abs(px[k]-bg[0])>10 or abs(px[k+1]-bg[1])>10 or abs(px[k+2]-bg[2])>10: n+=1
print("NON-BG-PIXELS",n)
sys.exit(0 if n>=64 else 1)   # two 8x8 sprites = 128 px, well over 64
PY
then
    echo "[img-host] PASS frame is non-blank (both sprites present in the raster)"
else
    echo "[img-host] FAIL frame looks blank"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[img-host] RESULT: PASS"
    exit 0
else
    echo "[img-host] RESULT: FAIL"
    exit 1
fi
