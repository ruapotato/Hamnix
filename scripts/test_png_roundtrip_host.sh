#!/usr/bin/env bash
# scripts/test_png_roundtrip_host.sh — FAST, QEMU-free host gate proving the
# PNG encoder (lib/pngwrite.ad, as used by user/hamshot.ad) and the PNG decoder
# (lib/png.ad, as used by user/hamview.ad) agree byte-for-byte at real desktop
# resolutions.
#
# It compiles tests/test_png_roundtrip_host.ad for the x86_64-linux Adder
# target, then for each resolution encodes a synthetic framebuffer to a PNG in
# memory and decodes it back with the REAL lib/png.ad, asserting every pixel
# round-trips. It ALSO dumps a full-desktop (1024x768) capture and cross-checks
# it with an INDEPENDENT decoder (python PIL + a manual zlib/CRC walk) so the
# result does not merely match our own decoder's bug.
#
# This is the regression guard for task #266 defect #1: a hamshot capture that
# opened as "corrupt image" in hamview because the decoder was capped at
# 512x512 / 256 KiB IDAT — far below a full-desktop framebuffer.
#
# Built with the frozen Python seed compiler (host target).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/test_png_roundtrip_host"
mkdir -p "$OUT"
fail=0

echo "[png-rt] compiling round-trip host driver for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux tests/test_png_roundtrip_host.ad "$BIN" 2>"$OUT/png_rt_compile.log"; then
    echo "[png-rt] FAIL: host driver did not compile"; cat "$OUT/png_rt_compile.log"; exit 1
fi
echo "[png-rt] PASS host driver compiled -> $BIN"

# --- round-trip through lib/png.ad at real desktop resolutions -----------
for dims in "32 16" "160 100" "500 400" "512 512" "1024 768" "1280 800" "1920 1080"; do
    if "$BIN" $dims >/dev/null 2>&1; then
        echo "[png-rt] PASS decoder round-trip ${dims// /x}"
    else
        echo "[png-rt] FAIL decoder round-trip ${dims// /x}"; fail=1
    fi
done

# --- independent standard-tool cross-check on a full-desktop capture ------
PNG="$OUT/png_rt_desk.png"
if ! "$BIN" 1024 768 "$PNG" >/dev/null 2>&1; then
    echo "[png-rt] FAIL: could not produce 1024x768 capture for cross-check"; fail=1
fi
if command -v python3 >/dev/null 2>&1 && [ -s "$PNG" ]; then
    if python3 - "$PNG" <<'PY'
import sys, struct, zlib
p = sys.argv[1]
d = open(p, "rb").read()
assert d[:8] == bytes([137,80,78,71,13,10,26,10]), "bad signature"
o = 8; bad = 0
while o < len(d):
    ln = struct.unpack('>I', d[o:o+4])[0]; typ = d[o+4:o+8]
    data = d[o+8:o+8+ln]; crc = struct.unpack('>I', d[o+8+ln:o+12+ln])[0]
    if (zlib.crc32(typ+data) & 0xffffffff) != crc:
        bad += 1
    o += 12 + ln
assert bad == 0, f"{bad} chunk(s) with a bad CRC-32"
try:
    from PIL import Image
    im = Image.open(p); im.load()
    assert im.size == (1024, 768) and im.mode == "RGB"
    r = (7*7 + 5*3) & 255; g = (7*3 + 5*11) & 255; b = (7 + 5*5) & 255
    assert im.getpixel((7, 5)) == (r, g, b), "PIL pixel mismatch"
    print("[png-rt] PASS standard-tool cross-check (PIL + zlib CRC)")
except ImportError:
    print("[png-rt] PASS zlib CRC cross-check (PIL absent, skipped)")
PY
    then :; else echo "[png-rt] FAIL: standard-tool cross-check rejected the capture"; fail=1; fi
else
    echo "[png-rt] note: python3 unavailable — skipped independent cross-check"
fi

if [ "$fail" -ne 0 ]; then
    echo "[png-rt] FAIL"; exit 1
fi
echo "[png-rt] PASS"
exit 0
