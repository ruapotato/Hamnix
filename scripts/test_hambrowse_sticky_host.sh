#!/usr/bin/env bash
# scripts/test_hambrowse_sticky_host.sh — FAST, QEMU-free gate for CSS
# `position: sticky` and viewport-pinned `position: fixed` in the native browser
# engine (lib/web/layout/{flow,box}.ad + lib/web/css/cascade.ad), driven by the
# pixel backend user/hambrowse_host_gfx.ad. Asserts on STABLE background-fill
# pixels (POSFILL records: each block box's painted pixel rect, stacking z,
# declared colour, sampled pixel) — not glyph ink — so a regression fails
# without a QEMU boot.
#
# The host renders the WHOLE page canvas (no live viewport crop), so a first
# paint carries no scroll state. The driver's `scroll <rows>` knob feeds the
# STATIC scroll offset the sticky/fixed resolver assumes ("if the page were
# scrolled down N rows, where do the pinned boxes resolve?"). We render the
# fixture TWICE — unscrolled and scrolled past the sticky threshold — and assert
# the reposition. Live per-frame recompute on real scroll is the documented
# follow-up.
#
# Coverage proved here:
#   (1) position:fixed pins to the VIEWPORT, not its positioned ancestor — the
#       bar declared inside a pushed-down `position:relative` ancestor paints at
#       the page/viewport top, ABOVE the ancestor's box.
#   (2) position:fixed tracks the viewport under scroll — the bar moves down to
#       stay at the (scrolled) viewport top.
#   (3) position:sticky is IN-FLOW until scrolled — the sticky header sits at its
#       scroll container's top edge, above the normal content, at scroll 0.
#   (4) position:sticky PINS once the viewport scrolls past its threshold — the
#       header repositions to the viewport top (coincident with the fixed bar),
#       while the ordinary in-flow content does NOT move.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_sticky.html"
D0="$OUT/sticky_dump0.txt"      # unscrolled
DS="$OUT/sticky_dumpS.txt"      # scrolled past the sticky threshold
PPM0="$OUT/sticky0.ppm"
PPMS="$OUT/stickyS.ppm"
PNG0="$OUT/sticky0.png"
PNGS="$OUT/stickyS.png"
SCROLL=12
mkdir -p "$OUT"
fail=0

echo "[hb-sticky] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/sticky_compile.log"; then
    echo "[hb-sticky] FAIL: driver did not compile"; cat "$OUT/sticky_compile.log"; exit 1
fi
echo "[hb-sticky] PASS pixel backend compiled -> $BIN"

echo "[hb-sticky] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/sticky_native.log"; then
    echo "[hb-sticky] FAIL: native hambrowse did not compile"; cat "$OUT/sticky_native.log"; exit 1
fi
echo "[hb-sticky] PASS native hambrowse still compiles"

echo "[hb-sticky] rendering $FIX (unscrolled) ..."
if ! "$BIN" "$FIX" "$PPM0" 640 >"$D0" 2>&1; then
    echo "[hb-sticky] FAIL: unscrolled render exited non-zero"; cat "$D0"; exit 1
fi
echo "[hb-sticky] rendering $FIX (scroll $SCROLL) ..."
if ! "$BIN" "$FIX" "$PPMS" 640 scroll "$SCROLL" >"$DS" 2>&1; then
    echo "[hb-sticky] FAIL: scrolled render exited non-zero"; cat "$DS"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM0" "$PNG0" 2>/dev/null && \
    echo "[hb-sticky] wrote $PNG0 for eyeballing" || true
python3 scripts/ppm_to_png.py "$PPMS" "$PNGS" 2>/dev/null && \
    echo "[hb-sticky] wrote $PNGS for eyeballing" || true

echo "--- unscrolled POSFILL ---"; grep -E '^POSFILL' "$D0" || true
echo "--- scroll $SCROLL POSFILL ---"; grep -E '^POSFILL' "$DS" || true

# Field extractor: echo the y0 (top pixel) of the FIRST POSFILL whose declared
# colour matches. POSFILL i z Z x0 X y0 Y x1 X y1 Y col C pix P  => y0 is $8.
y_for() { awk -v c="$1" '$1=="POSFILL" && $14==c {print $8; exit}' "$2"; }

