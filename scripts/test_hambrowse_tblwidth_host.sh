#!/usr/bin/env bash
# scripts/test_hambrowse_tblwidth_host.sh — FAST, QEMU-free gate proving that
# hambrowse honours an EXPLICIT presentational table width (HTML `width="80%"` /
# `width="Npx"`): a top-level table STRETCHES its column grid to fill that target
# so its cells wrap at the wider boundary, instead of shrinking to content width.
#
# WHY this matters: countless legacy/table-layout sites (Hacker News wraps its
# whole page in `<center><table width="85%">`, plus forums, docs, articles) rely
# on the width attribute to make the page fill the viewport. Before this fix the
# engine sized every table purely from cell CONTENT and ignored the width attr,
# so a `<center><table width="85%">` shrank to a narrow content column and got
# centred as a thin strip (with text clipping past the cramped cell edges).
#
# The gfx driver (user/hambrowse_host_gfx.ad) reports each stroked border rect as
#   BORDER <i> x0 .. y0 .. x1 .. y1 .. edge #RRGGBB ...
# The BLACK (#000000) rect is the table FRAME; its x1 is the table's right edge.
# This gate asserts:
#   * the width="80%" table's frame right edge reaches ~80% of the 640px viewport
#     (>= 460px) — i.e. the grid actually stretched to the target;
#   * a CONTROL table with the SAME cells but NO width attribute stays narrow
#     (frame right edge < 200px) — so the stretch is caused by the attribute, not
#     a tautology;
#   * the surplus is distributed across BOTH columns (the first column's right
#     edge is pushed well past its content width) — proportional auto-layout.
#
# Built with the frozen Python seed compiler; PNG conversion is stdlib-only.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0
VW=640

echo "[hb-tw] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/tw_compile.log"; then
    echo "[hb-tw] FAIL: driver did not compile"; cat "$OUT/tw_compile.log"; exit 1
fi
echo "[hb-tw] PASS pixel backend compiled"

echo "[hb-tw] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/tw_native.log"; then
    echo "[hb-tw] FAIL: native hambrowse did not compile"; cat "$OUT/tw_native.log"; exit 1
fi
echo "[hb-tw] PASS native hambrowse still compiles"

# Helper: right edge (x1) of the BLACK table frame in a fixture's render.
frame_x1() {
    awk '/^BORDER [0-9]/ {x1=e="";for(i=1;i<=NF;i++){if($i=="x1")x1=$(i+1);if($i=="edge")e=$(i+1)} if(e=="#000000") print x1}' "$1" | tail -1
}
# Helper: right edge (x1) of the FIRST grey cell grid line (the first column).
col0_x1() {
    awk '/^BORDER [0-9]/ {x1=e="";for(i=1;i<=NF;i++){if($i=="x1")x1=$(i+1);if($i=="edge")e=$(i+1)} if(e=="#808080"){print x1; exit}}' "$1"
}

# --- (A) width="80%" table stretches to fill the viewport ---------------------
FIX="tests/fixtures/hambrowse_tblwidth.html"
DUMP="$OUT/tw_dump.txt"
PPM="$OUT/tw.ppm"
echo "[hb-tw] rendering $FIX (viewport ${VW}px) ..."
if ! "$BIN" "$FIX" "$PPM" "$VW" >"$DUMP" 2>&1; then
    echo "[hb-tw] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^BORDER' "$DUMP"
WX1=$(frame_x1 "$DUMP")
WC0=$(col0_x1 "$DUMP")
echo "[hb-tw] width=80% frame right edge x1=${WX1:-?}, first column right edge=${WC0:-?}"

# 80% of 640 = 512; allow slack for indent + rounding -> require >= 460.
if [ -n "${WX1:-}" ] && [ "$WX1" -ge 460 ]; then
    echo "[hb-tw] PASS width=80% table stretched its frame to ~80% of the viewport (x1=$WX1)"
else
    echo "[hb-tw] FAIL width=80% table did not stretch (x1=${WX1:-none}, want >= 460)"; fail=1
fi

# --- (B) CONTROL: no width attribute => narrow content-sized table ------------
FIX2="tests/fixtures/hambrowse_tblwidth_auto.html"
DUMP2="$OUT/tw_auto_dump.txt"
PPM2="$OUT/tw_auto.ppm"
echo "[hb-tw] rendering control $FIX2 (no width attr) ..."
"$BIN" "$FIX2" "$PPM2" "$VW" >"$DUMP2" 2>&1
grep -E '^BORDER' "$DUMP2"
AX1=$(frame_x1 "$DUMP2")
echo "[hb-tw] auto (no width) frame right edge x1=${AX1:-?}"
if [ -n "${AX1:-}" ] && [ "$AX1" -lt 200 ]; then
    echo "[hb-tw] PASS un-sized control stays at content width (x1=$AX1) — attribute drives the stretch"
else
    echo "[hb-tw] FAIL control table unexpectedly wide (x1=${AX1:-none}, want < 200)"; fail=1
fi

# --- (C) the width table is strictly wider than the identical auto table ------
if [ -n "${WX1:-}" ] && [ -n "${AX1:-}" ] && [ "$WX1" -gt "$((AX1 + 200))" ]; then
    echo "[hb-tw] PASS width=80% table ($WX1) is far wider than the same table auto-sized ($AX1)"
else
    echo "[hb-tw] FAIL width table not decisively wider than auto (w=$WX1 auto=$AX1)"; fail=1
fi

# --- (D) surplus is distributed: the FIRST column grew past its content -------
# In the auto render column 0 ends at ~74px; the stretched render must push it
# well beyond that (proportional distribution across both columns).
AC0=$(col0_x1 "$DUMP2")
echo "[hb-tw] first column right edge: width=${WC0:-?}  auto=${AC0:-?}"
if [ -n "${WC0:-}" ] && [ -n "${AC0:-}" ] && [ "$WC0" -gt "$((AC0 + 40))" ]; then
    echo "[hb-tw] PASS surplus distributed — column 0 widened from $AC0 to $WC0"
else
    echo "[hb-tw] FAIL surplus not distributed to column 0 (width=$WC0 auto=$AC0)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-tw] RESULT: PASS"
else
    echo "[hb-tw] RESULT: FAIL"; exit 1
fi
