#!/usr/bin/env bash
# scripts/test_hambrowse_fieldset_host.sh — FAST, QEMU-free gate for the native
# browser engine drawing a <fieldset> border (compat-audit #7). Before the fix,
# <fieldset> hit the "transparent container" tag path and never opened a box, so
# its grouped controls got NO frame (BORDER n 0) even with a UA/stylesheet
# border; <legend> rendered as plain text with nothing around it.
#
# The fix makes <fieldset> a block box carrying a UA-default border (browsers
# stroke a groove frame around the group). This gate renders a fieldset with NO
# author border rule and asserts a REAL stroked rectangle appears: exactly one
# BORDER box, a dark top-edge stroke pixel and a white pixel just inside it
# (padding, no glyph fill) — stable chrome, not glyph ink, so a regression fails
# without a QEMU boot.
#
# Builds BOTH the host pixel driver (x86_64-linux) and the native hambrowse
# (x86_64-adder-user) so a break in the shared engine is caught either way.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_fieldset.html"
DUMP="$OUT/fieldset_dump.txt"
PPM="$OUT/fieldset.ppm"
PNG="$OUT/fieldset.png"
mkdir -p "$OUT"
fail=0

echo "[hb-fs] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/fs_compile.log"; then
    echo "[hb-fs] FAIL: driver did not compile"; cat "$OUT/fs_compile.log"; exit 1
fi
echo "[hb-fs] PASS pixel backend compiled -> $BIN"

echo "[hb-fs] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/fs_native.log"; then
    echo "[hb-fs] FAIL: native hambrowse did not compile"; cat "$OUT/fs_native.log"; exit 1
fi
echo "[hb-fs] PASS native hambrowse still compiles"

echo "[hb-fs] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-fs] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^BORDER' "$DUMP" || true
python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>/dev/null && \
    echo "[hb-fs] wrote $PNG for eyeballing" || true

# (1) exactly one border box drawn for the fieldset.
NBORD=$(awk '$1=="BORDER" && $2=="n" {print $3; exit}' "$DUMP")
if [ "${NBORD:-x}" = "1" ]; then
    echo "[hb-fs] PASS fieldset drew a border box (BORDER n 1)"
else
    echo "[hb-fs] FAIL fieldset border not drawn (BORDER n=${NBORD:-none}, want 1)"; fail=1
fi

# (2) it is a real rectangle: x1 > x0 by a healthy margin, and the top-edge
# pixel is a dark stroke while a pixel just inside is white (no glyph fill).
read -r BX0 BX1 EDGE INSIDE < <(awk '$1=="BORDER" && $2=="0" {print $4, $8, $12, $14; exit}' "$DUMP")
echo "[hb-fs] border x0=$BX0 x1=$BX1 edge=$EDGE inside=$INSIDE"
if [ -n "$BX0" ] && [ -n "$BX1" ] && [ "$((BX1 - BX0))" -ge 100 ]; then
    echo "[hb-fs] PASS border spans a real rectangle (width $((BX1 - BX0))px)"
else
    echo "[hb-fs] FAIL border rectangle too narrow/absent (x0=${BX0:-none} x1=${BX1:-none})"; fail=1
fi
if [ "$EDGE" = "#000000" ] && [ "$INSIDE" = "#ffffff" ]; then
    echo "[hb-fs] PASS dark stroke on the edge, white padding inside (edge=$EDGE inside=$INSIDE)"
else
    echo "[hb-fs] FAIL edge/inside sampling wrong (edge=$EDGE inside=$INSIDE, want #000000/#ffffff)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-fs] RESULT: PASS"
else
    echo "[hb-fs] RESULT: FAIL"; exit 1
fi
