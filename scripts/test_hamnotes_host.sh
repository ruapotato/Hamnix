#!/usr/bin/env bash
# scripts/test_hamnotes_host.sh — FAST, QEMU-free host gate for the Notes app
# (lib/hamnotescore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). It renders the empty pad (New/Save toolbar visible),
# types a scripted note, fires SAVE (Ctrl-S) which writes note-0.txt to a real
# scratch dir, fires NEW (Ctrl-N) which blanks the editor onto note-1, then
# pages back (Prev) which RELOADS note-0 off disk — proving a saved note
# persists. Four PNGs a human/agent can LOOK at are produced, the buffer
# lengths + ON-DISK byte counts are asserted, AND the NATIVE Hamnix build is
# confirmed to still compile from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamnotes_host"
ROOT="$OUT/notes_scratch"
mkdir -p "$OUT"
rm -rf "$ROOT"
mkdir -p "$ROOT"
fail=0

echo "[notes-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamnotesscene_host.ad "$BIN" 2>"$OUT/notes_compile.log"; then
    echo "[notes-host] FAIL: host harness did not compile"; cat "$OUT/notes_compile.log"; exit 1
fi
echo "[notes-host] PASS host harness compiled -> $BIN"

echo "[notes-host] compiling NATIVE hamnotesscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamnotesscene.ad "$OUT/hamnotes_native.elf" 2>"$OUT/notes_native.log"; then
    echo "[notes-host] FAIL: native hamnotesscene did not compile"; cat "$OUT/notes_native.log"; exit 1
fi
echo "[notes-host] PASS native hamnotesscene still compiles"

DUMP="$OUT/notes_dump.txt"
# #328: the trailing WORD.ppm/LINE.ppm args make the harness also exercise the
# double-click (select word) + triple-click (select line) paths and render each.
# argv[6] keeps the harness's DEFAULT body script ("Buy milk"<nl>"Call Sam") so
# the existing edit/save assertions below are unchanged; the word/line renders
# seed their own body via hamnotes_set_text, independent of this.
if ! "$BIN" "$ROOT" "$OUT/notes_before.ppm" "$OUT/notes_after.ppm" \
        "$OUT/notes_new.ppm" "$OUT/notes_reload.ppm" $'Buy milk\nCall Sam' \
        "$OUT/notes_word.ppm" "$OUT/notes_line.ppm" >"$DUMP" 2>&1; then
    echo "[notes-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after new reload word line; do
    if python3 scripts/ppm_to_png.py "$OUT/notes_$f.ppm" "$OUT/notes_$f.png" 2>"$OUT/notes_png.log"; then
        echo "[notes-host] PASS rendered $OUT/notes_$f.png"
    else
        echo "[notes-host] FAIL png conversion ($f)"; cat "$OUT/notes_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[notes-host] PASS $2";
    else echo "[notes-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# --- scene / toolbar / sidebar / title-field renders -----------------------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 480 300 #eceef2'         "notes window background"
assert_grep '^glyphs 10 6 \"Notes\"'            "app title label"
assert_grep 'glyphs .*\"New\"'                  "New toolbar button rendered"
assert_grep 'glyphs .*\"Save\"'                 "Save toolbar button rendered"
assert_grep 'glyphs .*\"Delete\"'               "Delete toolbar button rendered"
assert_grep 'glyphs .*\"Note 1/2\"'             "note indicator rendered (note 1 of 2)"
assert_grep 'glyphs .*\"NOTES\"'                "sidebar selector header rendered"
assert_grep '^fill 0 48 140 252 #f7f8fa'        "sidebar note-list panel rendered"
assert_grep 'glyphs .*\"Title\"'                "title-field label rendered"
assert_grep '^PIX 20 120 #f7f8fa'               "raster sidebar pixel"
assert_grep '^PIX 200 150 #fffef0'              "raster body paper pixel = pale note"

# --- the note SELECTOR lists both notes by their title ----------------------
assert_grep 'glyphs .*\"Groceries\"'            "note-0 title shown (title field + sidebar row)"
assert_grep 'glyphs .*\"Todo\"'                 "note-1 title shown in the sidebar selector"

# --- typing: TITLE field + BODY edit area -----------------------------------
assert_grep '^LEN0 0'                           "body starts empty"
assert_grep '^TITLE_LEN 9'                       "title field holds \"Groceries\" (9 chars)"
# Body script types "Buy milk\nCall Sam" then one backspace -> 16 chars.
assert_grep '^LEN1 16'                          "typed body + backspace edit gives 16 chars"
assert_grep '^DIRTY 1'                          "buffer marked dirty after edits"
assert_grep '^WORDS 4'                          "word count = 4 for \"Buy milk Call Sa\""

# --- live word/char count readout in the status bar (SCENE = reloaded note-0) -
# The dumped scene is the RELOAD render: note-0 body "Buy milk\\nCall Sa" =
# 4 words / 16 chars, drawn right-aligned in the toolbar strip.
assert_grep 'glyphs .*\"4 words  16 chars\"'    "status-bar word/char count rendered"
assert_grep 'glyphs .*\"Buy milk\"'             "first body line rendered"
assert_grep 'glyphs .*\"Call Sa\"'             "second body line rendered (backspaced)"

# --- SAVE persists title+body together to a real file -----------------------
assert_grep '^DIRTY_AFTER_SAVE 0'              "Ctrl-S clears the dirty flag"
assert_grep '^FILE0_LEN 26'                     "Ctrl-S wrote title+body (26 bytes) to note-0.txt"

# --- NEW blanks the editor onto a fresh note --------------------------------
assert_grep '^LEN_AFTER_NEW 0'                  "Ctrl-N clears the editor"
assert_grep '^IDX_AFTER_NEW 1'                  "Ctrl-N advances to a new note index"

# --- clicking a sidebar row SELECTS + reloads that note off disk ------------
assert_grep '^HIT_ROW0 5'                        "clicking a sidebar row hit-tests to select"
assert_grep '^IDX_AFTER_SELECT 0'               "selecting sidebar row 0 returns to note-0"
assert_grep '^LEN_AFTER_RELOAD 16'              "note-0 body reloaded from disk (16 bytes)"
assert_grep '^TITLE_AFTER_RELOAD 9'             "note-0 title reloaded from disk (Groceries)"

# --- #328 double/triple click: word vs line selection -----------------------
# Body "hello world foo": a double-click mid-"world" selects the 5-char word;
# a triple-click selects the whole 15-char line (also rendered to PNG).
assert_grep '^WORD_SEL 5'                        "double-click selects the word (\"world\", 5 chars)"
assert_grep '^LINE_SEL 15'                       "triple-click selects the whole line (15 chars)"

# --- DELETE removes the current note ----------------------------------------
assert_grep '^HIT_DELETE 6'                      "clicking Delete hit-tests to delete"
assert_grep '^COUNT_AFTER_DELETE 1'             "delete drops the note count 2 -> 1"
assert_grep '^TITLE_AFTER_DELETE 4'             "surviving note (Todo) shifted into slot 0"

# --- the scratch dir really holds the note + state files --------------------
if [ -s "$ROOT/note-0.txt" ]; then echo "[notes-host] PASS note-0.txt exists on disk";
else echo "[notes-host] FAIL note-0.txt not written to $ROOT"; fail=1; fi
if [ -s "$ROOT/.state" ]; then echo "[notes-host] PASS .state index written";
else echo "[notes-host] FAIL .state index not written"; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "[notes-host] OVERALL FAIL"; exit 1; fi
echo "[notes-host] OVERALL PASS"
