#!/usr/bin/env bash
# scripts/test_hambrowse_flexgrow_host.sh — FAST, QEMU-free gate for RESOLVED
# FLEXIBLE LENGTHS in the native browser engine (lib/web/layout/box.ad): the
# CSS Flexbox `flex-grow` / `flex-basis` / `flex` shorthand distribution.
#
# Before this rung the engine sized every flex column EQUALLY regardless of the
# authored flex factors (the parsed flex-grow/basis values were dead): `flex:2`
# beside `flex:1` still split the row 1:1. Now the container's free space is
# distributed to items IN PROPORTION to their inline flex-grow, over each item's
# flex-basis (explicit) or natural content width (auto):
#
#   (1) three `flex:1` items split the row EVENLY (equal widths).
#   (2) `flex:2` vs `flex:1` split the row ~2:1.
#   (3) `flex:0 0 200px` holds a FIXED main-size while a sibling `flex:1` grows
#       to consume the remaining space.
#
# Boundary (documented, asserted only via the inline-style fixture): flex-grow
# is read from each child's INLINE style="…". Class-resolved flex (`.col{flex:1}`)
# still falls back to the equal-column approximation, and flex-shrink on overflow
# is not yet honoured. flex-direction:column still stacks as normal block flow.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
mkdir -p "$OUT"

echo "[hb-flexgrow] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexgrow] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexgrow] PASS host harness compiled -> $BIN"

echo "[hb-flexgrow] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexgrow] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexgrow] PASS native hambrowse still compiles"

fail=0
D="$OUT/flexgrow.txt"
"$BIN" tests/fixtures/hambrowse_flexgrow.html 800 >"$D" 2>&1 \
    || { echo "[hb-flexgrow] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# Width (px) of the FIRST FILL painted in a given colour: FILL <t> <b> <lx> <rx> #rgb <z>
fw() { grep -E "^FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #$1( |\$)" "$D" | awk '{print $5-$4}' | head -1; }

# ---- (1) three flex:1 columns are EQUAL ------------------------------------
EQA=$(fw aa1111); EQB=$(fw 22bb22); EQC=$(fw 3333cc)
echo "[hb-flexgrow] flex:1 x3 widths: EQa=$EQA EQb=$EQB EQc=$EQC"
if [ -z "$EQA" ] || [ -z "$EQB" ] || [ -z "$EQC" ]; then
    echo "[hb-flexgrow] FAIL: missing an equal-split fill"; cat "$D"; exit 1
fi
d1=$(( EQA - EQB )); d2=$(( EQB - EQC ))
[ "$d1" -lt 0 ] && d1=$(( -d1 )); [ "$d2" -lt 0 ] && d2=$(( -d2 ))
if [ "$EQA" -gt 150 ] && [ "$d1" -le 20 ] && [ "$d2" -le 20 ]; then
    echo "[hb-flexgrow] PASS three flex:1 items split the row EVENLY"
else
    echo "[hb-flexgrow] FAIL flex:1 items not equal (EQa=$EQA EQb=$EQB EQc=$EQC)"; fail=1
fi

# ---- (2) flex:2 vs flex:1 splits ~2:1 --------------------------------------
GRW=$(fw dd4444); GRN=$(fw 55ee55)
echo "[hb-flexgrow] flex:2/flex:1 widths: wide=$GRW narrow=$GRN"
if [ -z "$GRW" ] || [ -z "$GRN" ]; then
    echo "[hb-flexgrow] FAIL: missing a grow fill"; cat "$D"; exit 1
fi
# wide should be clearly larger than narrow, roughly double (allow box padding).
if [ "$GRW" -gt "$GRN" ] && [ "$(( GRW * 10 ))" -gt "$(( GRN * 16 ))" ] \
   && [ "$(( GRW * 10 ))" -lt "$(( GRN * 24 ))" ]; then
    echo "[hb-flexgrow] PASS flex:2 item is ~2x the flex:1 item"
else
    echo "[hb-flexgrow] FAIL flex:2/flex:1 not ~2:1 (wide=$GRW narrow=$GRN)"; fail=1
fi

# ---- (3) flex-basis fixed + growing sibling --------------------------------
BSF=$(fw 661166); BSG=$(fw 77dd77)
echo "[hb-flexgrow] flex:0 0 200px / flex:1 widths: fixed=$BSF grow=$BSG"
if [ -z "$BSF" ] || [ -z "$BSG" ]; then
    echo "[hb-flexgrow] FAIL: missing a basis fill"; cat "$D"; exit 1
fi
# the fixed item stays near its 200px basis; the flex:1 sibling grows well past it.
if [ "$BSF" -ge 190 ] && [ "$BSF" -le 240 ] && [ "$BSG" -gt 320 ] && [ "$BSG" -gt "$BSF" ]; then
    echo "[hb-flexgrow] PASS flex-basis:200px stays fixed while flex:1 fills the rest"
else
    echo "[hb-flexgrow] FAIL flex-basis distribution wrong (fixed=$BSF grow=$BSG)"; fail=1
fi

# ---- control: the three variants must NOT all be identical -----------------
if [ "$EQA" != "$GRW" ] && [ "$GRW" != "$GRN" ]; then
    echo "[hb-flexgrow] PASS flex factors render DISTINCT column widths (no equal-column collapse)"
else
    echo "[hb-flexgrow] FAIL flex factors collapsed to one width"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-flexgrow] RESULT: FAIL"; exit 1
fi
echo "[hb-flexgrow] RESULT: PASS"
