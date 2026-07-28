#!/usr/bin/env bash
# scripts/test_hambrowse_button_host.sh — FAST, QEMU-free render-to-PNG gate for
# the default <button> rendering in the native browser engine, the on-device QA
# defect where a right-aligned `<button>Sign up</button>` inside a display:flex
# nav bar rendered NOTHING (no box, no label). A <button> must now paint a real
# push-button: a button-grey face + a 1px border + its label, and it participates
# in flex layout as an item (so a nav CTA lands at the right).
#
# Fixture: a `display:flex; justify-content:space-between` <nav> with three links
# and a trailing `<button>Sign up</button>`. Asserts on the rendered PPM via
# scripts/hb_button_probe.py:
#   * button-grey FACE pixels are present (the button is drawn, not blank)
#   * BORDER stroke pixels are present (it reads as a real bordered control)
#   * the button sits on the RIGHT half of the canvas (flex CTA placement)
#
# NOTE: actual click/submit dispatch is a separate, deferred concern handled by
# the DOM/event layer; this gate covers the VISUAL button box only.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_button.html"
DUMP="$OUT/button_dump.txt"
PPM="$OUT/button.ppm"
PNG="$OUT/button.png"
PROBE="$OUT/button_probe.txt"
WIDTH=760
mkdir -p "$OUT"
fail=0

echo "[hb-button] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/button_compile.log"; then
    echo "[hb-button] FAIL: driver did not compile"; cat "$OUT/button_compile.log"; exit 1
fi
echo "[hb-button] PASS pixel backend compiled -> $BIN"

echo "[hb-button] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/button_native.log"; then
    echo "[hb-button] FAIL: native hambrowse did not compile"; cat "$OUT/button_native.log"; exit 1
fi
echo "[hb-button] PASS native hambrowse still compiles"

echo "[hb-button] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" "$WIDTH" >"$DUMP" 2>&1; then
    echo "[hb-button] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^SEGTXT|^POSFILL' "$DUMP" || true
python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>/dev/null && \
    echo "[hb-button] wrote $PNG for eyeballing" || true

if ! python3 scripts/hb_button_probe.py "$PPM" >"$PROBE" 2>&1; then
    echo "[hb-button] FAIL: probe errored"; cat "$PROBE"; exit 1
fi
cat "$PROBE"

read -r _ CW CH < <(grep -E '^DIMS' "$PROBE")
read -r _ FN FX0 FX1 FY0 FY1 < <(grep -E '^FACE' "$PROBE")
read -r _ BN BX0 BX1 < <(grep -E '^BORDER' "$PROBE")
FN="${FN:-0}"; BN="${BN:-0}"

# (1) The button FACE is painted (visible box, not the old blank).
if [ "$FN" -gt 40 ]; then
    echo "[hb-button] PASS button face is rendered (${FN} button-grey px)"
else
    echo "[hb-button] FAIL button face missing/too small (${FN} px) — button not drawn"; fail=1
fi

# (2) A border stroke frames it (reads as a real control, not a plain text run).
if [ "$fail" -eq 0 ] && [ "$BN" -gt 8 ]; then
    echo "[hb-button] PASS button border stroke present (${BN} px)"
else
    echo "[hb-button] FAIL button border stroke missing (${BN} px)"; fail=1
fi

# (3) The CTA lands on the RIGHT half of the nav (flex-item placement), not at
#     the far left over the links.
if [ "$fail" -eq 0 ]; then
    HALF=$((CW / 2))
    if [ -n "${FX0:-}" ] && [ "$FX0" -gt "$HALF" ]; then
        echo "[hb-button] PASS button sits on the right (face x0=$FX0 > half=$HALF)"
    else
        echo "[hb-button] FAIL button not right-aligned (face x0=${FX0:-?} half=$HALF)"; fail=1
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-button] RESULT: PASS"
else
    echo "[hb-button] RESULT: FAIL"; exit 1
fi
