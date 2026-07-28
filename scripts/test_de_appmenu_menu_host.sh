#!/usr/bin/env bash
# scripts/test_de_appmenu_menu_host.sh — FAST, QEMU-free host gate for the
# MATE-style Applications menu (category grouping + search + recent).
#
# Compiles lib/appmenucore.ad (the shared, extern-free menu MODEL, drawn
# through lib/hamscene.ad + rasterized by lib/hamui_host.ad) for the
# x86_64-linux host target, seeds a FIXTURE app set spanning several
# freedesktop categories, renders the FULL menu + a FILTERED ("ca") menu to
# PNGs a human/agent can LOOK at, and asserts:
#   * apps are GROUPED under category HEADERS (Accessories/Graphics/Internet/
#     Office/Games/System/Settings), each app under the right header;
#   * a SEARCH box renders at the top and its filter logic narrows the visible
#     apps live (search "ca" -> only Calculator + Camera);
#   * a RECENT section lists the most-recently-launched apps at the top.
# Then confirms the NATIVE menu client (user/hamappmenu.ad) still compiles
# from the SAME shared model — all in milliseconds, no QEMU.
#
# Pass marker: RESULT: PASS

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/appmenu_host"
mkdir -p "$OUT"
fail=0

echo "[appmenu-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/appmenuscene_host.ad "$BIN" 2>"$OUT/appmenu_compile.log"; then
    echo "[appmenu-host] FAIL: host harness did not compile"
    cat "$OUT/appmenu_compile.log"; exit 1
fi
echo "[appmenu-host] PASS host harness compiled -> $BIN"

DUMP="$OUT/appmenu_dump.txt"
if ! "$BIN" "$OUT/appmenu_full.ppm" "$OUT/appmenu_filtered.ppm" \
        "$OUT/appmenu_flyout.ppm" >"$DUMP" 2>&1; then
    echo "[appmenu-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in full filtered flyout; do
    if python3 scripts/ppm_to_png.py "$OUT/appmenu_$f.ppm" "$OUT/appmenu_$f.png" \
            2>"$OUT/appmenu_png.log"; then
        echo "[appmenu-host] PASS rendered $OUT/appmenu_$f.png ($(file -b "$OUT/appmenu_$f.png" 2>/dev/null))"
    else
        echo "[appmenu-host] FAIL png conversion ($f)"; cat "$OUT/appmenu_png.log"; fail=1
    fi
done

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[appmenu-host] PASS $msg"
    else
        echo "[appmenu-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- scene emitted + search box renders -----------------------------------
assert_grep '^# scene v1 hamui'                    "scene header emitted"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Search\.\.\.\"' "search box renders (placeholder) in FULL menu"
# REGRESSION GATE (user report 2026-07-17): the menu is a modal popup that owns
# the keyboard while open, so its search field is always focused — it must show
# a CARET the instant the menu opens, even with an EMPTY filter (before any
# keystroke). The FULL menu renders the empty search box, so the 1x12 caret bar
# (searchtx #23262b) MUST be emitted. Was: no caret until you typed.
assert_grep '^fill [0-9]+ [0-9]+ 1 12 #23262b'  "empty+focused menu search box renders a caret bar"

