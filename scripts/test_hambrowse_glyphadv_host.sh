#!/usr/bin/env bash
# scripts/test_hambrowse_glyphadv_host.sh — FAST, QEMU-free gate proving Chrome-
# parity for PER-GLYPH advance width (round 16).
#
# hambrowse embeds the DejaVu faces but the Chromium reference renders sans-serif
# text with Liberation Sans (Arial-metric). lib/font_ttf.ad width-matches DejaVu
# to Liberation with a SINGLE per-face scale (877/1000). That corpus-mean ratio
# is right on mixed prose but WRONG per glyph class: a caps-heavy run comes out
# far too NARROW (hb over-condenses wide capitals). Measured vs `chromium` at
# 16px, the 43-char run below has a Chrome advance of ~433px; hambrowse BASE drew
# it at ~386px (−47px, wrapping/mis-aligning downstream inline segments).
#
# Round 16 replaces the uniform scale with the actual per-glyph Liberation Sans
# advance (measured from Chromium's canvas measureText, stored in
# lib/web/font_adv.ad as 2048-upm font units), consulted by BOTH the layout
# measure hook and the pixel paint (lib/htmlpaint.ad) so measure == paint. The
# same caps run now advances ~432px — within a few px of Chrome.
#
# This gate renders the caps run and reads the painted black run's right edge
# (X+W) from the gfx driver's `dumpops` mode. It asserts the run reaches
# Chrome's ~433px width (>= 415), which BASE (~386) fails, and stays under a
# sane upper bound (<= 448) so the fix does not OVER-widen. Deterministic, no
# network, milliseconds.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-glyphadv] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/glyphadv_compile.log"; then
    echo "[hb-glyphadv] FAIL: driver did not compile"; cat "$OUT/glyphadv_compile.log"; exit 1
fi

FIX="tests/fixtures/hambrowse_glyphadv.html"
DUMP="$OUT/glyphadv_ops.txt"
"$BIN" "$FIX" "$OUT/glyphadv.ppm" 1000 dumpops >"$DUMP" 2>&1 || {
    echo "[hb-glyphadv] FAIL: render nonzero"; cat "$DUMP"; exit 1; }

# The single black (#000000ff) text run: its X and W.
read -r RX RW < <(awk '/^OP covmask/ && $7=="#000000ff" {print $3, $5; exit}' "$DUMP")

if [ -z "${RX:-}" ] || [ -z "${RW:-}" ]; then
    echo "[hb-glyphadv] FAIL: could not locate caps run in dumpops"; cat "$DUMP"; exit 1
fi
ENDX=$(( RX + RW ))
echo "[hb-glyphadv] caps run x=${RX} w=${RW} end-x=${ENDX}px (Chrome ~433; base ~386)"

if [ "$ENDX" -ge 415 ] && [ "$ENDX" -le 448 ]; then
    echo "[hb-glyphadv] PASS caps run advance is Chrome-matched (${ENDX}px in 415..448)"
else
    echo "[hb-glyphadv] FAIL caps run advance off (${ENDX}px; want 415..448 — base ~386 over-condenses)"; fail=1
fi

# --- native hambrowse still compiles ------------------------------------------
if python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse.ad -o "$OUT/hambrowse_native_glyphadv" 2>"$OUT/glyphadv_native.log"; then
    echo "[hb-glyphadv] PASS native hambrowse compiles"
else
    echo "[hb-glyphadv] FAIL native hambrowse did not compile"; cat "$OUT/glyphadv_native.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-glyphadv] RESULT: PASS"
else
    echo "[hb-glyphadv] RESULT: FAIL"; exit 1
fi
