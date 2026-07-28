#!/usr/bin/env bash
# scripts/test_hambrowse_gif.sh — FAST, QEMU-free gate for GIF <img> support in
# the native browser, completing the big-three raster formats (PNG + JPEG land;
# this adds GIF, still common for logos/icons/simple graphics on real sites).
#
# lib/gif.ad is a from-scratch, pure-Adder, INTEGER-ONLY GIF decoder (GIF87a/
# GIF89a header + Logical Screen Descriptor + Global/Local Color Table + the
# Extension / Image Descriptor block stream + LZW decompression with the
# variable-width code table, CLEAR/END codes, the deferred-clear quirk, and the
# 4-pass interlaced row order). It decodes the FIRST frame to RGBA, honouring a
# Graphic Control Extension's TRANSPARENT colour index (-> alpha 0). The two
# hambrowse decode sites dispatch by magic (PNG 89 50, JPEG FF D8, GIF 47 49 46
# 38) and feed the RGBA into lib/htmlimg.ad exactly like PNG/JPEG.
#
# Because GIF is a PALETTE format, colours are LOSSLESS — the gate asserts EXACT
# quadrant colours (unlike the tolerant JPEG gate). It renders
# tests/fixtures/hambrowse_gif.html — a non-interlaced GIF, an INTERLACED GIF
# (same quadrant colours, exercising the de-interlace row order), a TRANSPARENT
# GIF, and a truncated/garbage GIF (placeholder, no crash) — and asserts:
#   * non-interlaced + interlaced decode to their true 48x32 with EXACT colours;
#   * the transparent top-left quadrant decodes to alpha 0 and, in the browser,
#     lets the white paper show through (alpha-composited blit);
#   * a truncated GIF reports rc<0 and draws the grey placeholder, no crash.
# It also runs lib/gif.ad's standalone probe for direct per-pixel + alpha
# accuracy, and renders build/host/gfx_gif.png for eyeballing.
#
# Built with the frozen Python seed compiler (no self-host bootstrap). Fixtures
# are generated deterministically by scripts/gen_gif_fixtures.py (a dependency-
# free GIF writer — no PIL, no zlib) so the gate is fully self-contained, and
# are ALSO checked in.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
PROBE="$OUT/gif_probe"
mkdir -p "$OUT"
fail=0

echo "[hb-gif] compiling pixel backend (with GIF decode) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/gif_compile.log"; then
    echo "[hb-gif] FAIL: driver did not compile"; cat "$OUT/gif_compile.log"; exit 1
fi
echo "[hb-gif] PASS pixel backend compiled -> $BIN"

echo "[hb-gif] compiling standalone gif probe ..."
if ! adder_bin x86_64-linux user/gif_probe.ad "$PROBE" 2>"$OUT/gif_probe_compile.log"; then
    echo "[hb-gif] FAIL: gif_probe did not compile"; cat "$OUT/gif_probe_compile.log"; exit 1
fi
echo "[hb-gif] PASS gif probe compiled -> $PROBE"

# (Re)generate the checked-in GIF fixtures deterministically — no PIL, no zlib.
FPLAIN="tests/fixtures/hambrowse_gif_plain.gif"
FINTER="tests/fixtures/hambrowse_gif_interlaced.gif"
FTRANS="tests/fixtures/hambrowse_gif_trans.gif"
FTRUNC="tests/fixtures/hambrowse_gif_trunc.gif"
if ! python3 scripts/gen_gif_fixtures.py "$FPLAIN" "$FINTER" "$FTRANS" "$FTRUNC" \
        >"$OUT/gif_gen.log" 2>&1; then
    echo "[hb-gif] FAIL: fixture generation"; cat "$OUT/gif_gen.log"; exit 1
fi
for f in "$FPLAIN" "$FINTER" "$FTRANS" "$FTRUNC"; do
    [ -s "$f" ] || { echo "[hb-gif] FAIL: missing fixture $f"; exit 1; }
done
echo "[hb-gif] plain fixture: $(file -b "$FPLAIN" 2>/dev/null)"

