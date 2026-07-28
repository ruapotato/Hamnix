#!/usr/bin/env bash
# scripts/test_hambrowse_tabs_host.sh — FAST, QEMU-free gate for the browser's
# MULTI-TAB session: the "+" new-tab button, tab switching, and tab closing.
#
# USER-REPORTED BUG this pins: "the + button for a new tab does not work." The
# Chrome-style shell (lib/browserwin.ad) had always DRAWN a tab strip with a "+"
# and had a hit test, but nothing sat behind it — user/hambrowse.ad pinned
# `browserwin_set_tabs(1, 0)` on every frame, so "+" was decoration and clicking
# a tab did nothing. user/hambrowse_tabs.ad is the session model that makes it
# real; this gate drives it end to end.
#
# Three layers, all host-side (both modules under test are PURE):
#   1. SESSION   — user/hambrowse_tabs_host.ad opens / switches / closes tabs and
#                  proves each tab keeps its OWN url, scroll offset and
#                  Back/Forward history (the whole point of a tab).
#   2. HIT TEST  — the same clicks routed through lib/browserwin.ad's
#                  browserwin_tab_hit, so the pixel the user presses maps to the
#                  session action (+ = -2, tab i = i, tab i's x box = -10-i).
#   3. PIXELS    — user/hambrowse_gfx_window.ad composites the real window with
#                  the LIVE session driving the strip, and a "+" CLICK is driven
#                  through the hit test; the PNG must then show 3 tabs with the
#                  new one active (white) — a screendump of >= 2 tabs.
#
# Also confirms the native browser (x86_64-adder-user) still compiles with the
# tab wiring, so a regression there fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
OUT="build/host"; mkdir -p "$OUT"
fail=0

# ---- 1+2. session model + strip hit test ----------------------------
UBIN="$OUT/hambrowse_tabs_host"
echo "[hb-tabs] compiling tab-session unit harness (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_tabs_host.ad "$UBIN" 2>"$OUT/tabs_unit.log"; then
    echo "[hb-tabs] FAIL: unit harness did not compile"; cat "$OUT/tabs_unit.log"; exit 1
fi
U="$OUT/tabs_unit.txt"
"$UBIN" >"$U" 2>&1 || { echo "[hb-tabs] FAIL: unit harness exited non-zero"; cat "$U"; exit 1; }
cat "$U"

assert_u() {  # exact-line message
    if grep -qx -- "$1" "$U"; then echo "[hb-tabs] PASS $2"
    else echo "[hb-tabs] FAIL $2 (missing: $1)"; fail=1; fi
}

# start state
assert_u 'T_N0 1'            "a fresh session has exactly one tab"
assert_u 'T_ACT0 0'          "that tab is active"

# THE BUG: the "+" button.
assert_u 'T_PLUS_HIT -2'     "clicking the + button hit-tests as new-tab (-2)"
assert_u 'T_OPEN_IDX 1'      "+ opens tab index 1"
assert_u 'T_N1 2'            "+ grew the strip to 2 tabs"
assert_u 'T_ACT1 1'          "+ switches to the tab it just opened"
assert_u 'T_NEWURL_LEN 0'    "a new tab starts with no url (shows about:newtab)"
assert_u 'T_NEWHIST 0'       "a new tab starts with an EMPTY Back/Forward history"

# switching
assert_u 'T_HIT_T0 0'        "a click on tab 0 hit-tests as tab 0"
assert_u 'T_HIT_T1 1'        "a click on tab 1 hit-tests as tab 1"
assert_u 'T_SEL0 1'          "selecting tab 0 reports a live-page change"
assert_u 'T_ACT2 0'          "tab 0 is now active"
assert_u 'T_URL0 https://example.com/one'    "tab 0 kept its OWN url"
assert_u 'T_SCROLL0 0'       "tab 0 kept its own scroll offset"
assert_u 'T_HIST0 1'         "tab 0 restored its own 1-entry history"
assert_u 'T_CANBACK0 0'      "tab 0 has nothing to go Back to"
assert_u 'T_SEL1 1'          "switching back to tab 1 reports a change"
assert_u 'T_URL1 https://example.com/two-b'  "tab 1 kept its OWN url"
assert_u 'T_SCROLL1 640'     "tab 1 kept its own 640px scroll offset"
assert_u 'T_HIST1 2'         "tab 1 restored its own 2-entry history"
assert_u 'T_CANBACK1 1'      "tab 1 CAN go Back (its history, not tab 0's)"
assert_u 'T_BACK1 https://example.com/two'   "Back in tab 1 walks tab 1's stack"

# the strip reflects the live set
assert_u 'T_STRIP_N 2'       "the painted strip shows the live tab count"
assert_u 'T_STRIP_ACT 1'     "the painted strip marks the live active tab"

# closing
assert_u 'T_N3 3'            "a third tab opens"
assert_u 'T_ACT3 2'          "the third tab is active"
assert_u 'T_CLOSEHIT_1 1'    "the x box of tab 1 hit-tests to tab 1"
assert_u 'T_HIT_X1 -11'      "a click on tab 1's x reports close-tab-1 (-10-i)"
assert_u 'T_CLOSE1_RELOAD 0' "closing a NON-active tab does not reload the page"
assert_u 'T_N4 2'            "closing tab 1 shrank the strip to 2"
assert_u 'T_ACT4 1'          "the active tab followed its slot down"
assert_u 'T_URL_AFTER https://example.com/three' "the surviving tab kept its url"
assert_u 'T_URL0_AFTER https://example.com/one'  "the tab before it is untouched"
assert_u 'T_CLOSE_ACT 1'     "closing the ACTIVE tab reports a page reload"
assert_u 'T_N5 1'            "and shrinks the strip to 1"
assert_u 'T_ACT5 0'          "focus falls to the remaining tab"
assert_u 'T_URL_LAST https://example.com/one'  "which still shows its own page"
assert_u 'T_CLOSE_LAST 0'    "the LAST tab never closes"
assert_u 'T_N6 1'            "so the strip stays at 1 tab"

