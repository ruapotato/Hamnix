#!/usr/bin/env bash
# scripts/test_font_hscale_host.sh — FAST, QEMU-free gate for the Chrome-parity
# horizontal metric scale in lib/font_ttf.ad.
#
# WHY: hambrowse embeds DejaVu, but headless Chromium resolves the generic
# `sans-serif` to Liberation Sans (Arimo), which is ~12% NARROWER than DejaVu
# Sans. Rendering DejaVu at its own width made every text run wider than Chrome,
# wrapping early and inflating page height ~2x (the #1 cross-site parity gap).
# lib/font_ttf.ad now applies a per-face horizontal scale (sans 877/1000,
# sans-bold 839/1000; serif & mono at 1000) to BOTH the advance AND the glyph
# outline so text is width-matched to Chrome's Liberation metric.
#
# This gate builds user/font_ttf_probe.ad (loads the bundled DejaVu-sans subset,
# rasterises 'A' at several px) and asserts the reported advances are the
# CONDENSED values — strictly narrower than the raw DejaVu advance — proving the
# scale is applied and guarding against silent reversion.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
PROBE="$OUT/font_ttf_probe"
FONT="fonts/dejavu-sans.ttf"
fail=0

echo "[hscale] (1/3) compiling user/font_ttf_probe.ad (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/font_ttf_probe.ad "$PROBE" 2>"$OUT/hscale_compile.log"; then
    echo "[hscale] FAIL: probe did not compile"; cat "$OUT/hscale_compile.log"; exit 1
fi
echo "[hscale] PASS probe compiled"

[ -f "$FONT" ] || { echo "[hscale] FAIL: missing $FONT"; exit 1; }
DUMP="$OUT/hscale_dump.txt"
"$PROBE" "$FONT" >"$DUMP" 2>&1 || { echo "[hscale] FAIL: probe exited non-zero"; cat "$DUMP"; exit 1; }

# Advance (px) of 'A' (cp 65) at a given px size, from the probe dump.
adv_at() { awk -v p="$1" '/^GLYPH cp=65 px='"$1"' / {for(i=1;i<=NF;i++){if($i ~ /^adv=/){sub(/adv=/,"",$i);print $i}}}' "$DUMP"; }

echo "[hscale] (2/3) checking condensed sans advances for 'A' ..."
# Expected CONDENSED advances (DejaVu-sans subset @ scale 877/1000). The raw
# (unscaled) DejaVu advance for 'A' is 1401/2048 em; the values below are the
# 877/1000-scaled, px-rounded advances the renderer now emits.
#   size : condensed  (raw would be)
#   12   : 7          (8)
#   16   : 10         (11)
#   18   : 11         (13)
#   24   : 14         (16)
#   32   : 19         (22)
check() {
    local px="$1" want="$2" rawish="$3"
    local got; got="$(adv_at "$px")"
    if [ "$got" = "$want" ]; then
        echo "[hscale] PASS 'A'@${px}px adv=$got (condensed; raw DejaVu ~$rawish)"
    else
        echo "[hscale] FAIL 'A'@${px}px adv=$got, expected condensed $want (raw ~$rawish)"; fail=1
    fi
}
check 12 7 8
check 16 10 11
check 18 11 13
check 24 14 16
check 32 19 22

echo "[hscale] (3/3) confirming the scale actually narrows (condensed < raw) ..."
a16="$(adv_at 16)"
if [ -n "$a16" ] && [ "$a16" -lt 11 ]; then
    echo "[hscale] PASS 'A'@16 advance ($a16) < raw DejaVu (11) — Chrome-parity scale is active"
else
    echo "[hscale] FAIL 'A'@16 advance ($a16) is not condensed below the raw DejaVu 11"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hscale] RESULT PASS"
    exit 0
else
    echo "[hscale] RESULT FAIL"
    exit 1
fi
