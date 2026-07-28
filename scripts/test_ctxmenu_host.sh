#!/usr/bin/env bash
# scripts/test_ctxmenu_host.sh — FAST, QEMU-free host gate for the MATE
# context menus (Task #124). Compiles lib/ctxmenucore.ad (the shared menu
# model, drawn through lib/hamscene.ad + rasterized by lib/hamui_host.ad) for
# the x86_64-linux host target, renders the PANEL / APPLET / CHOOSER menus to
# PNGs a human/agent can LOOK at, asserts the MATE labels + hit-testing, AND
# confirms the touched NATIVE compositor (user/hamUId.ad) still compiles from
# the same model — all in milliseconds, no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/ctxmenu_host"
mkdir -p "$OUT"
fail=0

echo "[ctxmenu-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/ctxmenuscene_host.ad "$BIN" 2>"$OUT/ctxmenu_compile.log"; then
    echo "[ctxmenu-host] FAIL: host harness did not compile"; cat "$OUT/ctxmenu_compile.log"; exit 1
fi
echo "[ctxmenu-host] PASS host harness compiled -> $BIN"

echo "[ctxmenu-host] running host harness ..."
DUMP="$OUT/ctxmenu_dump.txt"
if ! "$BIN" "$OUT/ctxmenu_panel.ppm" "$OUT/ctxmenu_applet.ppm" \
        "$OUT/ctxmenu_chooser.ppm" "$OUT/ctxmenu_choice_full.ppm" \
        "$OUT/ctxmenu_choice_filtered.ppm" >"$DUMP" 2>&1; then
    echo "[ctxmenu-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in panel applet chooser choice_full choice_filtered; do
    if python3 scripts/ppm_to_png.py "$OUT/ctxmenu_$f.ppm" "$OUT/ctxmenu_$f.png" 2>"$OUT/ctxmenu_png.log"; then
        echo "[ctxmenu-host] PASS rendered $OUT/ctxmenu_$f.png ($(file -b "$OUT/ctxmenu_$f.png" 2>/dev/null))"
    else
        echo "[ctxmenu-host] FAIL png conversion ($f)"; cat "$OUT/ctxmenu_png.log"; fail=1
    fi
done

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[ctxmenu-host] PASS $msg"
    else
        echo "[ctxmenu-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- PANEL menu: the MATE labels appear in the display list ---------------
assert_grep '^# scene v1 hamui'                       "scene header emitted"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Add to Panel\.\.\.\"' "panel: Add to Panel..."
assert_grep 'glyphs [0-9]+ [0-9]+ \"Properties\"'     "panel: Properties"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Reset All Panels\"' "panel: Reset All Panels"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Delete This Panel\"' "panel: Delete This Panel"
assert_grep 'glyphs [0-9]+ [0-9]+ \"New Panel\"'      "panel: New Panel"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Help\"'           "panel: Help"
assert_grep 'glyphs [0-9]+ [0-9]+ \"About Panels\"'   "panel: About Panels"

# --- APPLET menu: per-applet Preferences + Move/Remove/Lock --------------
assert_grep 'glyphs [0-9]+ [0-9]+ \"Preferences\"'    "applet: Preferences"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Move\"'           "applet: Move"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Remove From Panel\"' "applet: Remove From Panel"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Lock To Panel\"'  "applet: Lock To Panel"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Clock\"'          "applet: caption names the Clock applet (decentralized prefs)"

# --- CHOOSER: applet picker lists applets --------------------------------
assert_grep 'glyphs [0-9]+ [0-9]+ \"Application Launcher\"' "chooser: Application Launcher"
assert_grep 'glyphs [0-9]+ [0-9]+ \"System Monitor\"' "chooser: System Monitor"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Workspace Switcher\"' "chooser: Workspace Switcher"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Window List\"'    "chooser: Window List"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Add to Panel\"'   "chooser: title caption"

# --- geometry + hit-testing ----------------------------------------------
assert_grep '^MENU PANEL prims=[0-9]+ count=7 '       "panel menu has 7 rows"
assert_grep '^MENU APPLET prims=[0-9]+ count=4 '      "applet menu has 4 rows"
assert_grep '^MENU CHOOSER prims=[0-9]+ count=8 '     "chooser has 8 applet rows"
assert_grep '^HIT panel 50 70 0'                      "hit-test: row 0 under the pointer"
assert_grep '^HIT panel 50 130 3'                     "hit-test: Delete-This-Panel row 3"
assert_grep '^HIT panel 50 10 -1'                     "hit-test: point above the box misses"
assert_grep '^HIT applet 50 130 3'                    "hit-test: applet Lock row 3"
assert_grep '^PIX 44 70 #3584e4'                      "raster: hovered row painted modern accent blue"

