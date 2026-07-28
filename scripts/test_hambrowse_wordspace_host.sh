#!/usr/bin/env bash
# scripts/test_hambrowse_wordspace_host.sh — FAST, QEMU-free gate proving Chrome-
# parity for INLINE INTER-WORD SPACING INSIDE A TABLE CELL (the Hacker News
# sitebit `title (domain)` pattern; forum/aggregator rows generally).
#
# Before round 15, in-cell inline flow advanced the pen on the CELL_W (8px)
# MONOSPACE grid while the pixel paint drew the NARROWER proportional DejaVu
# advances. Every inter-word space was reserved at 8px and the accumulated
# per-word over-reservation stranded a big phantom gap before the next inline
# segment: a title's trailing edge (painted ~219px) was followed by the next
# `<span>`/`<a>` at ~244px — a ~25px "space" where Chrome draws ~4-5px. That
# pushed the sitebit `(domain)` far right on every story row.
#
# The fix routes table-cell inline runs through the SAME proportional measure
# hook the paint uses (lib/web/layout/box.ad `_run_px`/`_space_px` no longer fall
# back to CELL_W just because a table is active), so the inter-word space is the
# real ~5px glyph advance and the following segment sits tight after the word.
#
# The gfx driver's `dumpops` mode prints one `OP covmask X Y W H #rrggbbaa N` per
# painted text run. This gate renders a cell of `TITLE <a>link</a> (site)` and
# asserts the GAP between the black title run's right edge and the blue link run
# is a single proportional space (<= 12px), NOT the ~25px monospace phantom.
# Deterministic, no network, milliseconds.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-wordspace] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/wordspace_compile.log"; then
    echo "[hb-wordspace] FAIL: driver did not compile"; cat "$OUT/wordspace_compile.log"; exit 1
fi

FIX="tests/fixtures/hambrowse_wordspace.html"
DUMP="$OUT/wordspace_ops.txt"
"$BIN" "$FIX" "$OUT/wordspace.ppm" 1000 dumpops >"$DUMP" 2>&1 || {
    echo "[hb-wordspace] FAIL: render nonzero"; cat "$DUMP"; exit 1; }

# First black (#101010ff) covmask = the title run: X and W.
read -r TX TW < <(awk '/^OP covmask/ && $7=="#101010ff" {print $3, $5; exit}' "$DUMP")
# The blue (#1a4fd0ff) covmask = the <a> link run that follows the space.
LX=$(awk '/^OP covmask/ && $7=="#1a4fd0ff" {print $3; exit}' "$DUMP")

echo "[hb-wordspace] title run x=${TX:-?} w=${TW:-?} (right edge $(( ${TX:-0} + ${TW:-0} ))); link run x=${LX:-?}"

if [ -z "${TX:-}" ] || [ -z "${TW:-}" ] || [ -z "${LX:-}" ]; then
    echo "[hb-wordspace] FAIL: could not locate title/link runs in dumpops"; cat "$DUMP"; exit 1
fi

GAP=$(( LX - (TX + TW) ))
echo "[hb-wordspace] inter-word space (gap title->link) = ${GAP}px (Chrome single space ~4-5px; monospace phantom ~25px)"

# A proportional space is ~5px; the old CELL_W monospace phantom was ~25px.
if [ "$GAP" -ge 1 ] && [ "$GAP" -le 12 ]; then
    echo "[hb-wordspace] PASS in-cell inter-word space is proportional (${GAP}px <= 12)"
else
    echo "[hb-wordspace] FAIL in-cell inter-word space is NOT proportional (${GAP}px; want 1..12 — CELL_W monospace phantom)"; fail=1
fi

# Sanity: the sitebit (second black run) must sit tighter than the monospace base.
SB=$(awk '/^OP covmask/ && $7=="#101010ff" {c++; if(c==2){print $3; exit}}' "$DUMP")
echo "[hb-wordspace] sitebit run x=${SB:-?} (fix ~268; monospace base ~292)"
if [ -n "${SB:-}" ] && [ "$SB" -le 280 ]; then
    echo "[hb-wordspace] PASS sitebit sits tight (x=$SB <= 280)"
else
    echo "[hb-wordspace] FAIL sitebit pushed right (x=${SB:-none}, want <= 280)"; fail=1
fi

# --- native hambrowse still compiles ------------------------------------------
if python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse.ad -o "$OUT/hambrowse_native_wordspace" 2>"$OUT/wordspace_native.log"; then
    echo "[hb-wordspace] PASS native hambrowse compiles"
else
    echo "[hb-wordspace] FAIL native hambrowse did not compile"; cat "$OUT/wordspace_native.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-wordspace] RESULT: PASS"
else
    echo "[hb-wordspace] RESULT: FAIL"; exit 1
fi
