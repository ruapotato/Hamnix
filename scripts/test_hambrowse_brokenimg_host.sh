#!/usr/bin/env bash
# scripts/test_hambrowse_brokenimg_host.sh — FAST, QEMU-free gate for COMPACT
# broken-image placeholder sizing (lib/web/layout/box.ad :: _handle_img).
#
# On real sites (BBC News, Wikipedia) most content images carry a responsive
# `width:100%` CSS rule and NO width/height attributes. That percentage resolves
# against the page width in this engine, so an UNFETCHED/undecodable <img> would
# balloon its diagonal-cross "broken image" placeholder to the full column (and
# the lone-width square fallback then squared it), producing giant X-boxes that
# dominate the layout and shove text around. Real browsers draw a COMPACT box.
#
# The fix: a BROKEN image DECLINES a percentage-derived css width (mirroring the
# inline-<svg> replaced-element rule) and falls back to an explicit width/height
# ATTRIBUTE if the markup gave one, else the small default icon box. A DECODED
# image keeps `width:100%` intact (byte-identical for pages whose images load).
#
# This gate renders tests/fixtures/hambrowse_brokenimg.html and asserts, via the
# driver's deterministic IMGSEG geometry dump, that:
#   * A: a `width:100%` broken img -> COMPACT default box (NOT the ~640+ column);
#   * B: a broken img with width=120 height=90 attrs -> honoured at 120x90;
#   * C: a broken img with no size -> the small default box;
#   * NONE of the broken boxes balloon to the container/column width.
#
# Built with the frozen Python seed compiler (no self-host bootstrap).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-brokenimg] compiling pixel backend ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/brokenimg_compile.log"; then
    echo "[hb-brokenimg] FAIL: driver did not compile"
    cat "$OUT/brokenimg_compile.log"; exit 1
fi
echo "[hb-brokenimg] PASS pixel backend compiled -> $BIN"

FIX="tests/fixtures/hambrowse_brokenimg.html"
DUMP="$OUT/brokenimg_dump.txt"
PPM="$OUT/gfx_brokenimg.ppm"
PNG="$OUT/gfx_brokenimg.png"
WIDTH=800

echo "[hb-brokenimg] rendering $FIX (width $WIDTH) ..."
if ! "$BIN" "$FIX" "$PPM" "$WIDTH" >"$DUMP" 2>&1; then
    echo "[hb-brokenimg] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi

# Every image on the page is broken -> every IMGSEG is a placeholder (slot -2).
# The compact default is 40x32 (IMG_BROKEN_W/H); the explicit-attr one is 120x90.
COMPACT_W=40; COMPACT_H=32

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-brokenimg] PASS $msg"
    else
        echo "[hb-brokenimg] FAIL $msg (missing: $pat)"
        echo "  --- IMGSEG lines seen: ---"; grep -E '^IMGSEG' "$DUMP" | sed 's/^/    /'
        fail=1
    fi
}

# A: width:100% broken img collapses to the COMPACT default, NOT the column width.
assert_grep "^IMGSEG slot -2 w ${COMPACT_W} h ${COMPACT_H} " \
    "A: width:100% broken img -> compact ${COMPACT_W}x${COMPACT_H} (declines the percentage)"
# B: explicit width/height attributes are honoured on a broken img.
assert_grep '^IMGSEG slot -2 w 120 h 90 ' \
    "B: broken img width=120 height=90 -> honoured at 120x90"
# C: there are at least two compact (40x32) boxes (A and the no-size C).
NCOMPACT=$(grep -Ec "^IMGSEG slot -2 w ${COMPACT_W} h ${COMPACT_H} " "$DUMP")
if [ "${NCOMPACT:-0}" -ge 2 ]; then
    echo "[hb-brokenimg] PASS C: >=2 compact default boxes (width:100% + no-size), got $NCOMPACT"
else
    echo "[hb-brokenimg] FAIL C: expected >=2 compact ${COMPACT_W}x${COMPACT_H} boxes, got ${NCOMPACT:-0}"; fail=1
fi

# NONE of the broken boxes may balloon toward the 640px column / 800px canvas.
# Assert the widest placeholder box is <= 200px (well under the column width).
MAXW=$(awk '/^IMGSEG slot -2 /{if ($5+0 > m) m=$5+0} END{print m+0}' "$DUMP")
if [ "${MAXW:-0}" -le 200 ]; then
    echo "[hb-brokenimg] PASS no broken box balloons to the column (widest = ${MAXW}px <= 200)"
else
    echo "[hb-brokenimg] FAIL a broken box ballooned to ${MAXW}px (>200, near the column width)"; fail=1
fi

# Render the PPM to a PNG for eyeballing.
if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/brokenimg_png.log"; then
    echo "[hb-brokenimg] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-brokenimg] FAIL png conversion"; cat "$OUT/brokenimg_png.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-brokenimg] RESULT: PASS"
else
    echo "[hb-brokenimg] RESULT: FAIL"; exit 1
fi