# capacity + dead space
assert_u 'T_CAP 8'           "the strip caps at TAB_MAX (8) tabs"
assert_u 'T_CAP_OPEN -1'     "+ past the cap reports failure instead of corrupting"
assert_u 'T_HIT_MISS -1'     "dead space right of the + is not a tab"
assert_u 'T_HIT_BELOW -1'    "a click below the strip is not a tab"
assert_u 'DONE'              "unit harness ran to completion"

# ---- 3. PIXELS: composite the real window with a driven "+" click ---
WBIN="$OUT/hambrowse_gfx_window"
echo "[hb-tabs] compiling window compositor (x86_64-linux) ..."
if ! adder_bin x86_64-linux user/hambrowse_gfx_window.ad "$WBIN" 2>"$OUT/tabs_win.log"; then
    echo "[hb-tabs] FAIL: window compositor did not compile"; cat "$OUT/tabs_win.log"; exit 1
fi
FIX="tests/fixtures/hambrowse_article.html"

# The strip's baseline: the session opens 2 tabs with tab 0 active.
W="$OUT/tabs_win.txt"
"$WBIN" "$FIX" "$OUT/tabs_2.ppm" 1000 700 1 1 >"$W" 2>&1
python3 scripts/ppm_to_png.py "$OUT/tabs_2.ppm" "$OUT/tabs_2.png" 2>/dev/null
assert_w() { # file pattern message
    if grep -qx -- "$2" "$1"; then echo "[hb-tabs] PASS $3"
    else echo "[hb-tabs] FAIL $3 (missing: $2 in $1)"; cat "$1"; fail=1; fi
}
assert_w "$W" 'TABS 2'      "the composited window paints the live 2-tab strip"
assert_w "$W" 'TABACTIVE 0' "with tab 0 active"

# Now drive a real "+" CLICK through browserwin_tab_hit -> tabs_open().
W3="$OUT/tabs_win_plus.txt"
"$WBIN" "$FIX" "$OUT/tabs_3.ppm" 1000 700 1 1 0 0 plus >"$W3" 2>&1
python3 scripts/ppm_to_png.py "$OUT/tabs_3.ppm" "$OUT/tabs_3.png" 2>/dev/null
assert_w "$W3" 'PLUSHIT -2'  "the + pixel hit-tests as new-tab in the real window"
assert_w "$W3" 'TABS 3'      "clicking + added a THIRD tab to the painted strip"
assert_w "$W3" 'TABACTIVE 2' "and made the new tab the active one"

# And a real close click on tab 1's x box.
WC="$OUT/tabs_win_close.txt"
"$WBIN" "$FIX" "$OUT/tabs_close.ppm" 1000 700 1 1 0 0 plus closetab1 >"$WC" 2>&1
python3 scripts/ppm_to_png.py "$OUT/tabs_close.ppm" "$OUT/tabs_close.png" 2>/dev/null
assert_w "$WC" 'CLOSEHIT -11' "the x pixel of tab 1 hit-tests as close-tab-1"
assert_w "$WC" 'TABS 2'       "closing it shrank the painted strip back to 2"

# PIXEL proof: in the 3-tab render the ACTIVE tab (index 2) is lifted to WHITE
# while an inactive tab is the grey (222,225,230) strip colour. That is the
# visible difference a user sees after clicking "+".
px() {  # ppm x y -> "R G B"
    python3 - "$1" "$2" "$3" <<'PY'
import sys
f,x,y=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
p=open(f,'rb'); assert p.readline().strip()==b'P6'
w,h=map(int,p.readline().split()); p.readline(); d=p.read(); o=(y*w+x)*3
print(d[o],d[o+1],d[o+2])
PY
}
# tab width for 3 tabs in a 1000px window: (1000-8-34)/3 = 319 -> capped at 200.
# tab 2 spans x=[408,606); tab 0 spans x=[8,206).
A2="$(px "$OUT/tabs_3.ppm" 500 30)"
I0="$(px "$OUT/tabs_3.ppm" 100 30)"
if [ "$A2" = "255 255 255" ]; then
    echo "[hb-tabs] PASS the new (active) tab paints WHITE, lifted out of the strip"
else echo "[hb-tabs] FAIL new tab not white (got: $A2)"; fail=1; fi
if [ "$I0" = "222 225 230" ]; then
    echo "[hb-tabs] PASS the inactive tab beside it stays grey"
else echo "[hb-tabs] FAIL inactive tab not grey (got: $I0)"; fail=1; fi

# ---- native browser must still build with the tab wiring ------------
echo "[hb-tabs] confirming native hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/tabs_native.log"; then
    echo "[hb-tabs] FAIL: native hambrowse did not compile"; cat "$OUT/tabs_native.log"; fail=1
else
    echo "[hb-tabs] PASS native hambrowse still compiles"
fi

if [ "$fail" -ne 0 ]; then echo "[hb-tabs] RESULT: FAIL"; exit 1; fi
echo "[hb-tabs] RESULT: PASS"
echo "[hb-tabs] screendumps: $OUT/tabs_2.png (2 tabs) $OUT/tabs_3.png (3 tabs, + clicked) $OUT/tabs_close.png"
exit 0
