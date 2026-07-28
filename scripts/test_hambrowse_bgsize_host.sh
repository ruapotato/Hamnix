#!/usr/bin/env bash
# scripts/test_hambrowse_bgsize_host.sh — FAST, QEMU-free gate for CSS
# background IMAGE PLACEMENT in the native browser engine (lib/web/css/cascade.ad
# + lib/htmlpaint.ad + lib/htmlpage.ad):
#
#   background-size:     cover | contain | <w> [<h>] | auto
#   background-position: left/center/right top/center/bottom | <x>% <y>% | <x>px..
#   background-repeat:   repeat | no-repeat | repeat-x | repeat-y
#
# Before this, a background-image: url() always scaled-to-fill with no way to
# size, position or tile it. The cascade now parses these three properties into
# per-image placement state and htmlpaint_blit_image_bg honours size -> position
# -> repeat (computing the tile size + origin, then tiling/clipping inside the
# padding box, respecting border-radius).
#
# The fixture references a wide (2:1) SOLID-RED PNG both as an <img> (so the host
# harness decodes it into the shared image store) and as four div backgrounds:
# cover / contain+no-repeat / no-repeat+center / repeat-x. The probe reads the
# rendered PIXELS and asserts the red-vs-white(page-bg) placement geometry.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_bgsize.html"
PNGF="tests/fixtures/hb_bgsize_red.png"
mkdir -p "$OUT"
fail=0

# Regenerate the checked-in red PNG deterministically (idempotent) so the gate is
# self-contained and cannot silently drift from the committed fixture.
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
        raw += bytes((255, 0, 0, 255))
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
png += chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY

echo "[hb-bgsz] compiling text harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/bgsz_compile.log"; then
    echo "[hb-bgsz] FAIL: host harness did not compile"; cat "$OUT/bgsz_compile.log"; exit 1
fi
echo "[hb-bgsz] PASS text harness compiled -> $BIN"

echo "[hb-bgsz] compiling pixel backend for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/bgsz_gfx.log"; then
    echo "[hb-bgsz] FAIL: pixel backend did not compile"; cat "$OUT/bgsz_gfx.log"; exit 1
fi
echo "[hb-bgsz] PASS pixel backend compiled -> $GFX"

echo "[hb-bgsz] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/bgsz_native.log"; then
    echo "[hb-bgsz] FAIL: native hambrowse did not compile"; cat "$OUT/bgsz_native.log"; exit 1
fi
echo "[hb-bgsz] PASS native hambrowse still compiles"

# pixel path: render to PPM+PNG, then assert the placement geometry.
PPM="$OUT/bgsize.ppm"; PNG="$OUT/bgsize.png"; GD="$OUT/bgsize_gfx_dump.txt"
if "$GFX" "$FIX" "$PPM" 800 >"$GD" 2>&1; then
    if ! grep -q '^IMGDEC "hb_bgsize_red.png" 0' "$GD"; then
        echo "[hb-bgsz] FAIL: fixture image did not decode"; cat "$GD" | head; fail=1
    fi
    if python3 scripts/hb_bgsize_probe.py "$GD" "$PPM"; then
        echo "[hb-bgsz] PASS placement pixel assertions (cover/contain/center/repeat-x)"
    else
        echo "[hb-bgsz] FAIL placement pixel assertions"; fail=1
    fi
    if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/bgsz_png.log"; then
        echo "[hb-bgsz] PASS pixel render -> $PNG ($(file -b "$PNG" 2>/dev/null))"
    else
        echo "[hb-bgsz] FAIL png conversion"; cat "$OUT/bgsz_png.log"; fail=1
    fi
else
    echo "[hb-bgsz] FAIL: pixel render exited non-zero"; cat "$GD"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-bgsz] RESULT: FAIL"; exit 1; fi
echo "[hb-bgsz] RESULT: PASS"
