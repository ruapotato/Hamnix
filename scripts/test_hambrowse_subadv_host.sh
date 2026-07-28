#!/usr/bin/env bash
# scripts/test_hambrowse_subadv_host.sh — FAST, QEMU-free gate proving Chrome-
# parity for SUBPIXEL body-text advance accumulation (round 18).
#
# Round 16 gave hambrowse an accurate per-glyph Liberation Sans advance table
# (lib/web/font_adv.ad). But 16px BODY text still summed those advances as
# per-glyph INTEGER pixels (`FU_ADV_MIN_PX` gate = 20, above body size), so a
# long line drifted up to N*0.5px from Chrome by accumulating per-glyph rounding.
# ROUND 18 lowers the crossover to 16 so 16px body accumulates in FONT UNITS and
# rounds the running pen ONCE — matching Chrome, whose rendered run width equals
# its subpixel canvas measureText (verified: getBoundingClientRect == measureText,
# Chrome does NOT hint each body glyph advance to an integer).
#
# Measured vs `/usr/bin/chromium` at 16px (getBoundingClientRect):
#   line 1 "The quick brown fox ... today now"        Chrome 437.58px
#           per-glyph INTEGER (base) drew 435 (−2.6, drift UNDER)
#           fu accumulation (fix)   drew 437 (−0.6, Chrome-matched)
#   line 2 "Association of Widely ... Typefaces"       Chrome 467.78px
#           per-glyph INTEGER (base) drew 470 (+2.2, drift OVER)
#           fu accumulation (fix)   drew 468 (−0.2, Chrome-matched)
# The two lines drift in OPPOSITE directions under the integer model (the residual
# is a per-line accumulation of per-glyph rounding), and fu accumulation centres
# BOTH on Chrome — so the gate windows below (base misses each on the far side)
# can only pass with the subpixel-accumulation model.
#
# The gate reads each painted black run's right edge (X+W) from the gfx driver's
# `dumpops` mode. Deterministic, no network, milliseconds.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-subadv] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/subadv_compile.log"; then
    echo "[hb-subadv] FAIL: driver did not compile"; cat "$OUT/subadv_compile.log"; exit 1
fi

FIX="tests/fixtures/hambrowse_subadv.html"
DUMP="$OUT/subadv_ops.txt"
"$BIN" "$FIX" "$OUT/subadv.ppm" 1000 dumpops >"$DUMP" 2>&1 || {
    echo "[hb-subadv] FAIL: render nonzero"; cat "$DUMP"; exit 1; }

# The two black (#000000ff) text runs, in document order: end-x = X + W.
mapfile -t ENDS < <(awk '/^OP covmask/ && $7=="#000000ff" {print $3 + $5}' "$DUMP")

if [ "${#ENDS[@]}" -lt 2 ]; then
    echo "[hb-subadv] FAIL: expected 2 body runs, found ${#ENDS[@]}"; cat "$DUMP"; exit 1
fi
E1="${ENDS[0]}"; E2="${ENDS[1]}"
echo "[hb-subadv] line1 end-x=${E1}px (Chrome ~438; base ~435 drifts under)"
echo "[hb-subadv] line2 end-x=${E2}px (Chrome ~468; base ~470 drifts over)"

# fu accumulation lands both within ±1px of Chrome; the integer base misses each
# on the opposite side (435 < 436, 470 > 469).
if [ "$E1" -ge 436 ] && [ "$E1" -le 439 ]; then
    echo "[hb-subadv] PASS line1 subpixel-accumulated (${E1}px in 436..439; base 435 fails under)"
else
    echo "[hb-subadv] FAIL line1 advance off (${E1}px; want 436..439 — base ~435 per-glyph-int under-runs)"; fail=1
fi
if [ "$E2" -ge 466 ] && [ "$E2" -le 469 ]; then
    echo "[hb-subadv] PASS line2 subpixel-accumulated (${E2}px in 466..469; base 470 fails over)"
else
    echo "[hb-subadv] FAIL line2 advance off (${E2}px; want 466..469 — base ~470 per-glyph-int over-runs)"; fail=1
fi

# --- native hambrowse still compiles ------------------------------------------
if python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse.ad -o "$OUT/hambrowse_native_subadv" 2>"$OUT/subadv_native.log"; then
    echo "[hb-subadv] PASS native hambrowse compiles"
else
    echo "[hb-subadv] FAIL native hambrowse did not compile"; cat "$OUT/subadv_native.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-subadv] RESULT: PASS"
else
    echo "[hb-subadv] RESULT: FAIL"; exit 1
fi
