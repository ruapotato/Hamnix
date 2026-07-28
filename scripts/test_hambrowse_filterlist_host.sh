#!/usr/bin/env bash
# scripts/test_hambrowse_filterlist_host.sh — FAST, QEMU-free gate proving CSS
# `filter` FUNCTION LISTS (chaining) + the hue-rotate() function (Filter Effects
# Module L1) in the graphical hambrowse backend.
#
# Round-3 landed single CSS filters but a space-separated LIST collapsed to the
# FIRST recognised function (`filter: grayscale(1) brightness(1.2)` dropped the
# brightness) and hue-rotate() was absent. This round interns a chained filter
# into a small registry (cascade FILT_LIST_MARK|index) and lib/htmlpage applies
# each function IN ORDER over the box rect (true CSS chaining — each reads the
# previous result); a SINGLE function still returns its bare packed int (byte-
# identical legacy path). hue-rotate(Ndeg) is a real luma-preserving colour-matrix
# rotation in lib/htmlpaint (integer sin/cos).
#
# The gfx driver renders the fixture to a P6 PPM; hb_filterlist_probe.py scans the
# WHOLE framebuffer and proves each box's ORIGINAL colour is gone and the EXPECTED
# chained / hue-rotated colour is present (and that a chain does NOT stop at its
# first function). It also confirms the NATIVE hambrowse still compiles.
#
# Built with the frozen Python seed compiler. PNG conversion is stdlib-only.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"

echo "[hb-filterlist] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/filterlist_compile.log"; then
    echo "[hb-filterlist] FAIL: driver did not compile"; cat "$OUT/filterlist_compile.log"; exit 1
fi
echo "[hb-filterlist] PASS pixel backend compiled"

echo "[hb-filterlist] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/filterlist_native.log"; then
    echo "[hb-filterlist] FAIL: native hambrowse did not compile"; cat "$OUT/filterlist_native.log"; exit 1
fi
echo "[hb-filterlist] PASS native hambrowse still compiles"

FIX="tests/fixtures/hambrowse_filterlist.html"
PPM="$OUT/filterlist.ppm"
PNG="$OUT/filterlist.png"
W=400

echo "[hb-filterlist] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" "$W" >"$OUT/filterlist_dump.txt" 2>&1; then
    echo "[hb-filterlist] FAIL: render exited non-zero"; cat "$OUT/filterlist_dump.txt"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 && echo "[hb-filterlist] wrote $PNG"

if python3 scripts/hb_filterlist_probe.py "$PPM"; then
    echo "[hb-filterlist] RESULT: PASS"
else
    echo "[hb-filterlist] RESULT: FAIL"; exit 1
fi
