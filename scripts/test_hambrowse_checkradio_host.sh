#!/usr/bin/env bash
# scripts/test_hambrowse_checkradio_host.sh — FAST, QEMU-free gate for the pixel
# SHAPES of <input type=checkbox> / <input type=radio> in the native browser's
# real pixel painter (lib/htmlpage.ad + lib/htmlpaint.ad + lib/web/dom/forms.ad).
#
# W3C HTML forms: a checkbox is a SQUARE box (checked => accent fill + a white
# tick); a radio is a CIRCLE (checked => a filled accent centre dot). Previously
# both rendered as bracketed ASCII ('[x]' / '(*)'); now they draw as real
# widget shapes on the framebuffer, distinct from text fields and each other.
#
# The gate renders the fixture through the REAL pixel backend (hambrowse_host_gfx
# -> PPM) and probes the left widget column: four controls, top to bottom, must
# classify as checkbox(SQUARE) checked, checkbox unchecked, radio(CIRCLE)
# checked, radio unchecked — the SHAPE from the box's top-edge ink width and the
# CHECKED state from the accent fill's presence. Also builds the native browser.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
FIX="tests/fixtures/hambrowse_checkradio.html"
mkdir -p "$OUT"

echo "[hb-checkradio] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$OUT/hambrowse_gfx" 2>"$OUT/gfx_compile.log"; then
    echo "[hb-checkradio] FAIL: pixel backend did not compile"; cat "$OUT/gfx_compile.log"; exit 1
fi
echo "[hb-checkradio] PASS pixel backend compiled"

echo "[hb-checkradio] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-checkradio] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-checkradio] PASS native hambrowse still compiles"

PPM="$OUT/checkradio.ppm"
if ! "$OUT/hambrowse_gfx" "$FIX" "$PPM" 640; then
    echo "[hb-checkradio] FAIL: render exited non-zero"; exit 1
fi

fail=0
probe=$(python3 scripts/hb_checkradio_probe.py "$PPM")
echo "$probe" | sed 's/^/[hb-checkradio]   /'

line() { echo "$probe" | grep -E "^CTRL i=$1 " | head -1; }
field() { echo "$1" | sed -n "s/.* $2=\\([A-Za-z0-9]*\\).*/\\1/p"; }

n=$(echo "$probe" | grep -c '^CTRL ')
if [ "$n" -ne 4 ]; then
    echo "[hb-checkradio] FAIL expected 4 controls, got $n"; fail=1
fi

c0=$(line 0); c1=$(line 1); c2=$(line 2); c3=$(line 3)

# control 0: checked CHECKBOX -> SQUARE, checked
if [ "$(field "$c0" shape)" = "SQUARE" ] && [ "$(field "$c0" checked)" = "1" ]; then
    echo "[hb-checkradio] PASS control 0 = checkbox SQUARE, checked"
else
    echo "[hb-checkradio] FAIL control 0 ($c0)"; fail=1
fi

# control 1: unchecked CHECKBOX -> SQUARE, not checked
if [ "$(field "$c1" shape)" = "SQUARE" ] && [ "$(field "$c1" checked)" = "0" ]; then
    echo "[hb-checkradio] PASS control 1 = checkbox SQUARE, unchecked"
else
    echo "[hb-checkradio] FAIL control 1 ($c1)"; fail=1
fi

# control 2: checked RADIO -> CIRCLE, checked
if [ "$(field "$c2" shape)" = "CIRCLE" ] && [ "$(field "$c2" checked)" = "1" ]; then
    echo "[hb-checkradio] PASS control 2 = radio CIRCLE, checked"
else
    echo "[hb-checkradio] FAIL control 2 ($c2)"; fail=1
fi

# control 3: unchecked RADIO -> CIRCLE, not checked
if [ "$(field "$c3" shape)" = "CIRCLE" ] && [ "$(field "$c3" checked)" = "0" ]; then
    echo "[hb-checkradio] PASS control 3 = radio CIRCLE, unchecked"
else
    echo "[hb-checkradio] FAIL control 3 ($c3)"; fail=1
fi

# the two shape kinds must be DISTINCT (checkbox square != radio circle)
if [ "$(field "$c0" shape)" != "$(field "$c2" shape)" ]; then
    echo "[hb-checkradio] PASS checkbox SQUARE is a distinct shape from radio CIRCLE"
else
    echo "[hb-checkradio] FAIL checkbox and radio drew the same shape"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-checkradio] ALL PASS — checkbox/radio pixel shapes + checked states"
    exit 0
fi
echo "[hb-checkradio] FAILURES above"; exit 1
