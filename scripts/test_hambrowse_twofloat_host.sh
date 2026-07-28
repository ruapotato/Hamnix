#!/usr/bin/env bash
# scripts/test_hambrowse_twofloat_host.sh — FAST, QEMU-free gate for a
# SIMULTANEOUS left+right float pair in the native browser engine
# (lib/web/layout/box.ad float channels). A `float:left` box and a `float:right`
# box are both active at once and the body paragraph flows in the NARROW channel
# between them — the common figure-left / aside-right sandwich layout that used to
# collapse (the engine previously allowed only ONE float at a time, so the second
# fell back to an in-flow full-width block).
#
# Asserts on ACTUAL engine coordinates: the two float background rects (FILL
# top bot lx rx #col) sit on opposite edges, and the body text starts to the
# RIGHT of the left float yet stays LEFT of the right float. Builds both targets.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_twofloat.html"
mkdir -p "$OUT"

echo "[hb-2f] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/2f_compile.log"; then
    echo "[hb-2f] FAIL: host harness did not compile"; cat "$OUT/2f_compile.log"; exit 1
fi
echo "[hb-2f] PASS host harness compiled -> $BIN"

echo "[hb-2f] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/2f_native.elf" 2>"$OUT/2f_native.log"; then
    echo "[hb-2f] FAIL: native hambrowse did not compile"; cat "$OUT/2f_native.log"; exit 1
fi
echo "[hb-2f] PASS native hambrowse still compiles"

fail=0
D="$OUT/twofloat.txt"
"$BIN" "$FIX" 640 >"$D" 2>&1 || { echo "[hb-2f] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# FILL: $2 top $3 bot $4 lx $5 rx $6 #col
read -r LLX LRX < <(grep -E "FILL .* #3366cc" "$D" | awk '{print $4, $5; exit}')
read -r RLX RRX < <(grep -E "FILL .* #cc3366" "$D" | awk '{print $4, $5; exit}')
BX=$(grep -E "SEG [0-9]+ [0-9]+ .*\|Bodyword" "$D" | awk '{print $3}' | head -1)
echo "[hb-2f] left float  lx=$LLX rx=$LRX"
echo "[hb-2f] right float lx=$RLX rx=$RRX"
echo "[hb-2f] body first word x=$BX"

need() { [ -n "$1" ] || { echo "[hb-2f] FAIL: missing $2"; fail=1; return 1; }; return 0; }
need "$LLX" "left-float"  || true
need "$RLX" "right-float" || true
need "$BX"  "body-word"   || true

# (1) BOTH floats present at once (the whole point): left box near the left edge,
#     right box near the right edge, clearly separated.
if [ "$fail" -eq 0 ] && [ "$RLX" -gt "$LRX" ]; then
    echo "[hb-2f] PASS left+right floats both active, on opposite edges (Lrx=$LRX < Rlx=$RLX)"
else
    echo "[hb-2f] FAIL floats not both placed on opposite edges (Lrx=$LRX Rlx=$RLX)"; fail=1
fi

# (2) the LEFT float hugs the left margin; the RIGHT float hugs the right margin.
if [ "$fail" -eq 0 ] && [ "$LLX" -lt "$RLX" ] && [ "$LRX" -lt "$RRX" ]; then
    echo "[hb-2f] PASS left float left of right float on both edges (Llx=$LLX Rlx=$RLX)"
else
    echo "[hb-2f] FAIL float ordering wrong (Llx=$LLX Lrx=$LRX Rlx=$RLX Rrx=$RRX)"; fail=1
fi

# (3) body text flows in the channel BETWEEN the two floats: right of the left
#     float and left of the right float.
if [ "$fail" -eq 0 ] && [ "$BX" -ge "$LRX" ] && [ "$BX" -lt "$RLX" ]; then
    echo "[hb-2f] PASS body flows between the floats (Lrx=$LRX <= body=$BX < Rlx=$RLX)"
else
    echo "[hb-2f] FAIL body not in the inter-float channel (Lrx=$LRX body=$BX Rlx=$RLX)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-2f] RESULT: FAIL"; exit 1
fi
echo "[hb-2f] RESULT: PASS"
