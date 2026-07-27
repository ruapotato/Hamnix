#!/usr/bin/env bash
# scripts/test_hambrowse_flexnav_host.sh — FAST, QEMU-free gate for the round-3
# web-standards rung in the native browser engine (lib/htmlengine.ad): DIRECT
# <a> / <li> flex children (the canonical real-site navbar shape).
#
#   (1) `<nav style="display:flex"><a>Home</a>…` — the direct <a> link children
#       of a flex row now COLUMNISE (spread into equal columns across the bar)
#       instead of jamming at the left. Round 2 only blockified <span> children;
#       <a> was excluded to keep its href. This gate proves the link columns
#       spread AND keep their href (seg link id >= 0) + link colour.
#
#   (2) `<ul style="display:flex"><li>…` — a flex list columnises its <li>
#       children onto ONE row (side-by-side), the list-style:none navbar shape,
#       instead of stacking each <li> vertically. The bullet marker is dropped
#       for the flex-item columns; the <li> text colour still applies.
#
#   (3) `li{display:inline}` reset navs — an inline list item drops its line
#       break + bullet and flows horizontally (the classic old-school nav), the
#       items coalescing onto one line.
#
#   (4) A PLAIN (non-flex) <ul><li> still stacks vertically WITH bullet markers
#       — neither the flex nor the inline path may regress normal lists.
#
# These are the highest-leverage remaining flex gap: <a>/<li> navbars are on a
# huge fraction of real pages. Builds BOTH targets (host harness x86_64-linux +
# native hambrowse x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_flexnav.html"
mkdir -p "$OUT"

echo "[hb-flexnav] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexnav] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexnav] PASS host harness compiled -> $BIN"

echo "[hb-flexnav] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexnav] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexnav] PASS native hambrowse still compiles"

fail=0
D0="$OUT/flexnav.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-flexnav] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

seg_row() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D0" | awk '{print $2}' | head -1; }
seg_x()   { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D0" | awk '{print $3}' | head -1; }
seg_link(){ grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D0" | grep -oE " l-?[0-9]+ " | head -1 | tr -d ' '; }

# ---- (1) flex <a> navbar spreads into columns + keeps href -----------------
hx=$(seg_x "Home"); cx=$(seg_x "Contact")
echo "[hb-flexnav] nav <a> x: Home=$hx Contact=$cx"
if [ -n "$hx" ] && [ -n "$cx" ] && [ "$cx" -gt "$((hx + 300))" ]; then
    echo "[hb-flexnav] PASS flex <a> navbar spreads into columns (Home $hx -> Contact $cx)"
else
    echo "[hb-flexnav] FAIL flex <a> nav did not spread (Home=$hx Contact=$cx)"; fail=1
fi
hl=$(seg_link "Home")
if [ -n "$hl" ] && [ "$hl" != "l-1" ]; then
    echo "[hb-flexnav] PASS flex <a> column keeps its href/link id ($hl)"
else
    echo "[hb-flexnav] FAIL flex <a> column lost its link (got '$hl')"; fail=1
fi
# The nav's own background paints a FULL-BLEED bar spanning the viewport width
# (flex container box). `.nav` is a block-level display:flex container with no
# width/margin/padding, so its containing block is the body and its background
# box spans the full content width — the engine's full-bleed nav-bar model,
# emitted as `FILL <top> <bot> 0 <W>` (here 0..800 at the 800px render width).
# The stale `100 700` expectation this replaced matched NO CSS in the fixture (no
# 100px inset exists) and contradicted both this gate's own "full-width" comment
# and the engine's documented full-bleed nav convention that
# test_hambrowse_fullwidth_host.sh asserts green (nav bg spans ~0..viewport).
# STALE-ORIGIN RE-PIN (2026-07-27): the bar's LEFT column moved 0 -> 8 when the
# engine started honouring the UA 8px body margin instead of laying prose out
# from x=0. `chromium --headless` reports the nav's border box at x=8 (w=784)
# for this fixture, so 8 is the Chrome-correct origin; the full-bleed RIGHT
# edge this gate is really about is unchanged.
if grep -Eq 'FILL [0-9]+ [0-9]+ 8 800 #223344' "$D0"; then
    echo "[hb-flexnav] PASS flex nav paints its full-bleed background bar (8..800)"
else
    echo "[hb-flexnav] FAIL flex nav background bar missing"; fail=1
fi

# ---- (2) flex <ul><li> columnise on ONE row --------------------------------
ar=$(seg_row "Alpha"); dr=$(seg_row "Delta")
ax=$(seg_x "Alpha");   dx=$(seg_x "Delta")
echo "[hb-flexnav] menu li: Alpha row=$ar x=$ax  Delta row=$dr x=$dx"
if [ -n "$ar" ] && [ -n "$dr" ] && [ "$ar" = "$dr" ] && [ -n "$dx" ] && [ "$dx" -gt "$((ax + 300))" ]; then
    echo "[hb-flexnav] PASS flex <ul><li> columnise side-by-side on one row"
else
    echo "[hb-flexnav] FAIL flex <li> did not columnise (Alpha r=$ar x=$ax Delta r=$dr x=$dx)"; fail=1
fi

# ---- (3) display:inline <li> flows the items inline on ONE row -------------
# Plain-text inline items coalesce into a single run "Uno Dos Tres" (they share
# one line, no bullet, no per-item line break) — the reset-nav horizontal flow.
if grep -Eq 'SEG [0-9]+ [0-9]+ .*\|Uno Dos Tres\|' "$D0"; then
    echo "[hb-flexnav] PASS display:inline <li> flows items inline on one row"
else
    echo "[hb-flexnav] FAIL display:inline <li> did not flow inline"; grep -iE "Uno|Dos|Tres" "$D0"; fail=1
fi

# ---- (4) a PLAIN <ul><li> still stacks vertically with bullet markers -------
p1=$(seg_row "Plain one"); p2=$(seg_row "Plain two")
echo "[hb-flexnav] plain list rows: one=$p1 two=$p2"
if [ -n "$p1" ] && [ -n "$p2" ] && [ "$p2" -gt "$p1" ]; then
    echo "[hb-flexnav] PASS plain <ul><li> still stacks vertically (no flex regression)"
else
    echo "[hb-flexnav] FAIL plain list did not stack (one=$p1 two=$p2)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-flexnav] RESULT: FAIL"; exit 1
fi
echo "[hb-flexnav] RESULT: PASS"
