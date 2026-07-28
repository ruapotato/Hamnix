#!/usr/bin/env bash
# scripts/test_hambrowse_nesthdr_host.sh — FAST, QEMU-free gate proving Chrome-
# parity for LEGACY TABLE-LAYOUT HEADERS (the Hacker News orange nav bar pattern):
#
#   a NESTED `<table width="100%">` STRETCHES to fill its PARENT CELL — like
#   Chrome — instead of shrinking to its content and stranding a right-aligned
#   cell in the middle of the bar with the links wrapping to a 2nd line. HN wraps
#   its header in `<td bgcolor=#ff6600><table width=100%>…</table></td>`; without
#   the fix the inner nav table shrank to content, so `login`/`sign in` sat mid-bar
#   and `Hacker News new | past | … | submit` wrapped. Fixed by letting a nested
#   table honour its width attribute, bounded to the parent cell's right edge.
#
# The gfx driver (user/hambrowse_host_gfx.ad) reports each painted background box
# as `POSFILL <i> z <z> x0 .. y0 .. x1 .. y1 .. col #RRGGBB pix #RRGGBB` and the
# canvas size as `CANVAS <w> <h>`. This gate reads those deterministic lines — no
# network, no QEMU, milliseconds. Built with the frozen Python seed compiler.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-nesthdr] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/nesthdr_compile.log"; then
    echo "[hb-nesthdr] FAIL: driver did not compile"; cat "$OUT/nesthdr_compile.log"; exit 1
fi
echo "[hb-nesthdr] PASS pixel backend compiled"

echo "[hb-nesthdr] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/nesthdr_native.log"; then
    echo "[hb-nesthdr] FAIL: native hambrowse did not compile"; cat "$OUT/nesthdr_native.log"; exit 1
fi
echo "[hb-nesthdr] PASS native hambrowse still compiles"

# Helper: right edge (x1) of the FIRST background box of colour $2 in dump $1.
blue_x1() {
    awk -v want="$2" '/^POSFILL/{c="";x1="";for(i=1;i<=NF;i++){if($i=="col")c=$(i+1);if($i=="x1")x1=$(i+1)} if(c==want){print x1; exit}}' "$1"
}

# --- NESTED width="100%" table fills its parent cell --------------------------
VW=640
FIX="tests/fixtures/hambrowse_nesthdr.html"
DUMP="$OUT/nesthdr_dump.txt"
"$BIN" "$FIX" "$OUT/nesthdr.ppm" "$VW" >"$DUMP" 2>&1 || { echo "[hb-nesthdr] FAIL: render nonzero"; cat "$DUMP"; exit 1; }
WBLUE=$(blue_x1 "$DUMP" "#2222ff")
echo "[hb-nesthdr] nested width=100% right-cell (#2222ff) right edge x1=${WBLUE:-?} (viewport ${VW})"
# The right cell must reach near the viewport right edge (>= 560 of 640): the
# nested table stretched to fill the full-width parent cell.
if [ -n "${WBLUE:-}" ] && [ "$WBLUE" -ge 560 ]; then
    echo "[hb-nesthdr] PASS nested width=100% table stretched to fill the parent cell (x1=$WBLUE)"
else
    echo "[hb-nesthdr] FAIL nested width=100% table did not fill its cell (x1=${WBLUE:-none}, want >= 560)"; fail=1
fi

# --- CONTROL: SAME markup, NO width attr => stays content-sized ----------------
FIXA="tests/fixtures/hambrowse_nesthdr_auto.html"
DUMPA="$OUT/nesthdr_auto_dump.txt"
"$BIN" "$FIXA" "$OUT/nesthdr_auto.ppm" "$VW" >"$DUMPA" 2>&1
ABLUE=$(blue_x1 "$DUMPA" "#2222ff")
echo "[hb-nesthdr] control (no width) right-cell right edge x1=${ABLUE:-?}"
if [ -n "${ABLUE:-}" ] && [ "$ABLUE" -lt 400 ]; then
    echo "[hb-nesthdr] PASS un-sized control nested table stays content-width (x1=$ABLUE) — attribute drives the stretch"
else
    echo "[hb-nesthdr] FAIL control nested table unexpectedly wide (x1=${ABLUE:-none}, want < 400)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-nesthdr] RESULT: PASS"
else
    echo "[hb-nesthdr] RESULT: FAIL"; exit 1
fi
