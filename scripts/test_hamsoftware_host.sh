#!/usr/bin/env bash
# scripts/test_hamsoftware_host.sh — FAST, QEMU-free host gate for the "Software"
# app (the Synaptic-style GUI front-end over the native hpm package manager).
# The UI is lib/hampkgcore.ad drawn through lib/hamscene.ad and rasterized by
# lib/hamui_host.ad; this harness (user/hamsoftware_host.ad) feeds the pure core
# a FIXTURE package index (the exact text lines `hpm search` / `hpm list` /
# `hpm show` emit), turns the category sidebar ON, renders three PNGs a human/
# agent can LOOK at — the full list, the "Installed" category filter, and a
# selected package's detail pane — and asserts the sidebar / list / search /
# detail behaviour off the emitted scene grammar + rastered pixels. It also
# confirms the NATIVE Hamnix app (user/hamsoftware.ad) still compiles from the
# same core. hpm stays the engine; this only exercises the GUI front-end.
#
# NOTE (memory feedback_host_preview_monospace_lies): the host preview renders
# monospace and misrepresents proportional text X-positions, so we assert
# STRUCTURE / presence (which panes + labels emitted, category counts,
# hit-test results) — NOT exact caret/label pixel-X. Precise text layout is
# verified on-device / via the core's parser logic, not this PNG.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsoftware_host"
mkdir -p "$OUT"
fail=0

echo "[hamsoftware-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsoftware_host.ad "$BIN" 2>"$OUT/hamsoftware_compile.log"; then
    echo "[hamsoftware-host] FAIL: host harness did not compile"; cat "$OUT/hamsoftware_compile.log"; exit 1
fi
echo "[hamsoftware-host] PASS host harness compiled -> $BIN"

echo "[hamsoftware-host] compiling NATIVE hamsoftware for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamsoftware.ad "$OUT/hamsoftware_native.elf" 2>"$OUT/hamsoftware_native.log"; then
    echo "[hamsoftware-host] FAIL: native hamsoftware did not compile"; cat "$OUT/hamsoftware_native.log"; exit 1
fi
echo "[hamsoftware-host] PASS native hamsoftware still compiles"

DUMP="$OUT/hamsoftware_dump.txt"
if ! "$BIN" "$OUT/sw_list.ppm" "$OUT/sw_cat.ppm" "$OUT/sw_detail.ppm" \
        >"$DUMP" 2>&1; then
    echo "[hamsoftware-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in list cat detail; do
    if python3 scripts/ppm_to_png.py "$OUT/sw_$f.ppm" "$OUT/sw_$f.png" 2>"$OUT/sw_png.log"; then
        echo "[hamsoftware-host] PASS rendered $OUT/sw_$f.png"
    else
        echo "[hamsoftware-host] FAIL png conversion ($f)"; cat "$OUT/sw_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamsoftware-host] PASS $2";
    else echo "[hamsoftware-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# --- chrome / window / non-blank frame --------------------------------------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 772 430 #eceef2'         "widened (sidebar) window background"
# MAXIMIZE / RESIZE (user-reported: the Software window did not fill the screen
# when maximized, leaving gaps). A compositor resize event (hampkg_set_size)
# must STRETCH the scene: the background, detail pane and status bar fill the
# whole 1024x700 maximized content rect.
assert_grep '^fill 0 0 1024 700 #eceef2'        "maximized: background fills the whole window"
assert_grep '^fill 0 678 1024 22 #dfe2e8'       "maximized: status bar hugs the new bottom edge"
assert_grep '^fill 498 106 526 572 #ffffff'     "maximized: detail pane stretches to the right edge"
assert_grep '^fill 0 0 772 30 #2f5c8f'          "blue header bar spans full width"
assert_grep 'glyphs .*\"Software\"'             "app title label is Software"
# a non-trivial primitive count proves the frame is not blank
assert_grep '^PRIMS [1-9][0-9]+'                "non-blank frame (many primitives)"
assert_grep '^PIX 4 4 3103887'                  "raster header pixel = #2f5c8f (not blank)"

# --- search field + action buttons ------------------------------------------
assert_grep 'glyphs .*\"Find\"'                 "search field label"
# REGRESSION GATE (user report 2026-07-17): the search box must show a blinking
# CARET the instant it is focused, even while EMPTY (before any keystroke). The
# default scene renders the search box empty + focused, so the 1x14 caret bar in
# the caret colour (#2f5c8f) MUST be emitted. Was: empty -> placeholder only, no
# caret, so a freshly-opened box looked unfocused until you typed.
assert_grep 'glyphs .*\"search packages\.\.\.\"' "empty search box keeps its placeholder"
assert_grep '^fill [0-9]+ [0-9]+ 1 14 #2f5c8f'  "empty+focused search box renders a caret bar"
assert_grep 'glyphs .*\"Refresh\"'              "Refresh button"
assert_grep 'glyphs .*\"Install\"'              "Install button"
assert_grep 'glyphs .*\"Remove\"'               "Remove button"
assert_grep 'glyphs .*\"Upgrade\"'              "Upgrade button"

