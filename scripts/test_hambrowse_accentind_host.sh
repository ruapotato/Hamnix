#!/usr/bin/env bash
# scripts/test_hambrowse_accentind_host.sh — FAST, QEMU-free render-to-PNG gate
# for CSS `accent-color` + `:indeterminate` on checkbox/radio controls (round-7
# form-control polish). lib/web/css/cascade.ad + lib/web/dom/forms.ad +
# lib/web/layout/box.ad + lib/htmlpage.ad.
#
# THE GAP (round-6): the checkbox/radio pixel painter used a FIXED accent blue
# rgb(26,115,232) and knew only 2 states (checked/unchecked) — CSS `accent-color`
# and the `:indeterminate` state were ignored.
#
# THE FEATURE: `accent-color` now rides the cascade (d_accent/m_accent/r_accent,
# shared _box_decl parse -> both stylesheet and inline style="") and is resolved
# for the void <input> via a transient _img_cascade, stashed per-segment in
# seg_accent; the painter fills the checked box / radio dot / indeterminate dash
# in that colour (UA blue when unset). An `indeterminate` boolean attribute is
# the honest static trigger for `:indeterminate` (state 2) -> an accent box with
# a centred white DASH (distinct from the checked diagonal tick).
#
# Controls (document order -> CTRL index):
#   0 .redcb checked          -> SQUARE fill #dd2222 (stylesheet accent-color)
#   1 indeterminate           -> SQUARE fill #1a73e8 dash=1 (UA-blue :indeterminate)
#   2 checked                 -> SQUARE fill #1a73e8 dash=0 (UA-blue checked)
#   3 .greenrb radio checked  -> CIRCLE fill #22aa33 (stylesheet accent on a dot)
#   4 inline accent-color     -> SQUARE fill #ee8800 (inline style="" accent-color)
#
# Renders via the pixel backend (lib/htmlpaint + lib/htmlpage) — no QEMU boot.
# See docs/browser_w3c_conformance.md.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_accentind.html"
mkdir -p "$OUT"
fail=0

echo "[hb-ai] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/ai_gfx.log"; then
    echo "[hb-ai] FAIL: pixel backend did not compile"; cat "$OUT/ai_gfx.log"; exit 1
fi
echo "[hb-ai] PASS pixel backend compiled -> $GFX"

echo "[hb-ai] confirming native hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/ai_native.elf" 2>"$OUT/ai_native.log"; then
    echo "[hb-ai] FAIL: native hambrowse did not compile"; cat "$OUT/ai_native.log"; exit 1
fi
echo "[hb-ai] PASS native hambrowse still compiles"

pass() { echo "[hb-ai] PASS $1"; }
bad()  { echo "[hb-ai] FAIL $1"; fail=1; }

D="$OUT/ai.txt"
if ! "$GFX" "$FIX" "$OUT/ai.ppm" 880 >/dev/null 2>"$D"; then
    echo "[hb-ai] FAIL: render exited non-zero"; cat "$D"; exit 1
fi
python3 scripts/ppm_to_png.py "$OUT/ai.ppm" "$OUT/ai.png" >/dev/null 2>&1 \
    && echo "[hb-ai] wrote $OUT/ai.png"

PROBE="$OUT/ai_probe.txt"
python3 scripts/hb_accentind_probe.py "$OUT/ai.ppm" >"$PROBE" 2>&1
echo "--- probe ---"; cat "$PROBE"; echo "-------------"

field() {  # field <ctrl-idx> <key>   -> value of key=... on that CTRL line
    awk -v idx="$1" -v k="$2" '$1=="CTRL"{
        for(i=1;i<=NF;i++){ split($i,a,"="); if(a[1]=="i") ci=a[2] }
        if(ci==idx){ for(i=1;i<=NF;i++){ split($i,a,"="); if(a[1]==k) print a[2] } }
    }' "$PROBE"
}

chk() {  # chk <label> <idx> <shape> <fill> <dash>
    gs="$(field "$2" shape)"; gf="$(field "$2" fill)"; gd="$(field "$2" dash)"
    if [ "$gs" = "$3" ] && [ "$gf" = "$4" ] && [ "$gd" = "$5" ]; then
        pass "$1 (idx $2: $gs $gf dash=$gd)"
    else
        bad "$1 (idx $2: got '$gs $gf dash=$gd', want '$3 $4 dash=$5')"
    fi
}

chk "stylesheet accent-color red checkbox"       0 SQUARE "#dd2222" 0
chk "indeterminate UA-blue dashed checkbox"      1 SQUARE "#1a73e8" 1
chk "default UA-blue checked checkbox"           2 SQUARE "#1a73e8" 0
chk "stylesheet accent-color green radio dot"    3 CIRCLE "#22aa33" 0
chk "inline style accent-color orange checkbox"  4 SQUARE "#ee8800" 0

if [ "$fail" -ne 0 ]; then
    echo "[hb-ai] RESULT: FAIL"; exit 1
fi
echo "[hb-ai] RESULT: PASS"