FIX0=$(y_for '#ff00aa' "$D0")     # fixed bar, unscrolled
FIXS=$(y_for '#ff00aa' "$DS")     # fixed bar, scrolled
ANC0=$(y_for '#cccccc' "$D0")     # positioned ancestor (relative)
TOP0=$(y_for '#eeeeee' "$D0")     # first filler == page top
STK0=$(y_for '#00ffaa' "$D0")     # sticky header, unscrolled
STKS=$(y_for '#00ffaa' "$DS")     # sticky header, scrolled
SCR0=$(y_for '#dddddd' "$D0")     # scroll container top
NRM0=$(y_for '#ffaa00' "$D0")     # first normal content row, unscrolled
NRMS=$(y_for '#ffaa00' "$DS")     # first normal content row, scrolled

echo "[hb-sticky] fixed: y0=$FIX0 (scroll0) -> $FIXS (scroll$SCROLL); ancestor.y=$ANC0 pagetop.y=$TOP0"
echo "[hb-sticky] sticky: y0=$STK0 (scroll0) -> $STKS (scroll$SCROLL); scroller.y=$SCR0 normal.y=$NRM0->$NRMS"

need() { [ -n "$1" ] || { echo "[hb-sticky] FAIL: missing box ($2)"; fail=1; return 1; }; return 0; }
for v in "$FIX0:fixed0" "$FIXS:fixedS" "$ANC0:ancestor" "$TOP0:pagetop" \
         "$STK0:sticky0" "$STKS:stickyS" "$SCR0:scroller" "$NRM0:normal0" "$NRMS:normalS"; do
    need "${v%%:*}" "${v##*:}" || true
done

# (1) FIXED pins to the VIEWPORT, not its positioned ancestor: the bar (declared
# inside a pushed-down position:relative ancestor) paints at the page top, ABOVE
# the ancestor's box.
if [ "$fail" -eq 0 ] && [ "$FIX0" -le "$TOP0" ] && [ "$FIX0" -lt "$ANC0" ]; then
    echo "[hb-sticky] PASS fixed pins to viewport top (fixed.y=$FIX0 <= pagetop=$TOP0, above ancestor.y=$ANC0)"
else
    echo "[hb-sticky] FAIL fixed not viewport-pinned (fixed=$FIX0 pagetop=$TOP0 ancestor=$ANC0)"; fail=1
fi

# (2) FIXED tracks the viewport under scroll — moves down to the scrolled top.
if [ "$fail" -eq 0 ] && [ "$FIXS" -gt "$FIX0" ]; then
    echo "[hb-sticky] PASS fixed tracks the viewport under scroll (y $FIX0 -> $FIXS)"
else
    echo "[hb-sticky] FAIL fixed did not track scroll (y $FIX0 -> $FIXS)"; fail=1
fi

# (3) STICKY is IN-FLOW when unscrolled — the header sits at its scroll
# container's top edge, above the normal content.
if [ "$fail" -eq 0 ] && [ "$STK0" -eq "$SCR0" ] && [ "$STK0" -lt "$NRM0" ]; then
    echo "[hb-sticky] PASS sticky is in-flow at scroll 0 (sticky.y=$STK0 == scroller.y=$SCR0, above normal.y=$NRM0)"
else
    echo "[hb-sticky] FAIL sticky not in-flow at container top (sticky=$STK0 scroller=$SCR0 normal=$NRM0)"; fail=1
fi

# (4) STICKY PINS once the viewport scrolls past it — repositions to the viewport
# top (coincident with the fixed bar), while ordinary in-flow content stays put.
if [ "$fail" -eq 0 ] && [ "$STKS" -gt "$STK0" ] && [ "$STKS" -eq "$FIXS" ]; then
    echo "[hb-sticky] PASS sticky pins to viewport top when scrolled past (y $STK0 -> $STKS, == fixed $FIXS)"
else
    echo "[hb-sticky] FAIL sticky did not pin to viewport top (sticky $STK0->$STKS fixed=$FIXS)"; fail=1
fi
if [ "$fail" -eq 0 ] && [ "$NRMS" -eq "$NRM0" ]; then
    echo "[hb-sticky] PASS ordinary in-flow content did NOT move under scroll (normal.y=$NRM0)"
else
    echo "[hb-sticky] FAIL normal content moved (should be static: $NRM0 -> $NRMS)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-sticky] RESULT: PASS"
else
    echo "[hb-sticky] RESULT: FAIL"; exit 1
fi
