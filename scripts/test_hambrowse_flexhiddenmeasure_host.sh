#!/usr/bin/env bash
# scripts/test_hambrowse_flexhiddenmeasure_host.sh — FAST, QEMU-free gate proving
# the flex child natural-width measurer SKIPS display:none descendants. A
# `justify-content:space-between` row with two groups spreads to opposite edges
# ONLY if the right group's measured width excludes its CLASS-hidden popup prose;
# counted, that prose overflows the row (free=0) and both groups pack left.
# Regression guard for google.com's footer (`.iTjxkf` Privacy/Terms/Settings,
# whose hidden Settings menu + inline <style> measured ~6000px).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
OUT="build/host"; BIN="$OUT/hambrowse_host"; mkdir -p "$OUT"
echo "[hb-flexhiddenmeasure] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexhiddenmeasure] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexhiddenmeasure] PASS host harness compiled -> $BIN"
echo "[hb-flexhiddenmeasure] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexhiddenmeasure] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexhiddenmeasure] PASS native hambrowse still compiles"
fail=0
D="$OUT/flexhiddenmeasure.txt"
"$BIN" tests/fixtures/hambrowse_flexhiddenmeasure.html 800 >"$D" 2>&1 \
    || { echo "[hb-flexhiddenmeasure] FAIL: render exited non-zero"; cat "$D"; exit 1; }
flx() { grep -E "^FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #$1( |\$)" "$D" | awk '{print $4}' | head -1; }
LLX=$(flx aa1111); RLX=$(flx 3333cc)
echo "[hb-flexhiddenmeasure] left group lx=$LLX  right group lx=$RLX"
if [ -z "$LLX" ] || [ -z "$RLX" ]; then
    echo "[hb-flexhiddenmeasure] FAIL: missing a group fill"; cat "$D"; exit 1
fi
# left group hugs the left edge; right group is pushed to the right edge by
# space-between — only possible if the hidden descendant text was NOT measured.
if [ "$LLX" -lt 60 ] && [ "$RLX" -gt 500 ]; then
    echo "[hb-flexhiddenmeasure] PASS space-between spread the groups (hidden prose skipped)"
else
    echo "[hb-flexhiddenmeasure] FAIL groups not spread (left=$LLX right=$RLX) — hidden text measured?"; fail=1
fi
if [ "$fail" -ne 0 ]; then echo "[hb-flexhiddenmeasure] RESULT: FAIL"; exit 1; fi
echo "[hb-flexhiddenmeasure] RESULT: PASS"