# --- SEARCHABLE Add-to-Panel CHOOSER (v2 DIALOG) -------------------------
# The MATE add-applet dialog the panel's "Add to Panel..." opens: a title, a
# search box, category headers, and per-applet name + description rows.
assert_grep 'glyphs [0-9]+ [0-9]+ \"Search applets\.\.\.\"' "choice: search box placeholder renders"
# CARET-ON-FOCUS (user-reported): the add-to-panel applet-search field showed
# NO cursor until you typed. The modal chooser always holds the keyboard, so it
# must draw a 1px caret at the insertion point even when EMPTY. The FULL render
# has an empty filter, so its caret sits at the field start (x=56, the glyph
# origin) — a distinctive 1x13 fill in the text colour.
assert_grep 'fill 56 51 1 13 #23262b'                "choice: empty search field shows a caret on focus"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Menus & Launchers\"'    "choice: category header (Menus & Launchers)"
assert_grep 'glyphs [0-9]+ [0-9]+ \"System & Hardware\"'    "choice: category header (System & Hardware)"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Windows & Workspaces\"' "choice: category header (Windows & Workspaces)"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Menu Bar\"'             "choice: applet name (Menu Bar)"
assert_grep 'glyphs [0-9]+ [0-9]+ \"CPU and memory usage meters\"' "choice: applet DESCRIPTION renders"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Spacer\"'               "choice: Spacer applet (panel-specific, beyond stock chooser)"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Session\"'              "choice: Session applet (panel-specific)"
# Model structure: search row 0, category grouping, entries carry a category.
assert_grep '^CROW FULL 0 SEARCH'                    "choice model: row 0 is the search box"
assert_grep '^CROW FULL 1 HEADER Menus & Launchers'  "choice model: first header groups the launcher"
assert_grep '^CROW FULL 2 ENTRY Menu Bar'            "choice model: Menu Bar grouped under it"
# Live filter narrows the list: "work" -> only the Workspace Switcher.
assert_grep '^CHOICE FILTERED prims=[0-9]+ rows=3 ' "choice: filter 'work' narrows to a single applet section"
assert_grep '^CROW FILTERED 2 ENTRY Workspace Switcher' "choice: filtered result is the Workspace Switcher"
# Hit-testing on the dialog.
assert_grep '^CHIT search 0'                         "choice hit-test: search row under the pointer"
assert_grep '^CHIT miss -1'                          "choice hit-test: point left of the box misses"
assert_grep '^CKIND row2 2'                          "choice hit-test: row 2 is an ENTRY"
assert_grep '^CAPPLET row2 1'                        "choice hit-test: row 2 inserts the Menu Bar applet"

# --- live typing: the on-device keystroke edit path (push/backspace) --------
assert_grep '^CTYPE filter=\"work\" len=4 rows=3'    "typed keystrokes edit the chooser filter + narrow the layout"

# --- NATIVE panel consumes the searchable chooser (compiles) -------------
echo "[ctxmenu-host] compiling NATIVE hampanelscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hampanelscene.ad "$OUT/hampanelscene_native.elf" 2>"$OUT/ctxmenu_panel_native.log"; then
    echo "[ctxmenu-host] FAIL: native hampanelscene did not compile"; tail -40 "$OUT/ctxmenu_panel_native.log"; fail=1
else
    echo "[ctxmenu-host] PASS native hampanelscene still compiles (wired to the chooser)"
fi

# --- NATIVE compositor still compiles from the shared model --------------
echo "[ctxmenu-host] compiling NATIVE hamUId for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamUId.ad "$OUT/hamUId_native.elf" 2>"$OUT/ctxmenu_native.log"; then
    echo "[ctxmenu-host] FAIL: native hamUId did not compile"; tail -40 "$OUT/ctxmenu_native.log"; fail=1
else
    echo "[ctxmenu-host] PASS native hamUId still compiles"
fi

if [ "$fail" -eq 0 ]; then
    echo "[ctxmenu-host] RESULT: PASS"
    exit 0
else
    echo "[ctxmenu-host] RESULT: FAIL"
    exit 1
fi
