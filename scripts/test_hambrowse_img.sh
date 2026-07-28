#!/usr/bin/env bash
# scripts/test_hambrowse_img.sh — FAST, QEMU-free gate for the hambrowse pixel
# <img> RENDERING rung (task #75, "proper graphics" rung 5): a real PNG is
# decoded (lib/png.ad: signature + chunk walk + zlib/DEFLATE inflate + PNG
# unfiltering) and BLITTED into the browser's pixel canvas (lib/htmlimg.ad +
# lib/htmlpaint.ad + lib/htmlpage.ad) at its natural size, honouring width/height
# attributes, with a broken-image placeholder for a missing/undecodable src.
#
# It renders tests/fixtures/hambrowse_img.html — which references a tiny checked-
# in RGBA PNG (tests/fixtures/hambrowse_img_sample.png, regenerated here from
# stdlib zlib so the gate is self-contained) — and asserts, via the driver's
# deterministic geometry + pixel-sample dump, that:
#   * the PNG decodes to its true 48x32 dimensions;
#   * an unsized <img> reserves a 48x32 box; width/height scale it to 96x64;
#   * the KNOWN quadrant colours (red/green/blue + a 50%-alpha->grey blend)
#     land inside the blitted box (NOT paper-white);
#   * a missing src draws the grey placeholder box and does NOT crash.
#
# Built with the frozen Python seed compiler (no self-host bootstrap). PNG
# conversion for eyeballing uses scripts/ppm_to_png.py (stdlib only).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-img] compiling pixel backend (with PNG decode) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/img_compile.log"; then
    echo "[hb-img] FAIL: driver did not compile"; cat "$OUT/img_compile.log"; exit 1
fi
echo "[hb-img] PASS pixel backend compiled -> $BIN"

# Regenerate the checked-in sample PNG deterministically (idempotent) so the
# gate is self-contained and can't silently drift from the committed fixture.
SAMPLE="tests/fixtures/hambrowse_img_sample.png"
python3 - "$SAMPLE" <<'PY'
import sys, zlib, struct
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t+d) & 0xffffffff)
w, h = 48, 32
raw = bytearray()
for y in range(h):
    raw.append(0)  # filter: None
    for x in range(w):
        if x < 24 and y < 16:    raw += bytes((220, 40, 40, 255))   # red   TL
        elif x >= 24 and y < 16: raw += bytes((40, 200, 60, 255))   # green TR
        elif x < 24 and y >= 16: raw += bytes((50, 90, 220, 255))   # blue  BL
        else:                    raw += bytes((0, 0, 0, 128))       # 50% black BR
idat = zlib.compress(bytes(raw), 9)
ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(data)
PY
echo "[hb-img] sample PNG: $(file -b "$SAMPLE" 2>/dev/null)"

FIX="tests/fixtures/hambrowse_img.html"
DUMP="$OUT/img_dump.txt"
PPM="$OUT/gfx_img.ppm"
PNG="$OUT/gfx_img.png"

echo "[hb-img] rendering $FIX (pass 1: geometry) ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-img] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-img] PASS $msg"
    else
        echo "[hb-img] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# 1. The PNG decoded to its true dimensions (rc 0, 48x32).
assert_grep '^IMGDEC "hambrowse_img_sample.png" 0 48 32' \
    "PNG decoded to natural 48x32 (signature+inflate+unfilter)"
# 2. The missing image reports a decode failure (rc != 0) -> placeholder path.
assert_grep '^IMGDEC "does_not_exist.png" -1' \
    "missing src fails to decode (drives the placeholder)"
# 3. Unsized <img> reserves a 48x32 box; the decoded slot >= 0.
assert_grep '^IMGSEG slot 0 w 48 h 32 ' \
    "unsized <img> box = natural 48x32 (slot 0)"
# 4. width=96 height=64 scales the box.
assert_grep '^IMGSEG slot 0 w 96 h 64 ' \
    "width/height attributes scale the box to 96x64"
