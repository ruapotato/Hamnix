#!/usr/bin/env bash
# scripts/test_hambrowse_media_host.sh — FAST, QEMU-free render-to-PNG gate for
# CSS @media queries (responsive CSS). lib/web/css/cascade.ad.
#
# THE GAP: the engine had NO @media support at all — a `@media (...) { ... }`
# block was mis-parsed by the ruleset scanner (the prelude read as a selector,
# the inner rules as garbage declarations) and silently dropped. Every modern
# responsive site gates its layout on width breakpoints, so none of that applied.
#
# THE FEATURE: _parse_at_rule + _media_matches/_mq_query/_mq_feature evaluate a
# Media Queries L4 subset against the live viewport (bw x bh): media types
# (screen/all match, print/speech do not), `and`, comma (OR), `not`, `only`, and
# the range/discrete features min/max-width, width, min/max-height, height,
# orientation, prefers-color-scheme. A matching block's inner rulesets cascade
# exactly like top-level rules; a non-matching block is skipped; other at-rules
# (@keyframes/@font-face/@supports/@import/@charset) are skipped cleanly.
#
# This gate renders the SAME fixture at three viewport widths and pixel-asserts
# each element's background flips per the breakpoint it should match:
#   width 400 (portrait) : .box #00aa00 (max-width:500), .mid/.ornt base
#   width 700 (landscape): .box base, .mid #8800ff (600..900), .ornt #00cccc
#   width 1000(landscape): .box #cc0000 (min-width:800), .mid base, .ornt #00cccc
#   prefers-color-scheme:dark never matches (engine renders light) at any width.
#
# Renders via the pixel backend (lib/htmlpaint + lib/htmlpage) — no QEMU boot.
# See docs/browser_w3c_conformance.md.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_media.html"
mkdir -p "$OUT"
fail=0

echo "[hb-mq] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/mq_gfx.log"; then
    echo "[hb-mq] FAIL: pixel backend did not compile"; cat "$OUT/mq_gfx.log"; exit 1
fi
echo "[hb-mq] PASS pixel backend compiled -> $GFX"

echo "[hb-mq] confirming native hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/mq_native.elf" 2>"$OUT/mq_native.log"; then
    echo "[hb-mq] FAIL: native hambrowse did not compile"; cat "$OUT/mq_native.log"; exit 1
fi
echo "[hb-mq] PASS native hambrowse still compiles"

pass() { echo "[hb-mq] PASS $1"; }
bad()  { echo "[hb-mq] FAIL $1"; fail=1; }

# The paint colour of POSFILL rect index $2 in dump $1.
col_of() {
    awk -v idx="$2" '$1=="POSFILL" && $2==idx {
        for(i=1;i<=NF;i++) if($i=="col") print $(i+1)}' "$1"
}

render() {  # render() <width> -> writes $OUT/mq_<width>.txt
    w="$1"; d="$OUT/mq_${w}.txt"
    if ! "$GFX" "$FIX" "$OUT/mq_${w}.ppm" "$w" >"$d" 2>&1; then
        echo "[hb-mq] FAIL: render at width $w exited non-zero"; cat "$d"; exit 1
    fi
    python3 scripts/ppm_to_png.py "$OUT/mq_${w}.ppm" "$OUT/mq_${w}.png" \
        >/dev/null 2>&1 && echo "[hb-mq] wrote $OUT/mq_${w}.png"
}

expect() {  # expect <label> <dumpfile> <idx> <want-color>
    got="$(col_of "$2" "$3")"
    if [ "$got" = "$4" ]; then
        pass "$1 (idx $3 = $got)"
    else
        bad "$1 (idx $3: got '${got:-none}', want $4)"
    fi
}

# ---- width 400: narrow / portrait -----------------------------------------
render 400; D400="$OUT/mq_400.txt"
expect "w400 .box max-width:500 matches"        "$D400" 0 "#00aa00"
expect "w400 .mid 600..900 does NOT match (base)" "$D400" 1 "#333333"
expect "w400 .ornt portrait, not landscape (base)" "$D400" 2 "#444444"
expect "w400 prefers dark never matches (base)"  "$D400" 3 "#555555"

# ---- width 700: mid / landscape -------------------------------------------
render 700; D700="$OUT/mq_700.txt"
expect "w700 .box no breakpoint (base)"          "$D700" 0 "#112233"
expect "w700 .mid 600..900 AND matches"          "$D700" 1 "#8800ff"
expect "w700 .ornt landscape matches"            "$D700" 2 "#00cccc"
expect "w700 prefers dark never matches (base)"  "$D700" 3 "#555555"

# ---- width 1000: wide / landscape -----------------------------------------
render 1000; D1000="$OUT/mq_1000.txt"
expect "w1000 .box min-width:800 matches"        "$D1000" 0 "#cc0000"
expect "w1000 .mid out of 600..900 range (base)" "$D1000" 1 "#333333"
expect "w1000 .ornt landscape matches"           "$D1000" 2 "#00cccc"
expect "w1000 prefers dark never matches (base)" "$D1000" 3 "#555555"

if [ "$fail" -ne 0 ]; then
    echo "[hb-mq] RESULT: FAIL"; exit 1
fi
echo "[hb-mq] RESULT: PASS"
