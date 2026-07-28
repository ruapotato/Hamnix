#!/usr/bin/env bash
# scripts/test_hambrowse_keyframes_host.sh — FAST, QEMU-free render-to-PNG gate
# for CSS animations (@keyframes + animation/animation-name) in the STATIC
# END-STATE model. lib/web/css/cascade.ad.
#
# THE GAP: the engine had NO animation support — `@keyframes` blocks were
# brace-skipped by _parse_at_rule and `animation`/`animation-name` declarations
# were silently ignored, so an element that settles to a keyframed end colour
# (a fade-in, a colour-cycle, a reveal) rendered its BASE (pre-animation) state.
#
# THE FEATURE: _parse_at_rule now records a @keyframes definition's SETTLED frame
# (`100%`/`to`, else the last frame) as an inert end-state pseudo-rule keyed by
# the interned animation name; a rule/element declaring `animation`/
# `animation-name` resolves that name and _cascade_match_current OVERLAYS the
# keyframe's background/colour/transform/border-colour onto the cascade winners.
# This models `animation-fill-mode: forwards` / the visually-settled end of a
# finite animation — the honest choice for a headless single render (no timeline).
#
# This gate renders one fixture and pixel-asserts each box's background:
#   .fade    -> #00aa00  (100% frame of @keyframes fadein; overrides base #333)
#   .slide   -> #cc0000  (`to` frame of @keyframes reveal via animation-name)
#   .noanim  -> #112233  (no animation: base survives)
#   .missing -> #445566  (animation-name has NO matching @keyframes: base survives)
#
# Renders via the pixel backend (lib/htmlpaint + lib/htmlpage) — no QEMU boot.
# See docs/browser_w3c_conformance.md.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_keyframes.html"
mkdir -p "$OUT"
fail=0

echo "[hb-kf] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/kf_gfx.log"; then
    echo "[hb-kf] FAIL: pixel backend did not compile"; cat "$OUT/kf_gfx.log"; exit 1
fi
echo "[hb-kf] PASS pixel backend compiled -> $GFX"

echo "[hb-kf] confirming native hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/kf_native.elf" 2>"$OUT/kf_native.log"; then
    echo "[hb-kf] FAIL: native hambrowse did not compile"; cat "$OUT/kf_native.log"; exit 1
fi
echo "[hb-kf] PASS native hambrowse still compiles"

pass() { echo "[hb-kf] PASS $1"; }
bad()  { echo "[hb-kf] FAIL $1"; fail=1; }

col_of() {  # sampled paint colour of POSFILL rect index $2 in dump $1
    awk -v idx="$2" '$1=="POSFILL" && $2==idx {
        for(i=1;i<=NF;i++) if($i=="pix") print $(i+1)}' "$1"
}

D="$OUT/kf.txt"
if ! "$GFX" "$FIX" "$OUT/kf.ppm" 880 >"$D" 2>&1; then
    echo "[hb-kf] FAIL: render exited non-zero"; cat "$D"; exit 1
fi
python3 scripts/ppm_to_png.py "$OUT/kf.ppm" "$OUT/kf.png" >/dev/null 2>&1 \
    && echo "[hb-kf] wrote $OUT/kf.png"

grep -E '^POSFILL' "$D" || true

expect() {  # expect <label> <idx> <want-color>
    got="$(col_of "$D" "$2")"
    if [ "$got" = "$3" ]; then pass "$1 (idx $2 = $got)"
    else bad "$1 (idx $2: got '${got:-none}', want $3)"; fi
}

expect "fade settles to @keyframes 100% frame (#00aa00)"       0 "#00aa00"
expect "slide settles to @keyframes 'to' frame via animation-name (#cc0000)" 1 "#cc0000"
expect "noanim keeps base (#112233)"                           2 "#112233"
expect "missing keyframes keeps base (#445566)"                3 "#445566"

if [ "$fail" -ne 0 ]; then
    echo "[hb-kf] RESULT: FAIL"; exit 1
fi
echo "[hb-kf] RESULT: PASS"
