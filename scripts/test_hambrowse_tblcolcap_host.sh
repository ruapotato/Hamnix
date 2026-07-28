#!/usr/bin/env bash
# scripts/test_hambrowse_tblcolcap_host.sh — FAST, QEMU-free gate proving Chrome-
# parity for a LONG-TEXT AUTO-TABLE COLUMN (the Hacker News story-title pattern):
#
#   an auto-width `<table>` (no width attribute) whose cell holds a ~95-char title
#   sizes that column to its CONTENT, bounded only by the container — like Chrome —
#   so the title stays on ONE line. The engine used to clamp every column at a
#   FIXED 60-char (480px) cap, so a real headline wrapped to a second line even in
#   a wide viewport, doubling every story's height (HN rendered ~1658px vs Chrome
#   ~1438px). The cap is now the AVAILABLE width (floored at the old 60 so nothing
#   ever shrinks): a wide container lets the title breathe; a narrow one still
#   wraps (the cap is container-driven, not unbounded).
#
# The gfx driver (user/hambrowse_host_gfx.ad) prints `CANVAS <w> <h>` — a one-line
# title cell is a single ~19px text row (~62px page), a wrapped one is two (~81px).
# This gate reads that deterministic line — no network, no QEMU, milliseconds.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-tblcolcap] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/tblcolcap_compile.log"; then
    echo "[hb-tblcolcap] FAIL: driver did not compile"; cat "$OUT/tblcolcap_compile.log"; exit 1
fi

FIX="tests/fixtures/hambrowse_tblcolcap.html"

canvas_h() {
    awk '/^CANVAS/{print $3; exit}' "$1"
}

# --- WIDE viewport: the long title column sizes to content => ONE row ----------
DUMPW="$OUT/tblcolcap_wide.txt"
"$BIN" "$FIX" "$OUT/tblcolcap_wide.ppm" 1000 >"$DUMPW" 2>&1 || { echo "[hb-tblcolcap] FAIL: render nonzero"; cat "$DUMPW"; exit 1; }
HW=$(canvas_h "$DUMPW")
echo "[hb-tblcolcap] wide(1000) page height = ${HW:-?}px (one-line title ~62)"
if [ -n "${HW:-}" ] && [ "$HW" -le 70 ]; then
    echo "[hb-tblcolcap] PASS long title fits on ONE line in a wide table (h=$HW <= 70)"
else
    echo "[hb-tblcolcap] FAIL long title wrapped in a wide table (h=${HW:-none}, want <= 70 — the 60-char cap strangled it)"; fail=1
fi

# --- NARROW viewport: the cap is container-driven => the SAME title wraps -------
DUMPN="$OUT/tblcolcap_narrow.txt"
"$BIN" "$FIX" "$OUT/tblcolcap_narrow.ppm" 480 >"$DUMPN" 2>&1
HN=$(canvas_h "$DUMPN")
echo "[hb-tblcolcap] narrow(480) page height = ${HN:-?}px (wrapped ~81)"
if [ -n "${HN:-}" ] && [ "$HN" -ge 75 ]; then
    echo "[hb-tblcolcap] PASS title wraps when the container is narrow (h=$HN >= 75) — cap tracks the container, not unbounded"
else
    echo "[hb-tblcolcap] FAIL narrow-container title did not wrap (h=${HN:-none}, want >= 75)"; fail=1
fi

# --- native hambrowse still compiles ------------------------------------------
if python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse.ad -o "$OUT/hambrowse_native_tblcolcap" 2>"$OUT/tblcolcap_native.log"; then
    echo "[hb-tblcolcap] PASS native hambrowse compiles"
else
    echo "[hb-tblcolcap] FAIL native hambrowse did not compile"; cat "$OUT/tblcolcap_native.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-tblcolcap] RESULT: PASS"
else
    echo "[hb-tblcolcap] RESULT: FAIL"; exit 1
fi
