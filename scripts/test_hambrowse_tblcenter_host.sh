#!/usr/bin/env bash
# scripts/test_hambrowse_tblcenter_host.sh — FAST, QEMU-free gate proving Chrome-
# parity for the CENTRED-BLOCK TABLE GUTTER via `margin:0 auto` and the
# presentational `align="center"` attribute (the modern + legacy centred-layout
# idioms used by Hacker News / forums / aggregators / older corporate pages):
#
#   a fixed-width table (`width="85%"`) that centres ITSELF with
#   `style="margin:0 auto"` OR `align="center"` is horizontally centred in its
#   container — an equal left/right gutter — exactly like a `<center>`-wrapped
#   table, instead of hugging the left edge. Before the fix, only an ancestor
#   `<center>` (a text-align:-webkit-center scope, g_align==2) centred a table;
#   a table's OWN margin:auto / align=center was ignored and the grid stayed at
#   the container's left margin, so the whole layout sat left of Chrome's centred
#   column (HN gutter ~75px at width 1000 vs hb ~8px).
#
# The fix sets a per-table centre request (g_tbl_center) when the table itself
# carries margin-left/right:auto (cascade or inline style="margin:0 auto") or
# align="center"; _compute_cols then offsets the grid by half the free space —
# the SAME centring maths <center> already uses — bounded so a FULL-WIDTH table
# (width:100% / content that fills the container) still fills and never centres.
#
# The gfx driver (user/hambrowse_host_gfx.ad) reports each painted background box
# as `POSFILL <i> z <z> x0 .. y0 .. x1 .. y1 .. col #RRGGBB pix #RRGGBB`. The
# fixture gives four otherwise-identical 85%/100% tables a distinct title-cell
# bgcolor: GREEN = margin:auto (centre), BLUE = align=center (centre),
# RED = plain (LEFT control), YELLOW = width:100%+margin:auto (FILL control).
# This gate reads each box's left edge x0 — no network, no QEMU, milliseconds.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-tblcenter] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/tblcenter_compile.log"; then
    echo "[hb-tblcenter] FAIL: driver did not compile"; cat "$OUT/tblcenter_compile.log"; exit 1
fi

FIX="tests/fixtures/hambrowse_tblcenter.html"
DUMP="$OUT/tblcenter_dump.txt"
"$BIN" "$FIX" "$OUT/tblcenter.ppm" 640 >"$DUMP" 2>&1 || { echo "[hb-tblcenter] FAIL: render nonzero"; cat "$DUMP"; exit 1; }

# Left / right edge of the FIRST background box of colour $2 in dump $1.
box_x0() { awk -v want="$2" '/^POSFILL/{c="";x0="";for(i=1;i<=NF;i++){if($i=="col")c=$(i+1);if($i=="x0")x0=$(i+1)} if(c==want){print x0; exit}}' "$1"; }
box_x1() { awk -v want="$2" '/^POSFILL/{c="";x1="";for(i=1;i<=NF;i++){if($i=="col")c=$(i+1);if($i=="x1")x1=$(i+1)} if(c==want){print x1; exit}}' "$1"; }

GREEN=$(box_x0 "$DUMP" "#00cc00")    # margin:0 auto  => centred
BLUE=$(box_x0 "$DUMP"  "#0000cc")    # align="center" => centred
RED=$(box_x0 "$DUMP"   "#cc0000")    # plain          => LEFT control
YEL0=$(box_x0 "$DUMP"  "#cccc00")    # width:100%     => FILL control (left)
YEL1=$(box_x1 "$DUMP"  "#cccc00")    # width:100%     => FILL control (right)
echo "[hb-tblcenter] margin:auto  title-cell x0=${GREEN:-?} (centred, want >= 45)"
echo "[hb-tblcenter] align=center title-cell x0=${BLUE:-?}  (centred, want >= 45)"
echo "[hb-tblcenter] plain (ctrl)  title-cell x0=${RED:-?}  (LEFT,    want <= 35)"
echo "[hb-tblcenter] width:100%    fill  x0=${YEL0:-?} x1=${YEL1:-?} (FILL, want x0<=12 x1>=630)"

# --- margin:0 auto centres the table ------------------------------------------
if [ -n "${GREEN:-}" ] && [ "$GREEN" -ge 45 ]; then
    echo "[hb-tblcenter] PASS margin:0 auto centres the table (x0=$GREEN — was ~26 hugging left)"
else
    echo "[hb-tblcenter] FAIL margin:0 auto not centred (x0=${GREEN:-none}, want >= 45)"; fail=1
fi

# --- align="center" centres the table -----------------------------------------
if [ -n "${BLUE:-}" ] && [ "$BLUE" -ge 45 ]; then
    echo "[hb-tblcenter] PASS align=center centres the table (x0=$BLUE)"
else
    echo "[hb-tblcenter] FAIL align=center not centred (x0=${BLUE:-none}, want >= 45)"; fail=1
fi

# --- CONTROL: a plain table (no centring hint) stays LEFT ----------------------
if [ -n "${RED:-}" ] && [ "$RED" -le 35 ]; then
    echo "[hb-tblcenter] PASS plain control stays left (x0=$RED) — centring is guarded, not global"
else
    echo "[hb-tblcenter] FAIL plain control unexpectedly moved (x0=${RED:-none}, want <= 35)"; fail=1
fi

# --- centred tables are STRICTLY right of the left control ---------------------
if [ -n "${GREEN:-}" ] && [ -n "${BLUE:-}" ] && [ -n "${RED:-}" ] \
   && [ "$GREEN" -gt "$RED" ] && [ "$BLUE" -gt "$RED" ]; then
    echo "[hb-tblcenter] PASS centred tables ($GREEN/$BLUE) are right of the left control ($RED)"
else
    echo "[hb-tblcenter] FAIL centred/left not discriminated (green=${GREEN:-none} blue=${BLUE:-none} red=${RED:-none})"; fail=1
fi

# --- CONTROL: width:100% + margin:auto must still FILL, not centre -------------
if [ -n "${YEL0:-}" ] && [ -n "${YEL1:-}" ] && [ "$YEL0" -le 12 ] && [ "$YEL1" -ge 630 ]; then
    echo "[hb-tblcenter] PASS width:100% fills edge-to-edge (x0=$YEL0 x1=$YEL1) — full-width table not centred"
else
    echo "[hb-tblcenter] FAIL width:100% no longer fills (x0=${YEL0:-none} x1=${YEL1:-none}, want x0<=12 x1>=630)"; fail=1
fi

# --- native hambrowse still compiles ------------------------------------------
if python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse.ad -o "$OUT/hambrowse_native_tblcenter" 2>"$OUT/tblcenter_native.log"; then
    echo "[hb-tblcenter] PASS native hambrowse compiles"
else
    echo "[hb-tblcenter] FAIL native hambrowse did not compile"; cat "$OUT/tblcenter_native.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-tblcenter] RESULT: PASS"
else
    echo "[hb-tblcenter] RESULT: FAIL"; exit 1
fi
