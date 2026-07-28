#!/usr/bin/env bash
# scripts/test_hambrowse_h1noborder_host.sh — FAST, QEMU-free gate for an
# on-device QA rendering bug: hambrowse painted a SPURIOUS thin full-width
# horizontal rule directly beneath every <h1>/<h2>, even when the page declares
# NO border/underline/hr. It looked like an unwanted default `border-bottom`.
#
# Root cause: the engine's legacy per-row "heading underline" flag (row_rule==1,
# set for h1/h2 in the DOM layer) was painted by lib/htmlpage.ad as a light-grey
# hairline below the heading. Real browsers give a heading only larger BOLD type
# + margins — NO default border. The fix stops painting the rk==1 rule (a genuine
# CSS heading border still draws via the box/border pass); the real <hr> divider
# (rk==2) is untouched.
#
# This gate renders a plain "<h1> + paragraph + <h2> + paragraph" fixture (no CSS
# borders) to a PPM/PNG on the host pixel backend and asserts, at the PIXEL
# level, that the empty band just below each heading carries NO full-width dark
# rule — while the heading text itself still renders large + inked (bold/large
# not regressed). NO QEMU.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_h1noborder.html"
mkdir -p "$OUT"
fail=0

echo "[hb-h1nb] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/h1nb_gfx.log"; then
    echo "[hb-h1nb] FAIL: pixel backend did not compile"; cat "$OUT/h1nb_gfx.log"; exit 1
fi
echo "[hb-h1nb] PASS pixel backend compiled -> $GFX"

echo "[hb-h1nb] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/h1nb_native.log"; then
    echo "[hb-h1nb] FAIL: native hambrowse did not compile"; cat "$OUT/h1nb_native.log"; exit 1
fi
echo "[hb-h1nb] PASS native hambrowse still compiles"

PPM="$OUT/h1nb.ppm"; PNG="$OUT/h1nb.png"; GD="$OUT/h1nb_gfx_dump.txt"
if "$GFX" "$FIX" "$PPM" 800 >"$GD" 2>&1; then
    if python3 scripts/hb_h1noborder_probe.py "$GD" "$PPM"; then
        echo "[hb-h1nb] PASS no spurious heading underline (pixel band clean)"
    else
        echo "[hb-h1nb] FAIL spurious rule / heading regression"; fail=1
    fi
    if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/h1nb_png.log"; then
        echo "[hb-h1nb] PASS pixel render -> $PNG ($(file -b "$PNG" 2>/dev/null))"
    else
        echo "[hb-h1nb] FAIL png conversion"; cat "$OUT/h1nb_png.log"; fail=1
    fi
else
    echo "[hb-h1nb] FAIL: pixel render exited non-zero"; cat "$GD"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-h1nb] RESULT: FAIL"; exit 1; fi
echo "[hb-h1nb] RESULT: PASS"
