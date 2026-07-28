#!/usr/bin/env bash
# scripts/test_hambrowse_appshell_host.sh — FAST, QEMU-free gate for the
# APP-SHELL landmark layout mechanism in the native browser engine
# (lib/web/dom/forms.ad landmark float + `*dropdown-content` collapse, gated on
# a <main> landmark via lib/web/layout/flow.ad / lib/web/state.ad _page_has_main).
#
# WHY: real CMS/app shells (Wikipedia's Vector skin) place their nav/sidebar/TOC
# side-regions BESIDE the main column via CSS that usually lives in an EXTERNAL
# stylesheet the engine never fetches. Absent that CSS those tall regions stacked
# in document order ABOVE <main>, burying the article far down the page. The
# engine now (1) floats a pre-<main> chrome <nav>/<aside> into a fixed 240px LEFT
# gutter so the article flows up beside it, and (2) collapses a CSS-checkbox-hack
# `*dropdown-content` popup (display:none-by-default menu) instead of dumping its
# whole expanded contents (e.g. Wikipedia's 163-language list).
#
# Asserts on STABLE POSFILL background-fill pixel rects + a text-absence check —
# no glyph OCR, no QEMU. Two fixtures:
#   hambrowse_appshell.html         (HAS <main>) — mechanism ENGAGES
#   hambrowse_appshell_nomain.html  (NO  <main>) — mechanism is a NO-OP (control)

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_appshell.html"
CTL="tests/fixtures/hambrowse_appshell_nomain.html"
DUMP="$OUT/appshell_dump.txt"
CDUMP="$OUT/appshell_nomain_dump.txt"
PPM="$OUT/appshell.ppm"
PNG="$OUT/appshell.png"
mkdir -p "$OUT"
fail=0

echo "[hb-appshell] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/appshell_compile.log"; then
    echo "[hb-appshell] FAIL: driver did not compile"; cat "$OUT/appshell_compile.log"; exit 1
fi
echo "[hb-appshell] PASS pixel backend compiled -> $BIN"

echo "[hb-appshell] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/appshell_native.log"; then
    echo "[hb-appshell] FAIL: native hambrowse did not compile"; cat "$OUT/appshell_native.log"; exit 1
fi
echo "[hb-appshell] PASS native hambrowse still compiles"

echo "[hb-appshell] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-appshell] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
echo "[hb-appshell] rendering control $CTL ..."
if ! "$BIN" "$CTL" "$OUT/appshell_nomain.ppm" 640 >"$CDUMP" 2>&1; then
    echo "[hb-appshell] FAIL: control render exited non-zero"; cat "$CDUMP"; exit 1
fi
grep -E '^POSFILL' "$DUMP" || true
python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>/dev/null && \
    echo "[hb-appshell] wrote $PNG for eyeballing" || true

# Field extractor: echo "<x0> <y0> <x1> <y1>" for the POSFILL whose col matches.
row_for() { awk -v c="$1" '$1=="POSFILL" && $14==c {print $6,$8,$10,$12; exit}' "$2"; }

read -r NAV_X0 NAV_Y0 NAV_X1 NAV_Y1 < <(row_for '#112233' "$DUMP")   # chrome nav
read -r MB_X0  MB_Y0  MB_X1  MB_Y1  < <(row_for '#abcdef' "$DUMP")   # <main> box
read -r CN_X0  CN_Y0  CN_X1  CN_Y1  < <(row_for '#112233' "$CDUMP")  # control nav
read -r CM_X0  CM_Y0  CM_X1  CM_Y1  < <(row_for '#abcdef' "$CDUMP")  # control box

echo "[hb-appshell] main: NAV=($NAV_X0,$NAV_Y0)-($NAV_X1,$NAV_Y1) MAINBOX=($MB_X0,$MB_Y0)-($MB_X1,$MB_Y1)"
echo "[hb-appshell] ctrl: NAV=($CN_X0,$CN_Y0)-($CN_X1,$CN_Y1) BOX=($CM_X0,$CM_Y0)-($CM_X1,$CM_Y1)"

