#!/usr/bin/env bash
# scripts/test_hambrowse_gradient_host.sh — FAST, QEMU-free gate for CSS
# GRADIENT BACKGROUNDS in the native browser engine (lib/web/css/cascade.ad +
# lib/htmlpaint.ad + lib/htmlpage.ad):
#
#   background[-image]: linear-gradient(<angle|to side>, c0, c1[, cN])  and
#   radial-gradient(<shape>, c0, cN) now paint a REAL per-pixel colour ramp
#   across the element's background rectangle (respecting border-radius) instead
#   of leaving the element transparent. The cascade parses the direction + 2..N
#   colour stops into a side registry and packs the ID through the layout record
#   set; htmlpage rasterises it via htmlpaint_fill_gradient.
#
# Ubiquitous on buttons, hero sections and cards, so a regression must fail here
# without a QEMU boot. Builds the text-dump host harness, the pixel backend, and
# confirms native hambrowse still compiles; renders the fixture to a PPM/PNG and
# asserts the interpolated PIXEL VALUES (left red / middle purple / right blue,
# top->bottom fade, a diagonal, a 3-stop midpoint, and a radial centre->edge).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_gradient.html"
mkdir -p "$OUT"
fail=0

echo "[hb-grad] compiling text harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/grad_compile.log"; then
    echo "[hb-grad] FAIL: host harness did not compile"; cat "$OUT/grad_compile.log"; exit 1
fi
echo "[hb-grad] PASS text harness compiled -> $BIN"

echo "[hb-grad] compiling pixel backend for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/grad_gfx.log"; then
    echo "[hb-grad] FAIL: pixel backend did not compile"; cat "$OUT/grad_gfx.log"; exit 1
fi
echo "[hb-grad] PASS pixel backend compiled -> $GFX"

echo "[hb-grad] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/grad_native.log"; then
    echo "[hb-grad] FAIL: native hambrowse did not compile"; cat "$OUT/grad_native.log"; exit 1
fi
echo "[hb-grad] PASS native hambrowse still compiles"

# text-dump sanity: the engine emits one FILL record per gradient block (5).
D0="$OUT/grad_run.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-grad] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
nf=$(grep -c '^FILL ' "$D0")
if [ "$nf" -eq 5 ]; then
    echo "[hb-grad] PASS 5 gradient background boxes registered"
else
    echo "[hb-grad] FAIL expected 5 FILL records, got $nf"; fail=1
fi

# pixel path: render to PPM+PNG, then assert the interpolated pixel values.
PPM="$OUT/grad.ppm"; PNG="$OUT/grad.png"; GD="$OUT/grad_gfx_dump.txt"
if "$GFX" "$FIX" "$PPM" 800 >"$GD" 2>&1; then
    if python3 scripts/hb_gradient_probe.py "$GD" "$PPM"; then
        echo "[hb-grad] PASS interpolated-pixel assertions (linear/diagonal/3-stop/radial)"
    else
        echo "[hb-grad] FAIL interpolated-pixel assertions"; fail=1
    fi
    if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/grad_png.log"; then
        echo "[hb-grad] PASS pixel render -> $PNG ($(file -b "$PNG" 2>/dev/null))"
    else
        echo "[hb-grad] FAIL png conversion"; cat "$OUT/grad_png.log"; fail=1
    fi
else
    echo "[hb-grad] FAIL: pixel render exited non-zero"; cat "$GD"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-grad] RESULT: FAIL"; exit 1; fi
echo "[hb-grad] RESULT: PASS"