# --- the category sidebar (the new Synaptic left rail) ----------------------
assert_grep 'glyphs .*\"All\"'                  "sidebar: All category"
assert_grep 'glyphs .*\"Installed\"'            "sidebar: Installed category"
assert_grep 'glyphs .*\"Available\"'            "sidebar: Available category"
assert_grep 'glyphs .*\"Upgradable\"'           "sidebar: Upgradable category"

# --- package index parsed from real-shape `hpm search` output ---------------
assert_grep '^COUNT 6'                          "6 packages parsed from search output"
assert_grep '^FILT_ALL 6'                       "category All -> all 6 shown"
# The redundant "hamnix-" vendor prefix is stripped for DISPLAY (the stored
# package id keeps it for install/list matching), so the row renders "base".
assert_grep 'glyphs .*\"base\" #'               "package hamnix-base listed as 'base' (prefix stripped)"
assert_grep 'glyphs .*\"hambrowse\"'            "package hambrowse listed"
assert_grep 'glyphs .*\"webkitgtk\"'            "package webkitgtk listed"
assert_grep 'glyphs .*\"native web browser\"'   "short description rendered"

# --- category counts computed from `hpm list` state -------------------------
assert_grep '^CAT_ALL 6'                        "category counter: All = 6"
assert_grep '^CAT_INST 3'                       "category counter: Installed = 3"
assert_grep '^CAT_AVAIL 3'                      "category counter: Available = 3"
assert_grep '^CAT_UPGRAD 1'                     "category counter: Upgradable = 1 (hambrowse 0.8->0.9)"
assert_grep 'glyphs .*\"upgrade\"'              "upgradable badge rendered on the row"
assert_grep 'glyphs .*\"installed\"'            "installed badge rendered"
assert_grep 'glyphs .*\"available\"'            "available badge rendered"

# --- clicking a sidebar category filters the list ---------------------------
assert_grep '^CAT_HIT 6'                         "sidebar click hit-tests to a category (code 6)"
assert_grep '^CAT_SEL 1'                         "selected category = Installed"
assert_grep '^FILT_INST 3'                       "Installed category narrows list to 3"

# --- clicking a list row (offset past the sidebar) selects + fills detail ---
assert_grep '^HIT 5'                            "row click hit-tests to select"
assert_grep '^SEL 2'                            "selected package index 2 (hambrowse)"
assert_grep '^SEL_NAME hambrowse'               "selected package name is hambrowse"
assert_grep 'glyphs .*\"Version:\"'             "detail: version label"
assert_grep 'glyphs .*\"0.9\"'                  "detail: parsed version value"
assert_grep 'glyphs .*\"Depends:\"'             "detail: depends label"
assert_grep 'glyphs .*\"webkitgtk, hamnix-base\"' "detail: parsed dependency list"
assert_grep 'glyphs .*\"#hamnix-system\"'       "detail: parsed target"

# --- installed-app registry enumeration (the on-device fix) -----------------
# The native driver enumerates /etc/hamde/apps/*.desktop into the core via
# hampkg_add_pkg so the window lists EVERY installed app offline (no `hpm
# refresh`). This scenario drives that exact core API with a registry-shaped
# fixture (7 apps incl. multi-word names), proving >1 distinct app enumerates
# and multi-word Names survive (the search-line tokeniser would truncate them).
assert_grep '^REG_COUNT 7'                      "registry scan enumerates 7 installed apps (>1)"
assert_grep '^REG_INST 7'                       "all registry apps marked installed"
assert_grep '^REG_SEL_NAME Coin Dash$'          "multi-word app name kept intact (not 'Coin')"

# --- native driver is DATA-DRIVEN from the registry -------------------------
# Guard the load-bearing links the fix relies on so a refactor can't silently
# revert the app to the network-only (empty-offline) index path.
SRC="user/hamsoftware.ad"
for need in 'from lib.desktopentry import' 'p9_listdir' 'desktop_parse' \
            'hampkg_add_pkg' '/etc/hamde/apps'; do
    if grep -qF -- "$need" "$SRC"; then
        echo "[hamsoftware-host] PASS native driver uses '$need'"
    else
        echo "[hamsoftware-host] FAIL native driver missing '$need'"; fail=1
    fi
done

# --- the registry itself has the full per-app set (each app its own entry) --
APPS_DIR="etc/hamde/apps"
n_apps=$(find "$APPS_DIR" -maxdepth 1 -name '*.desktop' 2>/dev/null | wc -l)
if [ "$n_apps" -gt 1 ]; then
    echo "[hamsoftware-host] PASS registry has $n_apps app entries (>1)"
else
    echo "[hamsoftware-host] FAIL registry has only $n_apps app entries"; fail=1
fi
for app in hamsnake hamtetris coindash hamchess terminal editor control-center; do
    if [ -f "$APPS_DIR/$app.desktop" ]; then
        echo "[hamsoftware-host] PASS registry entry $app.desktop present"
    else
        echo "[hamsoftware-host] FAIL registry entry $app.desktop missing"; fail=1
    fi
done

if [ "$fail" -ne 0 ]; then echo "[hamsoftware-host] OVERALL FAIL"; exit 1; fi
echo "[hamsoftware-host] OVERALL PASS"
