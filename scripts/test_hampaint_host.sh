#!/usr/bin/env bash
# scripts/test_hampaint_host.sh — FAST, QEMU-free host gate for HamPaint, the
# MS-Paint / Tux-Paint-style raster drawing app (lib/hampaintcore.ad — a pure,
# dual-target drawing + compositing core shared by the native app
# user/hampaint.ad and this host harness user/hampaint_host.ad).
#
# It drives the SAME core the native app ships through its real interaction API
# (window-coordinate press/drag/release + button hit-testing) and:
#   * simulates a straight LINE (red), a FILLED RECT (blue) and a flood-FILL
#     (green), asserting the canvas pixels changed at the expected coords AND
#     colours (and that off-shape / boundary pixels are what they should be);
#   * SAVES the canvas as a real PNG (lib/pngwrite) then RE-LOADS it with the
#     pure PNG decoder (lib/png), proving the raster round-trips;
#   * exercises the real chrome hit-test (Clear button, palette swatch);
#   * renders the full app UI (toolbar + palette + canvas) to a PNG a human /
#     agent can LOOK at;
#   * confirms the NATIVE Hamnix build (x86_64-adder-user) still compiles from
#     the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hampaint_host"
PNG="$OUT/hampaint_scratch.png"
UIPPM="$OUT/hampaint_ui.ppm"
UIPNG="$OUT/hampaint_ui.png"
mkdir -p "$OUT"
rm -f "$PNG" "$UIPPM" "$UIPNG"
fail=0

echo "[hampaint-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hampaint_host.ad "$BIN" 2>"$OUT/hp_compile.log"; then
    echo "[hampaint-host] FAIL: host harness did not compile"; cat "$OUT/hp_compile.log"; exit 1
fi
echo "[hampaint-host] PASS host harness compiled -> $BIN"

echo "[hampaint-host] compiling NATIVE hampaint for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hampaint.ad "$OUT/hampaint_native.elf" 2>"$OUT/hp_native.log"; then
    echo "[hampaint-host] FAIL: native hampaint did not compile"; cat "$OUT/hp_native.log"; exit 1
fi
echo "[hampaint-host] PASS native hampaint still compiles"

DUMP="$OUT/hp_dump.txt"
if ! "$BIN" "$PNG" "$UIPPM" >"$DUMP" 2>&1; then
    echo "[hampaint-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

if python3 scripts/ppm_to_png.py "$UIPPM" "$UIPNG" 2>"$OUT/hp_png.log"; then
    echo "[hampaint-host] PASS rendered $UIPNG"
else
    echo "[hampaint-host] FAIL ui png conversion"; cat "$OUT/hp_png.log"; fail=1
fi

assert_eq() {
    # assert_eq KEY EXPECTED MSG
    local got
    got=$(awk -v k="$1" '$1==k{print $2}' "$DUMP")
    if [ "$got" = "$2" ]; then echo "[hampaint-host] PASS $3";
    else echo "[hampaint-host] FAIL $3 (want $1=$2, got '$got')"; fail=1; fi
}

# --- (1) straight LINE painted in RED at the expected canvas pixel ----------
assert_eq LINE_R 220 "line pixel is red (R=220)"
assert_eq LINE_G 30  "line pixel is red (G=30)"
assert_eq LINE_B 30  "line pixel is red (B=30)"
assert_eq OFFLINE_R 255 "a pixel off the line stayed white"

# --- (2) FILLED RECT painted in BLUE at its interior ------------------------
assert_eq RECT_R 40  "filled-rect interior is blue (R=40)"
assert_eq RECT_G 80  "filled-rect interior is blue (G=80)"
assert_eq RECT_B 210 "filled-rect interior is blue (B=210)"

# --- (3) flood FILL turned the background GREEN, respecting boundaries -------
assert_eq FILL_R 40  "flood-fill seed is green (R=40)"
assert_eq FILL_G 170 "flood-fill seed is green (G=170)"
assert_eq FILL_B 60  "flood-fill seed is green (B=60)"
assert_eq FILL_FAR_G 170 "flood-fill reached a distant background pixel"
assert_eq LINE_KEPT_R 220 "the red line survived the fill (boundary honoured)"

# --- (4) SAVE -> PNG round-trip reloads the same raster ---------------------
assert_eq PNG_DECODE 0 "saved PNG decodes cleanly"
assert_eq PNG_W 640 "reloaded PNG width is 640"
assert_eq PNG_H 440 "reloaded PNG height is 440"
assert_eq RT_LINE_R 220 "reloaded line pixel is red"
assert_eq RT_RECT_B 210 "reloaded rect interior is blue"
assert_eq RT_FILL_G 170 "reloaded fill pixel is green"
PNG_LEN=$(awk '$1=="PNG_LEN"{print $2}' "$DUMP")
if [ -n "$PNG_LEN" ] && [ "$PNG_LEN" -gt 1000 ]; then
    echo "[hampaint-host] PASS PNG file written ($PNG_LEN bytes)"
else
    echo "[hampaint-host] FAIL PNG file too small ($PNG_LEN)"; fail=1
fi
if [ -s "$PNG" ]; then echo "[hampaint-host] PASS $PNG on disk";
else echo "[hampaint-host] FAIL PNG not written to $PNG"; fail=1; fi

# --- (5) real chrome hit-test path (Clear button + palette swatch) ----------
assert_eq HIT_CLEAR 5 "press on the Clear button hit the Clear region (code 5)"
assert_eq HIT_PAL 3   "press on a palette swatch hit the palette region (code 3)"

# --- UI PPM header sanity (a P6 image of the whole window) -------------------
assert_eq PPM_OK 1 "full app UI rendered to a PPM"
if head -c 2 "$UIPPM" | grep -qx 'P6'; then
    echo "[hampaint-host] PASS UI PPM carries the P6 magic";
else echo "[hampaint-host] FAIL UI PPM missing P6 magic"; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "[hampaint-host] OVERALL FAIL"; exit 1; fi
echo "[hampaint-host] OVERALL PASS"
