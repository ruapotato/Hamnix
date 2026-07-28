#!/usr/bin/env bash
# scripts/test_hambrowse_extcss.sh — FAST, QEMU-free regression for EXTERNAL
# stylesheets (<link rel=stylesheet href=...>). The engine (lib/htmlengine.ad)
# now hands a front-end the linked hrefs (he_css_scan_links), ingests the fetched
# bytes (he_css_append), and cascades them through the SAME path as inline
# <style>. The host harness loads a local .css (the offline stand-in for the
# native browser's http9 <link> fetch) via:  FILE WIDTH css SHEET.css
#
# The SAME html + SAME binary is rendered twice — WITHOUT the sheet (pre) and
# WITH it (post) — so the pass proves the linked rules, and only the linked
# rules, produced the change:
#   * .masthead text-align:center  -> the h1 shifts right (x>320) only WITH css;
#   * .sidebar float:right         -> the SIDEBAR paragraph pins right (x>=500);
#   * .lede font-weight:bold       -> the LEDE paragraph turns bold (b1);
#   * .warn color:#b00020          -> the WARNBLOCK paragraph turns red.
# WITHOUT the sheet all four sit at the left margin, unstyled (x=8, b0, black).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_extcss.html"
CSS="tests/fixtures/hambrowse_extcss.css"
mkdir -p "$OUT"

echo "[hb-extcss] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/extcss_compile.log"; then
    echo "[hb-extcss] FAIL: host harness did not compile"; cat "$OUT/extcss_compile.log"; exit 1
fi
echo "[hb-extcss] PASS host harness compiled -> $BIN"

PRE="$OUT/extcss_pre.txt"
POST="$OUT/extcss_post.txt"
"$BIN" "$FIX" 900 >"$PRE" 2>&1              || { echo "[hb-extcss] FAIL: pre run"; cat "$PRE"; exit 1; }
"$BIN" "$FIX" 900 css "$CSS" >"$POST" 2>&1  || { echo "[hb-extcss] FAIL: post run"; cat "$POST"; exit 1; }
echo "=== WITHOUT external sheet ==="; cat "$PRE"
echo "=== WITH external sheet ===";    cat "$POST"

fail=0
assert_in() {  # pattern file msg
    if grep -Eq -- "$1" "$2"; then echo "[hb-extcss] PASS $3"
    else echo "[hb-extcss] FAIL $3  (/$1/ expected in $(basename "$2"))"; fail=1; fi
}
refute_in() {  # pattern file msg
    if grep -Eq -- "$1" "$2"; then echo "[hb-extcss] FAIL $3  (/$1/ unexpectedly in $(basename "$2"))"; fail=1
    else echo "[hb-extcss] PASS $3"; fi
}

# Both runs produced a layout.
assert_in 'LAYOUT segs=[1-9]' "$POST" "layout produced segments (with sheet)"

# --- .sidebar float:right (the linked layout rule) -------------------
# WITH the sheet the SIDEBAR paragraph pins to the right (x>=500); WITHOUT it it
# sits at the left margin (x=158).
assert_in '^SEG [0-9]+ (5|6|7)[0-9][0-9] .*SIDEBAR' "$POST" \
    "linked .sidebar{float:right} pins the sidebar to the right edge"
refute_in '^SEG [0-9]+ (5|6|7)[0-9][0-9] .*SIDEBAR' "$PRE" \
    "sidebar is NOT floated without the external sheet"

# --- .masthead text-align:center -------------------------------------
assert_in '^SEG 0 (3|4)[0-9][0-9] .*EXTHEAD' "$POST" \
    "linked .masthead{text-align:center} centres the masthead"
refute_in '^SEG 0 (3|4)[0-9][0-9] .*EXTHEAD' "$PRE" \
    "masthead is left-aligned without the external sheet"

# --- .lede font-weight:bold ------------------------------------------
assert_in '^SEG [0-9]+ 8 #[0-9a-f]+ b1 u0 s0 l-1 bg- .LEDE' "$POST" \
    "linked .lede{font-weight:bold} makes the lede bold"
refute_in '^SEG [0-9]+ 8 #[0-9a-f]+ b1 u0 s0 l-1 bg- .LEDE' "$PRE" \
    "lede is not bold without the external sheet"

# --- .warn color:#b00020 ---------------------------------------------
assert_in '^SEG [0-9]+ 8 #b00020 b1 u0 s0 l-1 bg- .WARNBLOCK' "$POST" \
    "linked .warn{color:#b00020} colours the warning paragraph red"
refute_in '#b00020' "$PRE" \
    "warning paragraph is not red without the external sheet"

echo "[hb-extcss] compiling native hambrowse (link-fetch path) ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/extcss_native.log"; then
    echo "[hb-extcss] FAIL: native hambrowse did not compile"; cat "$OUT/extcss_native.log"; exit 1
fi
echo "[hb-extcss] PASS native hambrowse still compiles"

if [ "$fail" = 0 ]; then
    echo "[hb-extcss] RESULT: PASS"; exit 0
else
    echo "[hb-extcss] RESULT: FAIL"; exit 1
fi
