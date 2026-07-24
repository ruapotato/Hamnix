#!/usr/bin/env bash
# scripts/test_hambrowse_window.sh — FAST, QEMU-free gate proving the NATIVE
# browser window (chrome + scrolled page viewport) renders as real PIXEL
# graphics — proportional AA text + a decoded PNG <img> — via the SHARED window
# compositor lib/browserwin.ad. That is the exact function user/hambrowse.ad's
# emit() calls to paint the compositor v2-blit backbuffer on device, so this
# host render (build/host/gfx_native_browser.png) is a faithful preview of the
# on-device window without a 6-minute installer boot.
#
# It also confirms the NATIVE hambrowse (which drives the same browserwin_paint)
# still compiles for x86_64-adder-user.
#
# Built with the frozen Python seed compiler. PNG conversion is stdlib-only
# (scripts/ppm_to_png.py).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx_window"
mkdir -p "$OUT"
fail=0

echo "[hb-win] compiling host window compositor for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_gfx_window.ad -o "$BIN" 2>"$OUT/win_compile.log"; then
    echo "[hb-win] FAIL: driver did not compile"; cat "$OUT/win_compile.log"; exit 1
fi
echo "[hb-win] PASS host window compositor compiled -> $BIN"

echo "[hb-win] confirming NATIVE hambrowse still compiles ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/win_native.log"; then
    echo "[hb-win] FAIL: native hambrowse did not compile"; cat "$OUT/win_native.log"; exit 1
fi
echo "[hb-win] PASS native hambrowse still compiles"

# Regenerate the tiny sample PNG the fixture references (self-contained).
SAMPLE="tests/fixtures/hambrowse_img_sample.png"
python3 - "$SAMPLE" <<'PY'
import sys, zlib, struct
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t+d) & 0xffffffff)
w, h = 48, 32
raw = bytearray()
for y in range(h):
    raw.append(0)
    for x in range(w):
        if x < 24 and y < 16:    raw += bytes((220, 40, 40, 255))
        elif x >= 24 and y < 16: raw += bytes((40, 200, 60, 255))
        elif x < 24 and y >= 16: raw += bytes((50, 90, 220, 255))
        else:                    raw += bytes((0, 0, 0, 128))
idat = zlib.compress(bytes(raw), 9)
ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(data)
PY

FIX="tests/fixtures/hambrowse_img.html"
DUMP="$OUT/win_dump.txt"
PPM="$OUT/gfx_native_browser.ppm"
PNG="$OUT/gfx_native_browser.png"

echo "[hb-win] compositing the full window for $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 880 600 >"$DUMP" 2>&1; then
    echo "[hb-win] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/win_png.log"; then
    echo "[hb-win] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-win] FAIL png conversion"; cat "$OUT/win_png.log"; fail=1
fi

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-win] PASS $msg"
    else
        echo "[hb-win] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# The window is 880x600 and the document overflowed a bit (DOCH > 0).
assert_grep '^WIN 880$'  "window width 880"
assert_grep '^WINH 600$' "window height 600"
assert_grep '^DOCH [1-9][0-9]*$' "document canvas has non-zero height"

# The Chrome-style TAB STRIP background pixel (2,2) is the light grey #dee1e6 =
# 222 225 230 (was a dark-blue title bar before the Chrome-shell redesign).
assert_grep '^PIX 2 2 222 225 230$' "tab strip drawn in Chrome grey"

