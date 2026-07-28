#!/usr/bin/env bash
# scripts/test_hambrowse_svgpctwidth.sh — FAST, QEMU-free gate proving a
# PERCENTAGE CSS width on an inline <svg> does NOT balloon the replaced icon to
# the full content column.
#
# Real pages (google.com) ship `svg{width:100%;height:100%}` (or `.foo
# svg{width:100%}`) intending the icon to fill a SMALL sized parent (e.g. a 24px
# span). Our engine resolves a `%` width against the PAGE width, so honouring it
# rasterised a tiny magnifying-glass/tool icon at ~1184px — a giant pixelated
# blob that also collapsed the search box. The fix: a replaced <svg> that
# already has an intrinsic box (attr / viewBox) DECLINES a percentage width and
# keeps its intrinsic/attr size, mirroring the existing `max-width:100%` rule.
# A FIXED-length CSS width (svg{width:300px}) is a real pin and STILL upscales.
#
# The fixture tests/fixtures/hambrowse_svgpctwidth.html carries three inline
# <svg>s under a global `svg{width:100%;height:100%}` rule:
#   1. a viewBox-only 24x24 icon           -> must render 24x24  (% declined)
#   2. width=24 height=24 + big viewBox     -> must render 24x24  (attr wins)
#   3. class="big" {width:300px;height:200px} viewBox 0 0 24 24
#                                           -> must render 300x200 (fixed px upscales)
# None may reach the ~600px content column.
#
# Built with the frozen Python seed compiler (no self-host bootstrap).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-svgpct] compiling pixel backend ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/svgpct_compile.log"; then
    echo "[hb-svgpct] FAIL: driver did not compile"; cat "$OUT/svgpct_compile.log"; exit 1
fi
echo "[hb-svgpct] PASS pixel backend compiled -> $BIN"

echo "[hb-svgpct] compiling native hambrowse (dual-target) ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse.native" 2>"$OUT/svgpct_native.log"; then
    echo "[hb-svgpct] FAIL: native hambrowse did not compile"
    cat "$OUT/svgpct_native.log"; exit 1
fi
echo "[hb-svgpct] PASS native hambrowse compiled"

FIX="tests/fixtures/hambrowse_svgpctwidth.html"
[ -s "$FIX" ] || { echo "[hb-svgpct] FAIL: missing fixture $FIX"; exit 1; }

PPM="$OUT/gfx_svgpctwidth.ppm"
DUMP="$OUT/svgpct_dump.txt"

echo "[hb-svgpct] rendering $FIX at 640px ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-svgpct] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-svgpct] PASS $msg"
    else
        echo "[hb-svgpct] FAIL $msg (missing: $pat)"
        grep -E '^IMGSEG ' "$DUMP" | head; fail=1
    fi
}
assert_no_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-svgpct] FAIL $msg (present: $pat)"
        grep -E '^IMGSEG ' "$DUMP" | head; fail=1
    else
        echo "[hb-svgpct] PASS $msg"
    fi
}

# 1 & 2: viewBox-only and attr-sized icons stay 24x24 — the % width is declined.
assert_grep  '^IMGSEG slot 0 w 24 h 24 '  "viewBox-only <svg> keeps 24x24 (percentage width declined)"
assert_grep  '^IMGSEG slot 1 w 24 h 24 '  "width=24 attr <svg> keeps 24x24 under svg{width:100%}"
# 3: a FIXED-length CSS size still upscales the viewBox to 300x200.
assert_grep  '^IMGSEG slot 2 w 300 h 200 ' "fixed-length CSS width:300px still upscales the viewBox"
# 4: an UNSIZED large-viewBox <svg> (no width/height attr, no fixed CSS px, the
# global svg{width:100%} declined) falls back to a 24x24 inline-icon default —
# it must NOT balloon to the 960 viewBox extent and must NOT shrink to 0/vanish.
assert_grep  '^IMGSEG slot 3 w 24 h 24 ' \
    "unsized 960-viewBox <svg> defaults to 24x24 (no balloon, no vanish)"
assert_no_grep '^IMGSEG slot 3 w 0 ' "unsized <svg> is not shrunk to width 0"
assert_no_grep '^IMGSEG slot 3 w 960 ' "unsized <svg> does not balloon to the 960 viewBox extent"
# Guard: NO inline <svg> ballooned toward the ~600px content column.
assert_no_grep '^IMGSEG slot [0-9]+ w (6[0-9][0-9]|[0-9]{4,}) ' \
    "no inline <svg> balloons to the content column width"

if [ "$fail" -eq 0 ]; then
    echo "[hb-svgpct] PASS"
else
    echo "[hb-svgpct] FAIL"; exit 1
fi
