#!/usr/bin/env bash
# scripts/test_hampkg_host.sh — FAST, QEMU-free host gate for the Package
# Manager GUI (lib/hampkgcore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). It feeds the pure core a FIXTURE package index (the exact
# text lines `hpm search` / `hpm list` / `hpm show` emit), renders three PNGs a
# human/agent can LOOK at — the full list, a live "web" search filter, and a
# selected package's detail pane — asserts the list/search/detail behaviour off
# the emitted scene grammar + rastered pixels, AND confirms the NATIVE Hamnix
# app still compiles from the same core. hpm stays the engine; this only
# exercises the GUI front-end's parsing + rendering + hit-testing.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hampkg_host"
mkdir -p "$OUT"
fail=0

echo "[hampkg-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hampkgscene_host.ad -o "$BIN" 2>"$OUT/hampkg_compile.log"; then
    echo "[hampkg-host] FAIL: host harness did not compile"; cat "$OUT/hampkg_compile.log"; exit 1
fi
echo "[hampkg-host] PASS host harness compiled -> $BIN"

echo "[hampkg-host] compiling NATIVE hampkgscene for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hampkgscene.ad -o "$OUT/hampkg_native.elf" 2>"$OUT/hampkg_native.log"; then
    echo "[hampkg-host] FAIL: native hampkgscene did not compile"; cat "$OUT/hampkg_native.log"; exit 1
fi
echo "[hampkg-host] PASS native hampkgscene still compiles"

DUMP="$OUT/hampkg_dump.txt"
if ! "$BIN" "$OUT/pkg_list.ppm" "$OUT/pkg_search.ppm" "$OUT/pkg_detail.ppm" \
        >"$DUMP" 2>&1; then
    echo "[hampkg-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in list search detail; do
    if python3 scripts/ppm_to_png.py "$OUT/pkg_$f.ppm" "$OUT/pkg_$f.png" 2>"$OUT/pkg_png.log"; then
        echo "[hampkg-host] PASS rendered $OUT/pkg_$f.png"
    else
        echo "[hampkg-host] FAIL png conversion ($f)"; cat "$OUT/pkg_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hampkg-host] PASS $2";
    else echo "[hampkg-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# --- chrome / buttons / search field ----------------------------------------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 640 430 #eceef2'         "window background"
assert_grep '^fill 0 0 640 30 #2f5c8f'          "blue header bar"
assert_grep 'glyphs .*\"Package Manager\"'      "app title label"
assert_grep 'glyphs .*\"Find\"'                 "search field label"
assert_grep 'glyphs .*\"Refresh\"'              "Refresh button"
assert_grep 'glyphs .*\"Install\"'              "Install button"
assert_grep 'glyphs .*\"Remove\"'               "Remove button"
assert_grep 'glyphs .*\"Upgrade\"'              "Upgrade button"
assert_grep 'glyphs .*\"6 packages in the index\"' "status line"

# --- the package index parsed from `hpm search` -----------------------------
assert_grep '^COUNT 6'                          "6 packages parsed from search output"
assert_grep '^FILT_ALL 6'                       "no filter -> all 6 shown"
# hamnix-base is rendered under its DISPLAY name: lib/hampkgcore::_disp_name
# deliberately strips the redundant "hamnix-" vendor prefix in the UI (e3577e8b)
# while the STORED id keeps the full package name (install/remove key on it).
# Pin BOTH halves of that contract — the stripped label in the scene AND the
# intact id in the model — so neither can silently rot.
assert_grep 'glyphs .*\"base\"'                 "package hamnix-base listed (display name, hamnix- stripped)"
assert_grep '^PKGID 0 hamnix-base$'             "stored package id keeps the full \"hamnix-base\" name"
assert_grep '^PKGID 3 hamnix-hamnotes$'         "stored package id keeps the full \"hamnix-hamnotes\" name"
assert_grep 'glyphs .*\"hambrowse\"'            "package hambrowse listed"
assert_grep 'glyphs .*\"webkitgtk\"'            "package webkitgtk listed"
assert_grep 'glyphs .*\"native web browser\"'   "short description rendered"

# --- installed/available state badges (parsed from `hpm list`) --------------
assert_grep 'glyphs .*\"installed\"'            "installed badge rendered"
assert_grep 'glyphs .*\"available\"'            "available badge rendered"

# --- live search filter narrows the list ------------------------------------
assert_grep '^FILT_WEB 2'                       "search \"web\" narrows to 2 packages"

# --- Synaptic-style status HUD: model-derived live counts -------------------
# full view: 6 listed, 2 installed (hamnix-base + hamnix-hamnotes), 0 upgradable
assert_grep '^HUD 6 listed   /   2 installed   /   0 upgradable' "status HUD live counts (full view)"
# the HUD tracks the live search filter: "web" -> only 2 packages listed
assert_grep '^HUD_WEB 2 listed   /   2 installed   /   0 upgradable' "status HUD reflects search filter (listed=2)"
assert_grep 'glyphs .*"6 listed'                "HUD rendered into the status bar"

# --- clicking a row selects + populates the detail pane ---------------------
assert_grep '^HIT 5'                            "row click hit-tests to select"
assert_grep '^SEL 2'                            "selected package index 2 (hambrowse)"
assert_grep '^SEL_NAME hambrowse'               "selected package name is hambrowse"
assert_grep 'glyphs .*\"Version:\"'             "detail: version label"
assert_grep 'glyphs .*\"0.9\"'                  "detail: parsed version value"
assert_grep 'glyphs .*\"Depends:\"'             "detail: depends label"
assert_grep 'glyphs .*\"webkitgtk, hamnix-base\"' "detail: parsed dependency list"
assert_grep 'glyphs .*\"#hamnix-system\"'       "detail: parsed target"

# --- raster: the header bar really painted the blue chrome ------------------
assert_grep '^PIX 4 4 3103887'                  "raster header pixel = #2f5c8f"

if [ "$fail" -ne 0 ]; then echo "[hampkg-host] OVERALL FAIL"; exit 1; fi
echo "[hampkg-host] OVERALL PASS"