# --- FULL menu: Recent stays INLINE; categories are PARENT BUTTONS ----------
# The USER design correction: each category is now a hover fly-out BUTTON
# (like the panel's "Linux apps ▸"), NOT an inline header with its apps listed
# underneath. The EXCEPTION is Recent, which stays inline exactly as before.
assert_grep '^ROW FULL 0 SEARCH'                   "row 0 is the SEARCH box"
assert_grep '^ROW FULL 1 HEADER-RECENT Recent'     "Recent section header present (still INLINE)"
assert_grep '^ROW FULL 2 APP Calculator  \[Recent\]'   "Recent lists the last-launched Calculator INLINE"
assert_grep '^ROW FULL 3 APP Web Browser  \[Recent\]'  "Recent also lists the earlier-launched Web Browser INLINE"
# Categories: each is a single CATBTN PARENT row, in MATE order, with NO
# inline app rows following it.
assert_grep '^ROW FULL 4 CATBTN Accessories'       "Accessories is a parent BUTTON (not an inline header)"
assert_grep '^ROW FULL 5 CATBTN Graphics'          "Graphics is a parent BUTTON"
assert_grep '^ROW FULL 6 CATBTN Internet'          "Internet is a parent BUTTON"
assert_grep '^ROW FULL 7 CATBTN Office'            "Office is a parent BUTTON"
assert_grep '^ROW FULL 8 CATBTN Games'             "Games is a parent BUTTON"
assert_grep '^ROW FULL 9 CATBTN Sound & Video'     "Sound & Video (Multimedia) is a parent BUTTON"
assert_grep '^ROW FULL 10 CATBTN System'           "System is a parent BUTTON"
assert_grep '^ROW FULL 11 CATBTN Settings'         "Settings is a parent BUTTON"
# CRITICAL: no category app is listed INLINE in the FULL menu (they all live
# behind the hover fly-outs). Only Recent apps may appear as APP rows.
if grep -Eq '^ROW FULL [0-9]+ APP .*\[(Accessories|Graphics|Internet|Office|Games|Sound & Video|System|Settings|Other)\]' "$DUMP"; then
    echo "[appmenu-host] FAIL a category app leaked INLINE (should be behind a fly-out)"; fail=1
else
    echo "[appmenu-host] PASS category apps are behind fly-outs, not inline"
fi

# The MODEL summary: 4 non-category rows (search + recent hdr + 2 recent) + 8
# category buttons = 12 rows; 12 apps; 2 recent.
assert_grep '^MODEL FULL rows=12 apps=12 recent=2' "FULL model: 12 rows (8 category buttons), 12 apps, 2 recent"

# --- FILTERED menu: typing "ca" live-narrows to Calculator + Camera -------
assert_grep '^MODEL FILTERED rows=5 apps=12 recent=2' "FILTERED collapses to 5 rows"
assert_grep '^ROW FILTERED 0 SEARCH'               "filtered: search box still row 0"
assert_grep '^ROW FILTERED 1 HEADER Accessories'   "filtered: Accessories header kept (has a match)"
assert_grep '^ROW FILTERED 2 APP Calculator  \[Accessories\]' "filtered: Calculator matches 'ca'"
assert_grep '^ROW FILTERED 3 HEADER Graphics'      "filtered: Graphics header kept (has a match)"
assert_grep '^ROW FILTERED 4 APP Camera  \[Graphics\]' "filtered: Camera matches 'ca'"
# The non-matching sections must be GONE (no Recent, no Internet, etc.).
if grep -Eq '^ROW FILTERED [0-9]+ (HEADER Internet|HEADER Office|HEADER Games|HEADER-RECENT|APP Web Browser)' "$DUMP"; then
    echo "[appmenu-host] FAIL filter leaked non-matching sections"; fail=1
else
    echo "[appmenu-host] PASS filter dropped every non-matching section"
fi
assert_grep 'glyphs [0-9]+ [0-9]+ \"ca\"'          "filtered menu draws the live search text 'ca'"

# --- FLY-OUT: hovering the "Graphics" category opens its child submenu -----
# Mirrors the panel's "Linux apps ▸" hover fly-out: a CHILD box, aligned to
# the parent CATBTN row, listing that category's apps; a click in it launches.
assert_grep '^FLYOUT cat=1 apps=2 box='            "Graphics fly-out is open with 2 apps and a box geometry"
# The box top (y=116) aligns to the Graphics parent row (BY=16 + row5*20=100).
assert_grep '^FLYOUT cat=1 apps=2 box=227,116,200,40' "fly-out box aligned to the Graphics parent row, opened to the RIGHT"
assert_grep '^CHILD 0 APP Image Viewer'            "fly-out lists Image Viewer"
assert_grep '^CHILD 1 APP Camera'                  "fly-out lists Camera"
# Hit-test: a point in the fly-out's 2nd row maps to the right APP index (4 ==
# Camera) so a click launches it; a point outside the box misses.
assert_grep '^CHILDHIT row1 app=4 name=Camera'     "fly-out hit-test maps a point to the correct app index -> launch"
assert_grep '^CHILDHIT miss -1'                    "fly-out hit-test misses a point outside the box"

