#!/usr/bin/env bash
# scripts/test_hambrowse_flexinputfill_host.sh — FAST, QEMU-free gate proving a
# `flex:1` item GROWS TO FILL a flex row even when a trailing sibling hangs a
# CLASS-hidden (`display:none`) popup subtree off itself. Regression guard for
# google.com's search bar: the hidden AI-Mode / tools menu, counted as content
# width, ballooned the trailing control to ~35000px so the `flex:1` search input
# got zero free space and rendered as a tiny box crammed to the right ("a box
# inside the box"). The flex child natural-width measurer now elides display:none
# descendants (cascade + inline), so the field grows across the bar.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
OUT="build/host"; BIN="$OUT/hambrowse_host"; mkdir -p "$OUT"
echo "[hb-flexinputfill] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexinputfill] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexinputfill] PASS host harness compiled -> $BIN"
echo "[hb-flexinputfill] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexinputfill] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexinputfill] PASS native hambrowse still compiles"
fail=0
D="$OUT/flexinputfill.txt"
"$BIN" tests/fixtures/hambrowse_flexinputfill.html 800 >"$D" 2>&1 \
    || { echo "[hb-flexinputfill] FAIL: render exited non-zero"; cat "$D"; exit 1; }
# FILL <t> <b> <lx> <rx> #rgb ...
fw() { grep -E "^FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #$1( |\$)" "$D" | awk '{print $5-$4}' | head -1; }
flx() { grep -E "^FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #$1( |\$)" "$D" | awk '{print $4}' | head -1; }
GROW=$(fw 22bb22); AIW=$(fw 3333cc); AILX=$(flx 3333cc)
echo "[hb-flexinputfill] flex:1 field width=$GROW  trailing width=$AIW lx=$AILX"
if [ -z "$GROW" ] || [ -z "$AIW" ] || [ -z "$AILX" ]; then
    echo "[hb-flexinputfill] FAIL: missing a fill"; cat "$D"; exit 1
fi
# the flex:1 field must GROW to fill most of the 800px row ...
if [ "$GROW" -gt 400 ]; then
    echo "[hb-flexinputfill] PASS flex:1 field grew to fill the bar ($GROW px)"
else
    echo "[hb-flexinputfill] FAIL flex:1 field did not fill (width=$GROW) — hidden popup measured?"; fail=1
fi
# ... and the hidden-popup sibling stays small AND sits at the right edge.
if [ "$AIW" -lt 200 ] && [ "$AILX" -gt 600 ]; then
    echo "[hb-flexinputfill] PASS trailing control stays small at the right edge"
else
    echo "[hb-flexinputfill] FAIL trailing control mis-sized/placed (w=$AIW lx=$AILX)"; fail=1
fi
if [ "$fail" -ne 0 ]; then echo "[hb-flexinputfill] RESULT: FAIL"; exit 1; fi
echo "[hb-flexinputfill] RESULT: PASS"