# ---- standalone probe: direct per-pixel decode accuracy (EXACT) ----
probe_dim() {  # $1=file $2=label
    local dump="$OUT/gif_probe_$2.txt"
    "$PROBE" "$1" 12 8 36 8 12 24 36 24 >"$dump" 2>&1
    if grep -Eq '^DIM 48 32$' "$dump"; then
        echo "[hb-gif] PASS probe $2 decoded to natural 48x32"
    else
        echo "[hb-gif] FAIL probe $2 dimensions"; cat "$dump"; fail=1
    fi
}

# "PIX x y r g b a" — EXACT match (palette is lossless).
probe_pix() {  # $1=label $2=x $3=y $4=r $5=g $6=b $7=a $8=msg
    local dump="$OUT/gif_probe_$1.txt" line
    line=$(grep -E "^PIX $2 $3 " "$dump" | head -1)
    if [ -z "$line" ]; then
        echo "[hb-gif] FAIL $8: no PIX $2 $3"; fail=1; return
    fi
    read -r _ _ _ gr gg gb ga <<<"$line"
    if [ "$gr" = "$4" ] && [ "$gg" = "$5" ] && [ "$gb" = "$6" ] && [ "$ga" = "$7" ]; then
        echo "[hb-gif] PASS $8 (exact $gr,$gg,$gb,a$ga)"
    else
        echo "[hb-gif] FAIL $8 (got $gr,$gg,$gb,a$ga want $4,$5,$6,a$7)"; fail=1
    fi
}

echo "[hb-gif] probe: NON-INTERLACED decode + exact quadrant colours ..."
probe_dim "$FPLAIN" plain
probe_pix plain 12 8  220 40 40  255 "red quadrant (non-interlaced)"
probe_pix plain 36 8  40 200 60  255 "green quadrant (non-interlaced)"
probe_pix plain 12 24 50 90 220  255 "blue quadrant (non-interlaced)"
probe_pix plain 36 24 240 240 240 255 "white quadrant (non-interlaced)"

echo "[hb-gif] probe: INTERLACED decode + exact quadrant colours (row order) ..."
probe_dim "$FINTER" inter
probe_pix inter 12 8  220 40 40  255 "red quadrant (interlaced)"
probe_pix inter 36 8  40 200 60  255 "green quadrant (interlaced)"
probe_pix inter 12 24 50 90 220  255 "blue quadrant (interlaced)"
probe_pix inter 36 24 240 240 240 255 "white quadrant (interlaced)"

echo "[hb-gif] probe: TRANSPARENT index -> alpha 0 ..."
probe_dim "$FTRANS" trans
probe_pix trans 12 8  17 17 17   0   "transparent quadrant decodes to alpha 0"
probe_pix trans 36 8  40 200 60  255 "green quadrant opaque (transparent GIF)"
probe_pix trans 36 24 240 240 240 255 "white quadrant opaque (transparent GIF)"

echo "[hb-gif] probe: truncated GIF fails cleanly (rc<0, no crash) ..."
"$PROBE" "$FTRUNC" 0 0 >"$OUT/gif_probe_trunc.txt" 2>&1
if grep -Eq '^RC -[0-9]' "$OUT/gif_probe_trunc.txt"; then
    echo "[hb-gif] PASS truncated GIF rejected (rc<0)"
else
    echo "[hb-gif] FAIL truncated GIF not rejected"; cat "$OUT/gif_probe_trunc.txt"; fail=1
fi

# ---- full browser render: layout + blit ----
FIX="tests/fixtures/hambrowse_gif.html"
DUMP="$OUT/gif_dump.txt"
PPM="$OUT/gfx_gif.ppm"
PNG="$OUT/gfx_gif.png"

echo "[hb-gif] rendering $FIX (pass 1: geometry) ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-gif] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-gif] PASS $msg"
    else
        echo "[hb-gif] FAIL $msg (missing: $pat)"; fail=1
    fi
}
assert_grep '^IMGDEC "hambrowse_gif_plain.gif" 0 48 32' \
    "non-interlaced GIF decodes to natural 48x32 in the browser"
assert_grep '^IMGDEC "hambrowse_gif_interlaced.gif" 0 48 32' \
    "interlaced GIF decodes to natural 48x32 in the browser"