# ANTI-ALIASING proof: scan the PNG for intermediate grey pixels (grayscale
# glyph-edge coverage a 1-bit VGA font can never produce).
AA=$(python3 - "$PNG" <<'PY'
import sys, zlib, struct
d = open(sys.argv[1], 'rb').read()
pos = 8; W = H = 0; idat = b''
while pos < len(d):
    ln = struct.unpack(">I", d[pos:pos+4])[0]; typ = d[pos+4:pos+8]; body = d[pos+8:pos+8+ln]
    if typ == b'IHDR': W, H = struct.unpack(">II", body[:8])
    elif typ == b'IDAT': idat += body
    elif typ == b'IEND': break
    pos += 12 + ln
raw = zlib.decompress(idat); stride = W*3 + 1; out = bytearray()
prev = bytearray(W*3)
for y in range(H):
    f = raw[y*stride]; line = bytearray(raw[y*stride+1:y*stride+1+W*3])
    if f == 1:
        for i in range(3, len(line)): line[i] = (line[i] + line[i-3]) & 255
    elif f == 2:
        for i in range(len(line)): line[i] = (line[i] + prev[i]) & 255
    elif f == 3:
        for i in range(len(line)):
            a = line[i-3] if i >= 3 else 0
            line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
    elif f == 4:
        for i in range(len(line)):
            a = line[i-3] if i >= 3 else 0; b = prev[i]; c = prev[i-3] if i >= 3 else 0
            p = a + b - c; pa = abs(p-a); pb = abs(p-b); pc = abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[i] = (line[i] + pr) & 255
    out += line; prev = line
grey = 0
for i in range(0, len(out), 3):
    r, g, b = out[i], out[i+1], out[i+2]
    if r == g == b and 8 < r < 247: grey += 1
print(grey)
PY
)
echo "[hb-win] AA grey pixels: $AA"
if [ "${AA:-0}" -gt 500 ]; then
    echo "[hb-win] PASS window has anti-aliased text ($AA grey edge pixels)"
else
    echo "[hb-win] FAIL window not anti-aliased (grey=$AA)"; fail=1
fi

# A decoded IMAGE pixel: the fixture's red quadrant lands inside the natural-
# size box near the top-left of the content. Sample a band of the content and
# assert a strongly-red pixel exists (proves a real PNG was blitted, not paper).
RED=$(python3 - "$PNG" <<'PY'
import sys, zlib, struct
d = open(sys.argv[1], 'rb').read()
pos = 8; W = H = 0; idat = b''
while pos < len(d):
    ln = struct.unpack(">I", d[pos:pos+4])[0]; typ = d[pos+4:pos+8]; body = d[pos+8:pos+8+ln]
    if typ == b'IHDR': W, H = struct.unpack(">II", body[:8])
    elif typ == b'IDAT': idat += body
    elif typ == b'IEND': break
    pos += 12 + ln
raw = zlib.decompress(idat); stride = W*3 + 1; rows = []; prev = bytearray(W*3)
for y in range(H):
    f = raw[y*stride]; line = bytearray(raw[y*stride+1:y*stride+1+W*3])
    if f == 1:
        for i in range(3, len(line)): line[i] = (line[i] + line[i-3]) & 255
    elif f == 2:
        for i in range(len(line)): line[i] = (line[i] + prev[i]) & 255
    elif f == 3:
        for i in range(len(line)):
            a = line[i-3] if i >= 3 else 0
            line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
    elif f == 4:
        for i in range(len(line)):
            a = line[i-3] if i >= 3 else 0; b = prev[i]; c = prev[i-3] if i >= 3 else 0
            p = a + b - c; pa = abs(p-a); pb = abs(p-b); pc = abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[i] = (line[i] + pr) & 255
    rows.append(line); prev = line
found = 0
for y in range(H):
    for x in range(W):
        r, g, b = rows[y][x*3], rows[y][x*3+1], rows[y][x*3+2]
        if r > 170 and g < 90 and b < 90: found += 1
print(found)
PY
)
echo "[hb-win] strongly-red image pixels: $RED"
if [ "${RED:-0}" -gt 100 ]; then
    echo "[hb-win] PASS a real decoded PNG was blitted (red quadrant present)"
else
    echo "[hb-win] FAIL no decoded image pixels found (red=$RED)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-win] RESULT: PASS"
else
    echo "[hb-win] RESULT: FAIL"
fi
exit "$fail"