# 5. The broken image is a placeholder box (slot -2).
assert_grep '^IMGSEG slot -2 ' \
    "broken src -> placeholder box (slot -2), no crash"

# ---- pixel-colour assertions inside the blitted box ----
# Pull the natural image's box origin (x, row-top) from the geometry dump, then
# sample the four quadrant centres. This proves REAL image pixels (not paper).
# IMGSEG fields: "IMGSEG slot <n> w <w> h <h> x <x> top <top>" -> x=$9, top=$11.
read IMGX IMGTOP < <(awk '/^IMGSEG slot 0 w 48 /{print $9, $11; exit}' "$DUMP")
read BRKX BRKTOP < <(awk '/^IMGSEG slot -2 /{print $9, $11; exit}' "$DUMP")
if [ -z "${IMGX:-}" ] || [ -z "${IMGTOP:-}" ]; then
    echo "[hb-img] FAIL could not read image box geometry"; fail=1
else
    RX=$((IMGX + 12));  RY=$((IMGTOP + 8))    # red   TL quadrant centre
    GX=$((IMGX + 36));  GY=$((IMGTOP + 8))    # green TR
    BX=$((IMGX + 12));  BY=$((IMGTOP + 24))   # blue  BL
    KX=$((IMGX + 36));  KY=$((IMGTOP + 24))   # grey  BR (50% black over white)
    PX=$((BRKX + 4));   PY=$((BRKTOP + 16))   # placeholder box interior
    SDUMP="$OUT/img_samples.txt"
    echo "[hb-img] rendering (pass 2: pixel samples) ..."
    "$BIN" "$FIX" "$PPM" 640 "$RX" "$RY" "$GX" "$GY" "$BX" "$BY" "$KX" "$KY" \
        "$PX" "$PY" >"$SDUMP" 2>&1

    assert_pix() {
        local x="$1" y="$2" col="$3" msg="$4"
        if grep -Eq -- "^PIX $x $y #$col\$" "$SDUMP"; then
            echo "[hb-img] PASS $msg (#$col at $x,$y)"
        else
            local got=$(grep -E "^PIX $x $y " "$SDUMP" | head -1)
            echo "[hb-img] FAIL $msg: expected #$col at $x,$y, got: $got"; fail=1
        fi
    }
    assert_pix "$RX" "$RY" "dc2828" "red quadrant blitted"
    assert_pix "$GX" "$GY" "28c83c" "green quadrant blitted"
    assert_pix "$BX" "$BY" "325adc" "blue quadrant blitted"
    assert_pix "$KX" "$KY" "7f7f7f" "50%-alpha black alpha-blends to grey over paper"
    assert_pix "$PX" "$PY" "eeeeee" "broken-image placeholder draws a grey box"
fi

# Render the PPM to a PNG for eyeballing.
if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/img_png.log"; then
    echo "[hb-img] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-img] FAIL png conversion"; cat "$OUT/img_png.log"; fail=1
fi

# ---- broken-only page must render + not crash ----
BROKEN="$OUT/img_broken.html"
cat > "$BROKEN" <<'HTML'
<html><body><p>Only a broken image:</p>
<img src="nope.png" alt="gone"><p>after</p></body></html>
HTML
if "$BIN" "$BROKEN" "$OUT/img_broken.ppm" 400 >"$OUT/img_broken_dump.txt" 2>&1; then
    if grep -Eq '^IMGSEG slot -2 ' "$OUT/img_broken_dump.txt"; then
        echo "[hb-img] PASS broken-only page draws a placeholder, exits 0"
    else
        echo "[hb-img] FAIL broken-only page missing placeholder seg"; fail=1
    fi
else
    echo "[hb-img] FAIL broken-only page crashed"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-img] PASS"
else
    echo "[hb-img] FAIL"; exit 1
fi