assert_grep '^IMGDEC "hambrowse_gif_trans.gif" 0 48 32' \
    "transparent GIF decodes to natural 48x32 in the browser"
assert_grep '^IMGDEC "hambrowse_gif_trunc.gif" -1' \
    "truncated GIF fails to decode (drives the placeholder)"
assert_grep '^IMGSEG slot 0 w 48 h 32 ' \
    "non-interlaced <img> reserves its natural 48x32 box (slot 0)"
assert_grep '^IMGSEG slot 1 w 48 h 32 ' \
    "interlaced <img> reserves its natural 48x32 box (slot 1)"
assert_grep '^IMGSEG slot 2 w 48 h 32 ' \
    "transparent <img> reserves its natural 48x32 box (slot 2)"
assert_grep '^IMGSEG slot -2 ' \
    "truncated src -> placeholder box (slot -2), no crash"

# ---- pixel-colour assertions inside the blitted boxes (EXACT) ----
read PX PTOP < <(awk '/^IMGSEG slot 0 w 48 /{print $9, $11; exit}' "$DUMP")
read TX TTOP < <(awk '/^IMGSEG slot 2 w 48 /{print $9, $11; exit}' "$DUMP")
if [ -z "${PX:-}" ] || [ -z "${PTOP:-}" ] || [ -z "${TX:-}" ] || [ -z "${TTOP:-}" ]; then
    echo "[hb-gif] FAIL could not read image box geometry"; fail=1
else
    RX=$((PX + 12));  RY=$((PTOP + 8))    # red   TL (plain)
    GX=$((PX + 36));  GY=$((PTOP + 8))    # green TR
    BX=$((PX + 12));  BY=$((PTOP + 24))   # blue  BL
    KX=$((PX + 36));  KY=$((PTOP + 24))   # white BR
    TLX=$((TX + 12)); TLY=$((TTOP + 8))   # transparent TL (trans) -> paper
    TGX=$((TX + 36)); TGY=$((TTOP + 8))   # green TR (trans) -> opaque
    SDUMP="$OUT/gif_samples.txt"
    echo "[hb-gif] rendering (pass 2: pixel samples) ..."
    "$BIN" "$FIX" "$PPM" 640 "$RX" "$RY" "$GX" "$GY" "$BX" "$BY" "$KX" "$KY" \
        "$TLX" "$TLY" "$TGX" "$TGY" >"$SDUMP" 2>&1

    # "PIX x y #rrggbb" — EXACT hex compare.
    assert_pix() {
        local x="$1" y="$2" want="$3" msg="$4" hexline hex
        hexline=$(grep -E "^PIX $x $y #" "$SDUMP" | head -1)
        if [ -z "$hexline" ]; then
            echo "[hb-gif] FAIL $msg: no sample at $x,$y"; fail=1; return
        fi
        hex=${hexline##*#}
        if [ "$hex" = "$want" ]; then
            echo "[hb-gif] PASS $msg (#$hex at $x,$y)"
        else
            echo "[hb-gif] FAIL $msg (#$hex want #$want at $x,$y)"; fail=1
        fi
    }
    assert_pix "$RX" "$RY" dc2828 "red quadrant blitted (exact)"
    assert_pix "$GX" "$GY" 28c83c "green quadrant blitted (exact)"
    assert_pix "$BX" "$BY" 325adc "blue quadrant blitted (exact)"
    assert_pix "$KX" "$KY" f0f0f0 "white quadrant blitted (exact)"
    # Transparent quadrant: the palette colour (17,17,17) must NOT appear — the
    # white paper shows through the alpha-0 blit.
    assert_pix "$TLX" "$TLY" ffffff "transparent quadrant shows white paper"
    assert_pix "$TGX" "$TGY" 28c83c "opaque green survives in transparent GIF"
fi

# Render the PPM to a PNG for eyeballing.
if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/gif_png.log"; then
    echo "[hb-gif] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-gif] FAIL png conversion"; cat "$OUT/gif_png.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-gif] PASS"
else
    echo "[hb-gif] FAIL"; exit 1
fi
