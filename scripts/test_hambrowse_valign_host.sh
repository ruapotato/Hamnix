#!/usr/bin/env bash
# scripts/test_hambrowse_valign_host.sh — FAST, QEMU-free gate for ROUND-3 CSS
# vertical-align on an inline-block in the native browser engine
# (lib/web/layout/box.ad). The m_valign cascade winner was parsed by round-2 but
# not consumed; a TALL inline-block chip (vertical padding -> 4 rows tall) now
# places its single text line per vertical-align:
#
#   .top -> text on the chip's FIRST row (row 0).
#   .bot -> text on the chip's LAST  row (row 3) — a whole-row drop.
#   .mid -> text stays on the first row, centred (byte-identical default).
#
# The three chips share one line, so their differing text ROWS prove the align.
# Builds BOTH targets so a break in either backend is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_valign.html"
mkdir -p "$OUT"

echo "[hb-va] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-va] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-va] PASS host harness compiled -> $BIN"

echo "[hb-va] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-va] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-va] PASS native hambrowse still compiles"

fail=0
D="$OUT/valign.txt"
"$BIN" "$FIX" 600 >"$D" 2>&1 || { echo "[hb-va] FAIL: render exited non-zero"; cat "$D"; exit 1; }
cat "$D"

# SEG lines are "SEG line x ... |text|"; $2 is the ROW.
row_of() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }

tr=$(row_of TOPCHIP)
br=$(row_of BOTCHIP)
mr=$(row_of MIDCHIP)
echo "[hb-va] rows: top=$tr bottom=$br middle=$mr (expect 0 / 3 / 0)"

if [ "$tr" = "0" ]; then
    echo "[hb-va] PASS vertical-align:top pins the chip text to row 0"
else
    echo "[hb-va] FAIL top chip row=$tr (want 0)"; fail=1
fi
if [ "$br" = "3" ]; then
    echo "[hb-va] PASS vertical-align:bottom drops the chip text to the last row (3)"
else
    echo "[hb-va] FAIL bottom chip row=$br (want 3)"; fail=1
fi
if [ "$mr" = "0" ] && [ -n "$br" ] && [ "$br" -gt "$mr" ]; then
    echo "[hb-va] PASS middle stays on row 0 (default centring) — distinct from bottom"
else
    echo "[hb-va] FAIL middle chip row=$mr (want 0, below bottom)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-va] RESULT: FAIL"; exit 1
fi
echo "[hb-va] RESULT: PASS"