need() { [ -n "$1" ] || { echo "[hb-appshell] FAIL: missing box ($2)"; fail=1; return 1; }; return 0; }
for v in "$NAV_X0:nav" "$MB_X0:mainbox" "$CN_X0:ctrl-nav" "$CM_X0:ctrl-box"; do
    need "${v%%:*}" "${v##*:}" || true
done

# (1) LANDMARK FLOAT: the pre-<main> nav is floated into the left gutter — its
#     box starts at the content left (x0=8) and is exactly SIDEBAR_W (240px)
#     wide, NOT the full 640px window. (A non-floated nav would span full width.)
if [ "$fail" -eq 0 ] && [ "$NAV_X0" -eq 8 ] && [ "$((NAV_X1 - NAV_X0))" -eq 240 ]; then
    echo "[hb-appshell] PASS nav floated to 240px left gutter (x0=$NAV_X0 w=$((NAV_X1-NAV_X0)))"
else
    echo "[hb-appshell] FAIL nav not floated to gutter (x0=$NAV_X0 w=$((NAV_X1-NAV_X0)) want x0=8 w=240)"; fail=1
fi

# (2) ARTICLE AT TOP, BESIDE the nav: the <main> box renders at the region top
#     (its top row <= the nav top, i.e. NOT pushed below the tall nav) AND in the
#     channel indented past the floated gutter (its left edge is right of the
#     nav's right edge). This is the whole point: the article is not buried.
if [ "$fail" -eq 0 ] && [ "$MB_Y0" -le "$NAV_Y0" ]; then
    echo "[hb-appshell] PASS mainbox at region top, not below the nav (MB.y0=$MB_Y0 <= NAV.y0=$NAV_Y0)"
else
    echo "[hb-appshell] FAIL mainbox pushed down by nav (MB.y0=$MB_Y0 NAV.y0=$NAV_Y0)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$MB_X0" -ge "$NAV_X1" ]; then
    echo "[hb-appshell] PASS mainbox flows beside the gutter (MB.x0=$MB_X0 >= NAV.x1=$NAV_X1)"
else
    echo "[hb-appshell] FAIL mainbox not beside the gutter (MB.x0=$MB_X0 NAV.x1=$NAV_X1)"; fail=1
fi

# (3) DROPDOWN COLLAPSE: the `*dropdown-content` popup's contents must not render.
if [ "$fail" -eq 0 ] && ! grep -q "SECRETMENU" "$DUMP"; then
    echo "[hb-appshell] PASS collapsed dropdown-content popup is not rendered"
else
    echo "[hb-appshell] FAIL dropdown-content popup leaked into layout (SECRETMENU present)"; fail=1
fi

# (4) GATED ON <main> (control, no <main>): the SAME nav stays a full-width
#     in-flow block (spans well past the 240px gutter) and the following box
#     stacks BELOW it — the mechanism is a no-op without a <main> landmark.
if [ "$fail" -eq 0 ] && [ "$((CN_X1 - CN_X0))" -gt 300 ]; then
    echo "[hb-appshell] PASS control nav is full-width, NOT floated (w=$((CN_X1-CN_X0)))"
else
    echo "[hb-appshell] FAIL control nav wrongly floated without <main> (w=$((CN_X1-CN_X0)))"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$CM_Y0" -ge "$CN_Y1" ]; then
    echo "[hb-appshell] PASS control box stacks BELOW the nav (CM.y0=$CM_Y0 >= CN.y1=$CN_Y1)"
else
    echo "[hb-appshell] FAIL control box not stacked below nav (CM.y0=$CM_Y0 CN.y1=$CN_Y1)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-appshell] RESULT: PASS"
else
    echo "[hb-appshell] RESULT: FAIL"; exit 1
fi
