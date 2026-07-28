#!/usr/bin/env bash
# scripts/test_hambrowse_abswidth_host.sh — FAST, QEMU-free render-to-PNG gate
# for CSS shrink-to-fit sizing of an AUTO-WIDTH `position:absolute` box
# (CSS 2.1 §10.3.7), the on-device QA defect where a `top:8px; right:8px` badge
# with NO explicit width filled the WHOLE containing block and started at the far
# LEFT, overlapping the heading — even though its right edge anchored correctly.
#
# Mirrors the QA hero card: a `position:relative`, linear-GRADIENT, padded panel
# whose FIRST child is a `position:absolute; top;right`, width:auto badge, then an
# <h1>. The badge must SHRINK-TO-FIT its content (a small box pinned top-RIGHT),
# not span the card. Asserts on the badge's stable POSFILL background rect:
#   * badge width  < 120px            (shrink-to-fit, NOT full card width)
#   * badge left x0 > parent_centre   (sits in the RIGHT half, off the heading)
#   * badge right x1 ~= parent_right-8 (right edge still anchored `right:8`)

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_abswidth.html"
DUMP="$OUT/abswidth_dump.txt"
PPM="$OUT/abswidth.ppm"
PNG="$OUT/abswidth.png"
mkdir -p "$OUT"
fail=0

echo "[hb-abswidth] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/abswidth_compile.log"; then
    echo "[hb-abswidth] FAIL: driver did not compile"; cat "$OUT/abswidth_compile.log"; exit 1
fi
echo "[hb-abswidth] PASS pixel backend compiled -> $BIN"

echo "[hb-abswidth] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/abswidth_native.log"; then
    echo "[hb-abswidth] FAIL: native hambrowse did not compile"; cat "$OUT/abswidth_native.log"; exit 1
fi
echo "[hb-abswidth] PASS native hambrowse still compiles"

echo "[hb-abswidth] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 760 >"$DUMP" 2>&1; then
    echo "[hb-abswidth] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^POSFILL' "$DUMP" || true
python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>/dev/null && \
    echo "[hb-abswidth] wrote $PNG for eyeballing" || true

# POSFILL i z Z x0 X y0 Y x1 X y1 Y col C pix P
row_for() {
    awk -v c="$1" '$1=="POSFILL" && $14==c {print $6, $8, $10, $12; exit}' "$DUMP"
}
read -r B_X0 B_Y0 B_X1 B_Y1 < <(row_for '#ffff00')   # the auto-width badge
# The gradient panel records its fill under a #000000 placeholder colour (the
# sampled pixel is the gradient); its rect gives the containing block's edges.
read -r P_X0 P_Y0 P_X1 P_Y1 < <(row_for '#000000')

echo "[hb-abswidth] badge=($B_X0,$B_Y0)-($B_X1,$B_Y1)  panel=($P_X0,$P_Y0)-($P_X1,$P_Y1)"

need() { [ -n "$1" ] || { echo "[hb-abswidth] FAIL: missing rect ($2)"; fail=1; return 1; }; return 0; }
need "$B_X0" "badge" || true
need "$P_X0" "panel" || true

if [ "$fail" -eq 0 ]; then
    BW=$((B_X1 - B_X0))
    PCENTER=$(((P_X0 + P_X1) / 2))
    RIGHT_TGT=$((P_X1 - 8))

    # (1) SHRINK-TO-FIT: the badge is a small box, NOT the full card width.
    if [ "$BW" -lt 120 ]; then
        echo "[hb-abswidth] PASS badge shrink-to-fits content (width=${BW}px < 120)"
    else
        echo "[hb-abswidth] FAIL badge did not shrink-to-fit (width=${BW}px >= 120 — spans the card)"; fail=1
    fi

    # (2) TOP-RIGHT: the badge sits in the RIGHT half (its left edge is past the
    #     panel centre), so it no longer overlaps the left-aligned heading.
    if [ "$fail" -eq 0 ] && [ "$B_X0" -gt "$PCENTER" ]; then
        echo "[hb-abswidth] PASS badge is in the right half (x0=$B_X0 > centre=$PCENTER)"
    else
        echo "[hb-abswidth] FAIL badge bleeds left over the heading (x0=$B_X0 centre=$PCENTER)"; fail=1
    fi

    # (3) RIGHT-ANCHORED: its right edge stays pinned `right:8` inside the panel.
    if [ "$fail" -eq 0 ] && [ "$B_X1" -ge "$((RIGHT_TGT - 2))" ] && \
       [ "$B_X1" -le "$((RIGHT_TGT + 2))" ]; then
        echo "[hb-abswidth] PASS badge right edge anchored at panel_right-8 (x1=$B_X1 ~= $RIGHT_TGT)"
    else
        echo "[hb-abswidth] FAIL badge right edge not anchored (x1=$B_X1 want ~$RIGHT_TGT)"; fail=1
    fi

    # (4) TOP: pinned to the panel's own top row (top:8 rounds to row 0).
    if [ "$fail" -eq 0 ] && [ "$B_Y0" -le "$((P_Y0 + 2))" ]; then
        echo "[hb-abswidth] PASS badge pinned to panel top (y0=$B_Y0 ~= panel_top=$P_Y0)"
    else
        echo "[hb-abswidth] FAIL badge not at panel top (y0=$B_Y0 panel_top=$P_Y0)"; fail=1
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-abswidth] RESULT: PASS"
else
    echo "[hb-abswidth] RESULT: FAIL"; exit 1
fi
