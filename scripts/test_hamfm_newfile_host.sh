#!/usr/bin/env bash
# scripts/test_hamfm_newfile_host.sh — FAST, QEMU-free host gate for the file
# manager's right-click CONTEXT MENU + the new "New File" (create empty file)
# action (lib/hamfmcore.ad + user/hamfmscene.ad).
#
# WHAT IT PROVES (no QEMU, milliseconds):
#   (1) The empty-space context menu, built by the SHARED core
#       (fmc_menu_empty_rows / fmc_menu_label), now offers BOTH "New Folder"
#       AND "New File" — rendered to a PNG a human/agent LOOKs at, and asserted
#       in the scene display list. A "before" PNG (New Folder only) shows the
#       visual addition.
#   (2) The New-File action drives the REAL native creation primitive
#       (fmc_touch -> sys_open_write, the SAME open-create the on-device app
#       uses) against a scratch directory and creates a real 0-byte file with
#       the default name "New File.txt".
#   (3) The directory-LISTING render: the shared core (lib/hamfmcore.ad) sorts
#       entries directories-first then A→Z (case-insensitive), flags executables
#       with a green tint + corner badge, and draws a live entry-count HUD in
#       the breadcrumb. A representative model (dirs + files + two executables)
#       is built directly (enumeration is a kernel path the host can't run) and
#       rendered through the REAL fmc_paint to a PNG a human/agent LOOKs at; the
#       post-sort model dump + scene display list assert order/exec/count.
#   (4) The NATIVE Hamnix build of user/hamfmscene.ad still compiles from the
#       same core (x86_64-adder-user).
#
# Built with the frozen Python seed compiler (compiles 100% of the tree).
# PNG conversion uses scripts/ppm_to_png.py (Python stdlib zlib only).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamfm_host"
mkdir -p "$OUT"
fail=0

echo "[hamfm-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamfmscene_host.ad "$BIN" 2>"$OUT/hamfm_compile.log"; then
    echo "[hamfm-host] FAIL: host harness did not compile"; cat "$OUT/hamfm_compile.log"; exit 1
fi
echo "[hamfm-host] PASS host harness compiled -> $BIN"

echo "[hamfm-host] compiling NATIVE hamfmscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamfmscene.ad "$OUT/hamfmscene_native.elf" 2>"$OUT/hamfm_native.log"; then
    echo "[hamfm-host] FAIL: native hamfmscene did not compile"; cat "$OUT/hamfm_native.log"; exit 1
fi
echo "[hamfm-host] PASS native hamfmscene still compiles"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
DUMP="$OUT/hamfm_host_dump.txt"
BEFORE="$OUT/hamfm_menu_before.ppm"
AFTER="$OUT/hamfm_menu_after.ppm"
LISTING="$OUT/hamfm_listing.ppm"

echo "[hamfm-host] running host harness (scratch=$SCRATCH) ..."
if ! "$BIN" "$BEFORE" "$AFTER" "$SCRATCH" "$LISTING" >"$DUMP" 2>&1; then
    echo "[hamfm-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

# Render the PPMs to PNGs (saved for eyeballing).
for f in "menu_before:$BEFORE" "menu_after:$AFTER" "listing:$LISTING"; do
    name="${f%%:*}"; src="${f#*:}"; dst="$OUT/hamfm_$name.png"
    if python3 scripts/ppm_to_png.py "$src" "$dst" 2>"$OUT/hamfm_png.log"; then
        echo "[hamfm-host] PASS rendered $dst ($(file -b "$dst" 2>/dev/null))"
    else
        echo "[hamfm-host] FAIL png conversion ($name)"; cat "$OUT/hamfm_png.log"; fail=1
    fi
done

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hamfm-host] PASS $msg"
    else
        echo "[hamfm-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# (1) The AFTER context menu draws BOTH entries (real labels in the scene list).
