#!/usr/bin/env bash
# scripts/test_hambrowse_absinline_host.sh — FAST, QEMU-free gate for the ROOT
# bug behind hambrowse's HEADING-CLIP and TOP-LEFT-BADGE symptoms: a
# `position:absolute`/`fixed` element was not removed from INLINE flow. It was
# laid out at its static (top-left) inline position where it (1) painted its
# label at the wrong corner and (2) consumed inline advance that pushed the
# following <h1> line one badge-width to the right, so the heading overran the
# card and clipped.
#
# The fixture is a `position:relative` card holding an EARLY `position:absolute`
# badge before a long heading — once as an INLINE <span> (must blockify + leave
# inline flow) and once as a BLOCK <div>. After the fix:
#   * REFLOW reports overflow 0 and maxx <= the card's right edge (the heading
#     fits — it starts at the card LEFT, not offset by the badge);
#   * each badge's background rect (POSFILL) is a small chip anchored to the
#     card's top-RIGHT (right edge ~= card_right-4, left edge well right of the
#     card left), NOT flush at the heading's line start.
# Asserts on STABLE geometry (REFLOW + POSFILL records), so a regression fails
# WITHOUT a QEMU boot.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_absinline.html"
DUMP="$OUT/absinline_dump.txt"
PPM="$OUT/absinline.ppm"
PNG="$OUT/absinline.png"
mkdir -p "$OUT"
fail=0

echo "[hb-absinline] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/absinline_compile.log"; then
    echo "[hb-absinline] FAIL: driver did not compile"; cat "$OUT/absinline_compile.log"; exit 1
fi
echo "[hb-absinline] PASS pixel backend compiled -> $BIN"

echo "[hb-absinline] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/absinline_native.log"; then
    echo "[hb-absinline] FAIL: native hambrowse did not compile"; cat "$OUT/absinline_native.log"; exit 1
fi
echo "[hb-absinline] PASS native hambrowse still compiles"

echo "[hb-absinline] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 700 >"$DUMP" 2>&1; then
    echo "[hb-absinline] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^REFLOW|^POSFILL' "$DUMP" || true
python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>/dev/null && \
    echo "[hb-absinline] wrote $PNG for eyeballing" || true

# ---- (1) the heading FITS: no prose segment overruns the viewport, and the
#      rightmost inked x stays within the card (maxx small, NOT ~1100 = badge
#      width + full unwrapped heading). The bug produced overflow>=1, maxx>>700.
read -r OVER < <(awk '$1=="REFLOW"{for(i=1;i<=NF;i++) if($i=="overflow") print $(i+1)}' "$DUMP")
read -r MAXX < <(awk '$1=="REFLOW"{for(i=1;i<=NF;i++) if($i=="maxx") print $(i+1)}' "$DUMP")
if [ -n "$OVER" ] && [ "$OVER" -eq 0 ]; then
    echo "[hb-absinline] PASS no prose overflow (overflow=$OVER)"
else
    echo "[hb-absinline] FAIL heading clips — prose overflow (overflow=$OVER)"; fail=1
fi
# card right edge = 650 (x0 50 + width 640 - pad); the heading must not exceed it.
if [ -n "$MAXX" ] && [ "$MAXX" -le 660 ]; then
    echo "[hb-absinline] PASS heading fits within the card (maxx=$MAXX <= 660)"
else
    echo "[hb-absinline] FAIL heading pushed past the card (maxx=$MAXX > 660)"; fail=1
fi

# Field extractor for a POSFILL colour: "<x0> <x1>".
badge_x() {
    awk -v c="$1" '$1=="POSFILL" && $14==c {print $6, $10; exit}' "$DUMP"
}
read -r CARD_X0 CARD_X1 < <(badge_x '#eeeeee')   # card 1
read -r IB_X0   IB_X1   < <(badge_x '#ff0000')   # inline (span) badge
read -r BB_X0   BB_X1   < <(badge_x '#0000ee')   # block (div) badge

need() { [ -n "$1" ] || { echo "[hb-absinline] FAIL: missing box ($2)"; fail=1; return 1; }; return 0; }
need "$CARD_X0" card || true
need "$IB_X0" ibadge || true
need "$BB_X0" bbadge || true

RIGHT_TGT=$((CARD_X1 - 4))     # right:4px inside the card right edge
CENTER=$(( (CARD_X0 + CARD_X1) / 2 ))

# ---- (2) INLINE (span) badge anchored top-RIGHT, not at the heading line start.
if [ "$fail" -eq 0 ] && [ "$IB_X1" -ge "$((RIGHT_TGT - 2))" ] && [ "$IB_X1" -le "$((RIGHT_TGT + 2))" ]; then
    echo "[hb-absinline] PASS inline badge right edge at card_right-4 (x1=$IB_X1 ~= $RIGHT_TGT)"
else
    echo "[hb-absinline] FAIL inline badge not right-anchored (x1=$IB_X1 want ~$RIGHT_TGT)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$IB_X0" -gt "$CENTER" ]; then
    echo "[hb-absinline] PASS inline badge is a right-side chip, NOT at the heading start (x0=$IB_X0 > centre=$CENTER)"
else
    echo "[hb-absinline] FAIL inline badge at the heading line start (x0=$IB_X0 centre=$CENTER)"; fail=1
fi

# ---- (3) BLOCK (div) badge likewise anchored top-RIGHT.
if [ "$fail" -eq 0 ] && [ "$BB_X1" -ge "$((RIGHT_TGT - 2))" ] && [ "$BB_X1" -le "$((RIGHT_TGT + 2))" ]; then
    echo "[hb-absinline] PASS block badge right edge at card_right-4 (x1=$BB_X1 ~= $RIGHT_TGT)"
else
    echo "[hb-absinline] FAIL block badge not right-anchored (x1=$BB_X1 want ~$RIGHT_TGT)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$BB_X0" -gt "$CENTER" ]; then
    echo "[hb-absinline] PASS block badge is a right-side chip (x0=$BB_X0 > centre=$CENTER)"
else
    echo "[hb-absinline] FAIL block badge near the heading start (x0=$BB_X0 centre=$CENTER)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-absinline] RESULT: PASS"
else
    echo "[hb-absinline] RESULT: FAIL"; exit 1
fi
