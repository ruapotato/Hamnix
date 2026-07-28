#!/usr/bin/env bash
# scripts/test_hambrowse_inlbmargin_host.sh — FAST, QEMU-free gate for two
# small-pixel-area but visually-critical browser fixes (RMSE under-weights them):
#
#   1. A `display:inline-block` span/anchor that is STYLED (border + border-radius
#      + padding + width + background) must paint a REAL bordered, rounded, filled
#      BOX with its text inside — inline in the flow — not raw text. (Chrome's
#      search box / CTA / badge idiom.) Earlier only <input>/<button> got real
#      boxes; this extends it to styled inline-block spans.
#   2. Inline / inline-block elements with margin-left/right must render SPACED,
#      not glued (`AllNewsMaps`). The horizontal margin advances the inline flow.
#
# Builds the text-dump harness (asserts the FILL/SEG display list), the pixel
# backend (exercises the rounded-border rasteriser), and confirms native
# hambrowse still compiles — all with NO QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_inlbmargin.html"
mkdir -p "$OUT"
fail=0

echo "[hb-ilm] compiling text harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/ilm_compile.log"; then
    echo "[hb-ilm] FAIL: host harness did not compile"; cat "$OUT/ilm_compile.log"; exit 1
fi
echo "[hb-ilm] PASS text harness compiled"

echo "[hb-ilm] compiling pixel backend for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/ilm_gfx.log"; then
    echo "[hb-ilm] FAIL: pixel backend did not compile"; cat "$OUT/ilm_gfx.log"; exit 1
fi
echo "[hb-ilm] PASS pixel backend compiled"

echo "[hb-ilm] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/ilm_native.log"; then
    echo "[hb-ilm] FAIL: native hambrowse did not compile"; cat "$OUT/ilm_native.log"; exit 1
fi
echo "[hb-ilm] PASS native hambrowse still compiles"

# Render at width 600 (== MEASURE_MAX + 2*CONTENT_X) so no centring gutter offsets
# the pinned x-positions.
D0="$OUT/ilm_run.txt"
"$BIN" "$FIX" 600 >"$D0" 2>&1 || { echo "[hb-ilm] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E '^FILL|^SEG' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-ilm] PASS $2"
    else
        echo "[hb-ilm] FAIL $2 (missing: $1)"; fail=1
    fi
}

# --- FIX 1: the styled inline-block .sbox paints a real box ---
# FILL line: "FILL top bot lx rx #hex rad z padt padb b#hex".
# width:200 + padding:6px 14px -> a 228px-wide box, radius 16, white fill, 6px
# top/bottom pad, and a #dfe1e5 border stroke (b#dfe1e5, NOT b-).
#
# lx is 0, NOT 14. This gate used to pin lx=14 / text x=28 — the chip shifted
# right by its own padding-left, because the box model folds margin-left and
# padding-left into one inset column and the inline-block path (which models its
# padding separately) counted it twice. `chromium --headless`
# getBoundingClientRect on THIS fixture's .sbox:
#     box 0.0..230.0  w=230.0  text 15.0
# i.e. the border box starts at the body's left edge and the text is inset by
# the padding alone (15 = the 1px border + 14px padding; this engine does not
# reserve the border column, so it reads 14). The old expectation was the bug.
assert_grep '^FILL 0 1 0 228 #ffffff 16 0 6 6 b#dfe1e5' \
    "styled inline-block paints a rounded (r16) bordered (#dfe1e5) filled box at lx=0, width 228"
# The box text flows INSIDE the box, inset by the 14px left padding (chromium: 15).
assert_grep '^SEG 0 14 #202124 .*\|query text\|' \
    "the inline-block box text renders inside the box (x=14 = lx0 + pad14)"

# --- FIX 2: inline horizontal margins space the tabs ---
# .tabs span { margin-right:20px }. "All"(x=0), then each following tab is pushed
# right by the 20px margin: "News" at 44 (24 for 'All' + 20), "Maps" at 96
# (44 + 32 for 'News' + 20). Without the fix they glue at 24 and 56.
assert_grep '^SEG 2 0 #5f6368 .*\|All\|'   "first inline tab at the left margin (x=0)"
assert_grep '^SEG 2 44 #5f6368 .*\|News\|' "margin-right:20px spaces the 2nd tab (x=44, not glued at 24)"
assert_grep '^SEG 2 96 #5f6368 .*\|Maps\|' "cumulative inline margins space the 3rd tab (x=96, not glued at 56)"

# --- Pixel path: exercise the real rounded-border rasteriser (no QEMU) ---
PPM="$OUT/ilm.ppm"; PNG="$OUT/ilm.png"
if "$GFX" "$FIX" "$PPM" 600 >"$OUT/ilm_gfx_dump.txt" 2>&1; then
    if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/ilm_png.log"; then
        echo "[hb-ilm] PASS pixel render -> $PNG ($(file -b "$PNG" 2>/dev/null))"
    else
        echo "[hb-ilm] FAIL png conversion"; cat "$OUT/ilm_png.log"; fail=1
    fi
else
    echo "[hb-ilm] FAIL: pixel render exited non-zero"; cat "$OUT/ilm_gfx_dump.txt"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-ilm] RESULT: FAIL"; exit 1
fi
echo "[hb-ilm] RESULT: PASS"