assert_grep '^glyphs .* "New Folder" '  "menu draws 'New Folder' entry"
assert_grep '^glyphs .* "New File" '     "menu draws 'New File' entry"
# The shared core reported a 2-row empty-space menu (New Folder + New File).
assert_grep '^AFTER-ROWS 2$'             "empty-space menu has exactly 2 rows (Folder + File)"
# The before render is the old single-row menu (regression witness).
assert_grep '^BEFORE-ROWS 1$'            "before menu had only 1 row (New Folder)"

# (2) The New-File action created a real 0-byte file with the default name.
assert_grep '^NEWFILE-NAME New File\.txt$' "New-File proposes default name 'New File.txt'"
assert_grep '^NEWFILE-RC 1$'               "fmc_touch reported success"

# (3) The directory LISTING render: the shared core sorts dirs-first / A→Z,
# flags executables, and draws the entry-count HUD in the breadcrumb. Proven
# from the post-sort model dump + the rendered scene display list (no pixels).
# Input was shuffled (files before dirs, mixed case) so the order proves sort.
assert_grep '^ENTRY 0 D - \.\.$'          "'..' pinned at row 0"
assert_grep '^ENTRY 1 D - build$'          "dirs-first: 'build' sorts to row 1 (A→Z, case-insensitive)"
assert_grep '^ENTRY 2 D - Documents$'      "dir 'Documents' at row 2"
assert_grep '^ENTRY 3 D - Music$'          "dir 'Music' at row 3 (last dir)"
assert_grep '^ENTRY 4 F - apple.md$'       "first FILE ('apple.md') sorts AFTER all dirs at row 4"
assert_grep '^ENTRY 5 F X hello$'          "executable 'hello' flagged X (no extension)"
assert_grep '^ENTRY 7 F X run.sh$'         "executable 'run.sh' flagged X"
assert_grep '^ENTRY 8 F - zebra.txt$'      "'zebra.txt' sorts last (A→Z)"
assert_grep '^LISTING-COUNT 8$'            "entry-count HUD reports 8 real items (excludes '..')"
# The breadcrumb header glyph string carries the live count HUD "(8)".
assert_grep '^glyphs .* "hamfm: /home/live \(8\)" ' "breadcrumb draws path + '(8)' item-count HUD"
# The sorted labels render as real glyphs in the listing scene.
assert_grep '^glyphs .* "build" '          "listing draws the 'build' folder label"
assert_grep '^glyphs .* "run.sh" '         "listing draws the 'run.sh' executable label"
# Executable badge: two green roundrects (dark badge + light dot) are emitted
# for each of the two exec files — proves the type badge painted.
if [ "$(grep -Ec '^roundrect .* #2e8b3d( |$)' "$DUMP")" -ge 2 ]; then
    echo "[hamfm-host] PASS executable badge painted for exec files (>=2 green badges)"
else
    echo "[hamfm-host] FAIL executable badge missing (expected >=2 '#2e8b3d' roundrects)"; fail=1
fi

NEWFILE="$SCRATCH/New File.txt"
if [ -e "$NEWFILE" ]; then
    echo "[hamfm-host] PASS New-File created a real file: $NEWFILE"
    sz=$(stat -c '%s' "$NEWFILE" 2>/dev/null || echo -1)
    if [ "$sz" = "0" ]; then
        echo "[hamfm-host] PASS created file is 0 bytes (empty)"
    else
        echo "[hamfm-host] FAIL created file is not 0 bytes (size=$sz)"; fail=1
    fi
    # It "appears in the listing": a plain readdir of the scratch dir shows it.
    if ls -1 "$SCRATCH" | grep -Fxq "New File.txt"; then
        echo "[hamfm-host] PASS new file appears in the directory listing"
    else
        echo "[hamfm-host] FAIL new file not in directory listing"; fail=1
    fi
else
    echo "[hamfm-host] FAIL New-File did not create $NEWFILE"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hamfm-host] RESULT: PASS"
    exit 0
else
    echo "[hamfm-host] RESULT: FAIL"
    exit 1
fi
