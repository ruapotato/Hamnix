#!/usr/bin/env bash
# scripts/test_hambrowse_gridautorows_host.sh — FAST, QEMU-free render gate for
# CSS `grid-auto-rows` (implicit grid track sizing, round-11). lib/web/css/
# cascade.ad + lib/web/dom/forms.ad + lib/web/layout/box.ad.
#
# THE GAP (round-10): implicit grid rows — those past grid-template-rows — were
# ALWAYS content-sized. `grid-auto-rows: 120px` (the ubiquitous dashboard case of
# `grid-template-columns: repeat(N, 1fr)` + a fixed auto-row height) was ignored,
# so every row collapsed to one text line.
#
# THE FEATURE: grid-auto-rows now rides the cascade (r_gar/m_gar/d_gar, shared
# _grid_one_track parse) and is carried to the grid frame (flex_gar). A fixed-px
# auto-row gives implicit rows that height (_grid_row_h_rows); fr/auto stay
# content-sized (byte-identical to before).
#
# The fixture is a 2-col grid with NO grid-template-rows and grid-auto-rows:72px,
# so BOTH grid rows are implicit. The second row's items must therefore sit ~72px
# (5 text rows @16px) below the first — NOT ~25px (one content row) as before.
#
# Renders via the pixel backend (lib/htmlpaint + lib/htmlpage) — no QEMU boot.
# See docs/browser_w3c_conformance.md.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_gridautorows.html"
mkdir -p "$OUT"
fail=0

echo "[hb-gar] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/gar_gfx.log"; then
    echo "[hb-gar] FAIL: pixel backend did not compile"; cat "$OUT/gar_gfx.log"; exit 1
fi
echo "[hb-gar] PASS pixel backend compiled -> $GFX"

echo "[hb-gar] confirming native hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/gar_native.elf" 2>"$OUT/gar_native.log"; then
    echo "[hb-gar] FAIL: native hambrowse did not compile"; cat "$OUT/gar_native.log"; exit 1
fi
echo "[hb-gar] PASS native hambrowse still compiles"

pass() { echo "[hb-gar] PASS $1"; }
bad()  { echo "[hb-gar] FAIL $1"; fail=1; }

D="$OUT/gar.txt"
"$GFX" "$FIX" "$OUT/gar.ppm" 880 >"$D" 2>&1 || {
    echo "[hb-gar] FAIL: render exited non-zero"; cat "$D"; exit 1; }
python3 scripts/ppm_to_png.py "$OUT/gar.ppm" "$OUT/gar.png" >/dev/null 2>&1 \
    && echo "[hb-gar] wrote $OUT/gar.png"

echo "--- POSFILL ---"; grep "^POSFILL" "$D"; echo "---------------"

# y0 of a POSFILL box by its index.
y0() { awk -v idx="$1" '$1=="POSFILL" && $2==idx {for(i=1;i<=NF;i++) if($i=="y0") print $(i+1)}' "$D"; }

r0="$(y0 0)"   # row-0 item A (red)
r1="$(y0 2)"   # row-1 item C (blue) — the first row is IMPLICIT, sized by auto-rows
if [ -z "$r0" ] || [ -z "$r1" ]; then
    bad "grid item fills present (got r0='$r0' r1='$r1')"
else
    dy=$((r1 - r0))
    # grid-auto-rows:72px -> 5 text rows @16px (~125px incl. gap). Without the
    # feature the second row starts ~25px down (one content row). Threshold 90
    # cleanly separates the two (regression => this fails).
    if [ "$dy" -ge 90 ]; then
        pass "implicit row sized by grid-auto-rows (row1 y=$r1 is ${dy}px below row0 y=$r0)"
    else
        bad "grid-auto-rows ignored (row1 only ${dy}px below row0; want >=90)"
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-gar] RESULT: FAIL"; exit 1
fi
echo "[hb-gar] RESULT: PASS"