# --- SOUND & VIDEO fly-out: AudioVideo apps classify to the NEW Multimedia
# bucket (NOT Graphics), so the shipped Video Player + Audio Player are
# discoverable under "Sound & Video" — the media-discoverability regression. --
assert_grep '^MMFLYOUT cat=5 apps=2'               "Sound & Video (Multimedia==5) fly-out lists 2 apps"
assert_grep '^MMCHILD 0 APP Video Player'          "Sound & Video lists the Video Player (AudioVideo -> Multimedia, not Graphics)"
assert_grep '^MMCHILD 1 APP Audio Player'          "Sound & Video lists the Audio Player"
# And the AudioVideo apps did NOT leak into the Graphics fly-out (still 2 apps).
if grep -Eq '^(CHILD|MMCHILD) [0-9]+ APP (Video|Audio) Player' "$DUMP" && \
   grep -q '^FLYOUT cat=1 apps=2 ' "$DUMP"; then
    echo "[appmenu-host] PASS media apps live under Sound & Video, Graphics fly-out unchanged"
else
    echo "[appmenu-host] FAIL media-app classification regressed"; fail=1
fi

# --- hit-test + row-kind sanity -------------------------------------------
assert_grep '^HIT search 0'                        "hit-test: pointer on the search box -> row 0"
assert_grep '^HIT miss -1'                         "hit-test: pointer left of the box misses"
assert_grep '^KIND row2 2'                         "row 2 is an APP row (launchable)"

# --- live typing: the on-device keystroke edit path (push/backspace) --------
# Typing "C","a","z" then Backspace leaves the filter "ca" and narrows the
# layout to the 5 rows the FILTERED render proves — verifies a typed key both
# updates the filter buffer and re-narrows the visible set.
assert_grep '^TYPE filter=\"ca\" len=2 rows=5'     "typed keystrokes edit the filter buffer + narrow the layout"

# --- FRAME-1 DISMISS GUARD (#287/#313/#330 one-frame-flash regression) -------
# The menu is a detached child spawned on the panel button's PRESS edge with the
# mouse still held; it must NOT self-dismiss on frame 1, but a genuine click-away
# or focus-out (after it has settled) must STILL dismiss. These drive the exact
# pure helpers the /event drain uses (amc_focus_out_dismiss / amc_press_edge).
assert_grep '^DISMISS focus_out_before_in 0'   "spurious 'f out' before any 'f in' does NOT dismiss (no frame-1 flash)"
assert_grep '^DISMISS focus_out_after_in 1'    "genuine 'f out' after the menu was focused STILL dismisses"
assert_grep '^DISMISS focus_in 0'              "'f in' itself never dismisses (#313)"
assert_grep '^DISMISS press_first_held 0'      "held opening click on the FIRST 'm' event is no press-outside edge"
assert_grep '^DISMISS press_still_held 0'      "button still held on the next sample is no new press edge"
assert_grep '^DISMISS press_after_release 1'   "a real NEW press after a release STILL edges (click-away dismiss preserved)"

# --- NATIVE menu client still compiles from the shared model --------------
echo "[appmenu-host] compiling NATIVE hamappmenu for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamappmenu.ad "$OUT/hamappmenu_native.elf" 2>"$OUT/appmenu_native.log"; then
    echo "[appmenu-host] FAIL: native hamappmenu did not compile"
    tail -40 "$OUT/appmenu_native.log"; fail=1
else
    echo "[appmenu-host] PASS native hamappmenu still compiles"
fi

if [ "$fail" -eq 0 ]; then
    echo "[appmenu-host] RESULT: PASS"
    exit 0
else
    echo "[appmenu-host] RESULT: FAIL"
    exit 1
fi
