#!/usr/bin/env bash
# scripts/test_hambrowse_cellpad0_host.sh — FAST, QEMU-free gate proving Chrome-
# parity for the presentational `cellpadding="0"` attribute (the classic Hacker
# News / forum / aggregator TABLE layout):
#
#   a `<table cellpadding="0" cellspacing="0">` packs its columns TIGHT like
#   Chrome — no inter-column gap, no interior text inset, and an EMPTY cell (the
#   HN votelinks cell that holds only an empty upvote-arrow div) collapses to
#   ~zero width — so the story TITLE starts right after the rank number instead of
#   a full ~24px cell floor per leading column. Before the fix every column
#   carried the fixed CELL_PAD (16px) + CELL_PADX (6px) reserve regardless of the
#   attribute, so a rank+vote pair pushed the title ~66px in (hb) vs Chrome ~26.
#
# The fix derives the table's effective padding from `cellpadding="N"`
# (0 => tight); a table WITHOUT the attribute, or with a NON-ZERO cellpadding,
# keeps the historical spacing — so this is a guarded, attribute-driven change,
# not a global table-metric shift.
#
# The gfx driver (user/hambrowse_host_gfx.ad) reports each painted background box
# as `POSFILL <i> z <z> x0 .. y0 .. x1 .. y1 .. col #RRGGBB pix #RRGGBB`. The
# fixture gives the TITLE cell of two otherwise-identical rows a distinct bgcolor:
# GREEN in a cellpadding="0" table, BLUE in a cellpadding="8" table. This gate
# reads each box's left edge x0 — no network, no QEMU, milliseconds.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-cellpad0] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/cellpad0_compile.log"; then
    echo "[hb-cellpad0] FAIL: driver did not compile"; cat "$OUT/cellpad0_compile.log"; exit 1
fi

FIX="tests/fixtures/hambrowse_cellpad0.html"
DUMP="$OUT/cellpad0_dump.txt"
"$BIN" "$FIX" "$OUT/cellpad0.ppm" 640 >"$DUMP" 2>&1 || { echo "[hb-cellpad0] FAIL: render nonzero"; cat "$DUMP"; exit 1; }

# Left edge (x0) of the FIRST background box of colour $2 in dump $1.
box_x0() {
    awk -v want="$2" '/^POSFILL/{c="";x0="";for(i=1;i<=NF;i++){if($i=="col")c=$(i+1);if($i=="x0")x0=$(i+1)} if(c==want){print x0; exit}}' "$1"
}

GREEN=$(box_x0 "$DUMP" "#00cc00")   # title cell of the cellpadding="0" table
BLUE=$(box_x0 "$DUMP" "#0000cc")    # title cell of the cellpadding="8" table
echo "[hb-cellpad0] cellpadding=0 title-cell left x0=${GREEN:-?} (tight, want <= 40)"
echo "[hb-cellpad0] cellpadding=8 title-cell left x0=${BLUE:-?}  (padded, want >= 55)"

# --- cellpadding="0": rank + EMPTY vote columns collapse => title starts tight --
if [ -n "${GREEN:-}" ] && [ "$GREEN" -le 40 ]; then
    echo "[hb-cellpad0] PASS cellpadding=0 packs columns tight — title starts at x0=$GREEN (was ~66 with the fixed cell floor)"
else
    echo "[hb-cellpad0] FAIL cellpadding=0 title still pushed in (x0=${GREEN:-none}, want <= 40 — the CELL_PAD/CELL_PADX floor ignored the attribute)"; fail=1
fi

# --- CONTROL: a NON-ZERO cellpadding keeps the historical wide spacing ----------
if [ -n "${BLUE:-}" ] && [ "$BLUE" -ge 55 ]; then
    echo "[hb-cellpad0] PASS cellpadding=8 keeps the padded spacing (x0=$BLUE) — the attribute drives the packing, not a global change"
else
    echo "[hb-cellpad0] FAIL cellpadding=8 unexpectedly tight (x0=${BLUE:-none}, want >= 55)"; fail=1
fi

# --- the tight table's title is STRICTLY left of the padded one -----------------
if [ -n "${GREEN:-}" ] && [ -n "${BLUE:-}" ] && [ "$GREEN" -lt "$BLUE" ]; then
    echo "[hb-cellpad0] PASS tight-table title ($GREEN) is left of the padded-table title ($BLUE)"
else
    echo "[hb-cellpad0] FAIL tight/padded titles not discriminated (green=${GREEN:-none} blue=${BLUE:-none})"; fail=1
fi

# --- native hambrowse still compiles -------------------------------------------
if python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse.ad -o "$OUT/hambrowse_native_cellpad0" 2>"$OUT/cellpad0_native.log"; then
    echo "[hb-cellpad0] PASS native hambrowse compiles"
else
    echo "[hb-cellpad0] FAIL native hambrowse did not compile"; cat "$OUT/cellpad0_native.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-cellpad0] RESULT: PASS"
else
    echo "[hb-cellpad0] RESULT: FAIL"; exit 1
fi
