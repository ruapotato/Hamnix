#!/usr/bin/env bash
# scripts/test_hambrowse_topnav_host.sh — FAST, QEMU-free gate for the MASTHEAD /
# TOP-NAV guard on the app-shell landmark float (lib/web/dom/forms.ad
# _is_landmark_side + the g_header_depth guard in _handle_tag).
#
# WHY: the app-shell mechanism floats a pre-<main> COMPLEMENTARY sidebar into a
# 240px left gutter so the article flows up beside it (see
# test_hambrowse_appshell_host.sh). But a pre-<main> <nav> is, on real sites,
# almost always a full-width horizontal TOP BAR — the site masthead or primary
# navigation — not a narrow side column. Floating its (CSS-less, expanded) menu
# into a 240px gutter overlapped the article on every real doc/news page tested
# (MDN's reference mega-menu <nav>; BBC's section+region <nav>). This gate proves
# such navs are NOT floated: they stay full-width and <main> renders at the
# content left edge (x0=8), not indented past a phantom gutter.
#
# Asserts on STABLE POSFILL background-fill pixel rects — no glyph OCR, no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_topnav.html"
DUMP="$OUT/topnav_dump.txt"
PPM="$OUT/topnav.ppm"
PNG="$OUT/topnav.png"
mkdir -p "$OUT"
fail=0

echo "[hb-topnav] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/topnav_compile.log"; then
    echo "[hb-topnav] FAIL: driver did not compile"; cat "$OUT/topnav_compile.log"; exit 1
fi
echo "[hb-topnav] PASS pixel backend compiled -> $BIN"

echo "[hb-topnav] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/topnav_native.log"; then
    echo "[hb-topnav] FAIL: native hambrowse did not compile"; cat "$OUT/topnav_native.log"; exit 1
fi
echo "[hb-topnav] PASS native hambrowse still compiles"

echo "[hb-topnav] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-topnav] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^POSFILL' "$DUMP" || true
python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>/dev/null && \
    echo "[hb-topnav] wrote $PNG for eyeballing" || true

# Field extractor: echo "<x0> <y0> <x1> <y1>" for the POSFILL whose col matches.
row_for() { awk -v c="$1" '$1=="POSFILL" && $14==c {print $6,$8,$10,$12; exit}' "$2"; }

read -r MH_X0 MH_Y0 MH_X1 MH_Y1 < <(row_for '#112233' "$DUMP")   # masthead nav (in header)
read -r PN_X0 PN_Y0 PN_X1 PN_Y1 < <(row_for '#223344' "$DUMP")   # primary nav (sibling)
read -r MB_X0 MB_Y0 MB_X1 MB_Y1 < <(row_for '#abcdef' "$DUMP")   # <main> box

echo "[hb-topnav] masthead=($MH_X0,$MH_Y0)-($MH_X1,$MH_Y1) primary=($PN_X0,$PN_Y0)-($PN_X1,$PN_Y1) mainbox=($MB_X0,$MB_Y0)-($MB_X1,$MB_Y1)"

need() { [ -n "$1" ] || { echo "[hb-topnav] FAIL: missing box ($2)"; fail=1; return 1; }; return 0; }
for v in "$MH_X0:masthead" "$PN_X0:primary" "$MB_X0:mainbox"; do
    need "${v%%:*}" "${v##*:}" || true
done

# (1) MASTHEAD nav (inside <header>) is NOT floated: it spans full width
#     (well past the 240px gutter), NOT a 240px column.
if [ "$fail" -eq 0 ] && [ "$((MH_X1 - MH_X0))" -gt 300 ]; then
    echo "[hb-topnav] PASS masthead nav is full-width, NOT floated (w=$((MH_X1-MH_X0)))"
else
    echo "[hb-topnav] FAIL masthead nav wrongly floated (w=$((MH_X1-MH_X0)) want >300)"; fail=1
fi

# (2) PRIMARY nav (top-level sibling after </header>) is NOT floated either.
if [ "$fail" -eq 0 ] && [ "$((PN_X1 - PN_X0))" -gt 300 ]; then
    echo "[hb-topnav] PASS primary nav is full-width, NOT floated (w=$((PN_X1-PN_X0)))"
else
    echo "[hb-topnav] FAIL primary nav wrongly floated (w=$((PN_X1-PN_X0)) want >300)"; fail=1
fi

# (3) With no nav floated, <main> renders at the content LEFT edge (x0=8), NOT
#     indented past a phantom 240px gutter (which would overlap the menu).
if [ "$fail" -eq 0 ] && [ "$MB_X0" -eq 8 ]; then
    echo "[hb-topnav] PASS mainbox at content left edge, no phantom gutter (x0=$MB_X0)"
else
    echo "[hb-topnav] FAIL mainbox indented past a phantom gutter (x0=$MB_X0 want 8)"; fail=1
fi

# (4) <main> stacks BELOW both navs (they are in-flow full-width blocks, so the
#     article is not overlapped by the menu that precedes it).
if [ "$fail" -eq 0 ] && [ "$MB_Y0" -ge "$PN_Y1" ]; then
    echo "[hb-topnav] PASS mainbox below the navs, not overlapped (MB.y0=$MB_Y0 >= PN.y1=$PN_Y1)"
else
    echo "[hb-topnav] FAIL mainbox overlaps the navs (MB.y0=$MB_Y0 PN.y1=$PN_Y1)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-topnav] RESULT: PASS"
else
    echo "[hb-topnav] RESULT: FAIL"; exit 1
fi
