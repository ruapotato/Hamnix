#!/usr/bin/env bash
# scripts/test_hambrowse_boxr2_host.sh — FAST, QEMU-free gate for the ROUND-2
# box-model / flex / position cascade properties in the native browser engine
# (lib/web/css/cascade.ad). Each is a property the LAYOUT module needs; the ones
# that map onto the existing width / positioned-offset paths are asserted on real
# engine coordinates here:
#
#   (A) min-width       — floors the content column (min-width:300px alone pins a
#                         316px box on an 800px viewport).
#   (B) box-sizing      — border-box subtracts the horizontal padding from the
#                         declared width, so a border-box box is NARROWER than the
#                         same content-box box by exactly the padding (2*40=80).
#   (C) flex-basis      — a length basis seeds the item main-size (250px -> 266px).
#   (D) flex shorthand  — `flex: 0 0 180px` extracts the 180px basis (-> 196px).
#   (E) position:sticky — distinct from static: applies its relative offset now
#                         (left:60px shifts +60px) whereas static ignores offsets.
#   (F) vertical-align / text-indent — parse without regressing the render (the
#                         styled element still lays out; consumed by a later round).
#
# Builds BOTH targets so a break in either backend is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_boxr2.html"
mkdir -p "$OUT"

echo "[hb-boxr2] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-boxr2] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-boxr2] PASS host harness compiled -> $BIN"

echo "[hb-boxr2] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-boxr2] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-boxr2] PASS native hambrowse still compiles"

fail=0
D="$OUT/boxr2.txt"
"$BIN" "$FIX" 800 >"$D" 2>&1 || { echo "[hb-boxr2] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# FILL lines are "FILL top bot lx rx #hex"; width = rx - lx.
fill_w()  { grep -E "FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ $1( |$)" "$D" | awk '{print $5-$4}' | head -1; }
fill_lx() { grep -E "FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ $1( |$)" "$D" | awk '{print $4}' | head -1; }
seg_x()   { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $3}' | head -1; }
seg_present() { grep -Eq "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D"; }

# ---- (A) min-width floors the width ------------------------------------------
mww=$(fill_w '#eeeeee')
echo "[hb-boxr2] min-width box width=$mww (expect ~316, well under the ~700 full width)"
if [ -n "$mww" ] && [ "$mww" -ge 300 ] && [ "$mww" -le 340 ]; then
    echo "[hb-boxr2] PASS min-width:300px floors the box to $mww px"
else
    echo "[hb-boxr2] FAIL min-width not applied (width=$mww)"; fail=1
fi

# ---- (B) box-sizing: border-box narrower than content-box by the padding -----
bbw=$(fill_w '#ddccbb')     # border-box
cbw=$(fill_w '#bbccdd')     # content-box
echo "[hb-boxr2] box-sizing widths: border-box=$bbw content-box=$cbw (expect content-box wider by 80)"
if [ -n "$bbw" ] && [ -n "$cbw" ] && [ "$cbw" -gt "$bbw" ] && \
   [ "$((cbw - bbw))" -eq 80 ]; then
    echo "[hb-boxr2] PASS border-box subtracts 2*40px padding from the width ($cbw-$bbw=80)"
else
    echo "[hb-boxr2] FAIL box-sizing width delta (border=$bbw content=$cbw)"; fail=1
fi

# ---- (C) flex-basis seeds the main-size --------------------------------------
fbw=$(fill_w '#c0ffee')
echo "[hb-boxr2] flex-basis box width=$fbw (expect ~266 = 250 + chrome)"
if [ -n "$fbw" ] && [ "$fbw" -ge 250 ] && [ "$fbw" -le 290 ]; then
    echo "[hb-boxr2] PASS flex-basis:250px seeds a 250px main-size ($fbw px)"
else
    echo "[hb-boxr2] FAIL flex-basis not applied (width=$fbw)"; fail=1
fi

# ---- (D) flex shorthand basis (flex: 0 0 180px) ------------------------------
fxw=$(fill_w '#facade')
echo "[hb-boxr2] flex shorthand box width=$fxw (expect ~196 = 180 + chrome)"
if [ -n "$fxw" ] && [ "$fxw" -ge 180 ] && [ "$fxw" -le 210 ]; then
    echo "[hb-boxr2] PASS 'flex: 0 0 180px' extracts the 180px basis ($fxw px)"
else
    echo "[hb-boxr2] FAIL flex shorthand basis not applied (width=$fxw)"; fail=1
fi

# ---- (E) position:sticky stays in flow at scroll 0 ---------------------------
# CORRECTED 2026-07-27. This block used to demand that `position:sticky;left:60px`
# render 60px right of an otherwise identical static box. That is NOT what a
# browser does: a sticky box's inset offsets only bite once its scroll container
# has scrolled past the corresponding threshold, and an unscrolled page has no
# horizontal scrolling at all, so `left` is inert. `chromium --headless` on THIS
# fixture reports both boxes at x=8.0 (getBoundingClientRect):
#     DIV(sticky left:60px top:0) x=8.0 y=116.0
#     DIV(static left:60px)       x=8.0 y=134.0
# The engine already renders both at x=8, i.e. it was CORRECT and the old
# assertion pinned a browser-contradicting expectation. Assert the real invariant
# instead: sticky lays out in normal flow at scroll 0 — same inline position as a
# static sibling, one flow row below it — so a sticky header does not jump
# sideways before the user scrolls.
skx=$(seg_x StickyEl)
stx=$(seg_x StaticEl)
echo "[hb-boxr2] sticky x=$skx  static x=$stx (expect equal — the left inset is inert at scroll 0, as in Chrome)"
if [ -n "$skx" ] && [ -n "$stx" ] && [ "$skx" -eq "$stx" ]; then
    echo "[hb-boxr2] PASS position:sticky lays out in flow at scroll 0 (left inset inert, matches Chrome)"
else
    echo "[hb-boxr2] FAIL sticky moved out of flow at scroll 0 (sticky=$skx static=$stx)"; fail=1
fi

# ---- (F) vertical-align / text-indent parse without regressing the render ----
if seg_present ValignIndent; then
    echo "[hb-boxr2] PASS vertical-align + text-indent parse without breaking the render"
else
    echo "[hb-boxr2] FAIL vertical-align/text-indent element vanished"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-boxr2] RESULT: FAIL"; exit 1
fi
echo "[hb-boxr2] RESULT: PASS"
