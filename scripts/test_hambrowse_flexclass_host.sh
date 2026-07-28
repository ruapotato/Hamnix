#!/usr/bin/env bash
# scripts/test_hambrowse_flexclass_host.sh — FAST, QEMU-free gate for CLASS /
# STYLESHEET-resolved flex sizing in the native browser engine
# (lib/web/layout/box.ad + lib/web/css/cascade.ad).
#
# Prior rungs read flex-grow / flex-shrink / flex-basis from each child's INLINE
# style="flex…" only; a class rule `.col{flex:1}` fell back to the equal-column
# approximation, so real sites (which style flex items by class) sized wrong.
# Now the per-child flex pre-scan resolves the CASCADE winners (m_flexg/s/b) for
# each child element and only lets an inline style override them. This fixture
# carries NO inline flex at all — every factor comes from the <style> block:
#
#   (1) three `.col{flex:1}` items split the row EVENLY (equal widths).
#   (2) `.wide{flex:2}` beside `.col{flex:1}` splits the row ~2:1.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
mkdir -p "$OUT"

echo "[hb-flexclass] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexclass] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexclass] PASS host harness compiled -> $BIN"

echo "[hb-flexclass] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexclass] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexclass] PASS native hambrowse still compiles"

fail=0
D="$OUT/flexclass.txt"
"$BIN" tests/fixtures/hambrowse_flexclass.html 800 >"$D" 2>&1 \
    || { echo "[hb-flexclass] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# Width (px) of the FIRST FILL painted in a given colour: FILL <t> <b> <lx> <rx> #rgb <z>
fw() { grep -E "^FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #$1( |\$)" "$D" | awk '{print $5-$4}' | head -1; }

# ---- (1) three .col{flex:1} columns are EQUAL ------------------------------
EQA=$(fw aa1111); EQB=$(fw 22bb22); EQC=$(fw 3333cc)
echo "[hb-flexclass] .col{flex:1} x3 widths: EQa=$EQA EQb=$EQB EQc=$EQC"
if [ -z "$EQA" ] || [ -z "$EQB" ] || [ -z "$EQC" ]; then
    echo "[hb-flexclass] FAIL: missing an equal-split fill"; cat "$D"; exit 1
fi
d1=$(( EQA - EQB )); d2=$(( EQB - EQC ))
[ "$d1" -lt 0 ] && d1=$(( -d1 )); [ "$d2" -lt 0 ] && d2=$(( -d2 ))
if [ "$EQA" -gt 150 ] && [ "$d1" -le 20 ] && [ "$d2" -le 20 ]; then
    echo "[hb-flexclass] PASS three .col{flex:1} items split the row EVENLY"
else
    echo "[hb-flexclass] FAIL .col{flex:1} not equal (EQa=$EQA EQb=$EQB EQc=$EQC)"; fail=1
fi

# ---- (2) .wide{flex:2} vs .col{flex:1} splits ~2:1 -------------------------
GRW=$(fw dd4444); GRN=$(fw 55ee55)
echo "[hb-flexclass] .wide{flex:2}/.col{flex:1} widths: wide=$GRW narrow=$GRN"
if [ -z "$GRW" ] || [ -z "$GRN" ]; then
    echo "[hb-flexclass] FAIL: missing a grow fill"; cat "$D"; exit 1
fi
if [ "$GRW" -gt "$GRN" ] && [ "$(( GRW * 10 ))" -gt "$(( GRN * 16 ))" ] \
   && [ "$(( GRW * 10 ))" -lt "$(( GRN * 24 ))" ]; then
    echo "[hb-flexclass] PASS .wide{flex:2} item is ~2x the .col{flex:1} item"
else
    echo "[hb-flexclass] FAIL .wide/.col not ~2:1 (wide=$GRW narrow=$GRN)"; fail=1
fi

# ---- control: class factors must NOT collapse to one equal-column width ----
if [ "$EQA" != "$GRW" ] && [ "$GRW" != "$GRN" ]; then
    echo "[hb-flexclass] PASS class flex factors render DISTINCT widths (no equal-column collapse)"
else
    echo "[hb-flexclass] FAIL class flex factors collapsed to one width"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-flexclass] RESULT: FAIL"; exit 1
fi
echo "[hb-flexclass] RESULT: PASS"
