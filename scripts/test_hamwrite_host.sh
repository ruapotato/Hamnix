#!/usr/bin/env bash
# scripts/test_hamwrite_host.sh — FAST, QEMU-free host gate for HamWrite, the
# native office-suite WORD PROCESSOR (lib/hamwritecore.ad drawn through
# lib/hamscene.ad + rasterized by lib/hamui_host.ad). It drives the SHIPPING
# core through a full editing session and asserts, at every step, that both the
# document MODEL and the RENDER agree:
#
#   1. window chrome — title bar, File/Edit/Format MENU BAR, BOTH formatting
#      toolbar rows (B / I / U, H1-H2-H3, the S-M-L-XL size buttons,
#      Left/Center/Right, Undo/Redo, Bul/Num, indent/outdent, the eight-colour
#      palette, the highlighter and Find), the RULER and the white page;
#   2. TEXT ENTRY — typed keys land in the buffer with a live word/char count;
#   3. FORMATTING TOGGLES CHANGE THE RENDERED RUN, not just the model:
#        * bold  -> a double-struck `glyphs ... b` op for exactly the bolded
#                   word, with the plain remainder as its own normal run;
#        * underline -> a real `line` op under the run;
#        * text size (XL/title) -> the run is re-emitted PER CHARACTER at a
#                   scaled advance with a second strike a pixel lower;
#        * align centre -> the row's left edge moves off the text margin;
#   4. the MENU BAR works — clicking "File" opens a drop-down whose items draw,
#      and clicking "Save As..." raises the modal filename prompt;
#   5. SAVE/LOAD ROUND-TRIPS EVERY ATTRIBUTE — a HAMWRITE2 container is written
#      to a real file, the buffer is cleared, the file is re-opened off disk and
#      the text, the bold span, the underline, the size class AND the paragraph
#      alignment all come back byte-exact; "Save As" writes a second real file;
#   6. SCROLLING — a document longer than the page scrolls to keep the caret in
#      view, and a wheel-up returns to the top.
#
#   7. MULTI-LEVEL UNDO/REDO — typing groups into word-sized undo steps, redo
#      restores them, a fresh edit truncates the redo branch, and formatting
#      and Replace-All are each a single undoable step;
#   8. FIND & REPLACE — a live case-insensitive hit count, Find Next with a
#      selection on the match, "not found", every hit painted with a highlight
#      band on the page, and Replace All rewriting the body;
#   9. LISTS + INDENT + COLOUR + HIGHLIGHT — bullet and numbered paragraphs
#      draw a marker in a real gutter, indent shifts the whole paragraph, the
#      colour palette re-inks the run, the highlighter paints behind it, and
#      the SECOND attribute plane round-trips through a HAMWRITE2 container;
#
#  10. a SHOWCASE render — a realistic mixed-format document (centred XL title,
#      bold sub-head, a wrapped body with an underlined and an italic run, a
#      right-aligned small sign-off) assembled entirely through the toolbar
#      hit-tests a user clicks.
#
# Four PNGs a human/agent can LOOK at are produced (build/host/hw_before.png,
# hw_after.png, hw_find.png, hw_showcase.png), and the NATIVE Hamnix build is
# confirmed to still compile from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamwrite_host"
DOC="$OUT/hamwrite_scratch.hdoc"
ALT="$OUT/renamed.hdoc"
mkdir -p "$OUT"
rm -f "$DOC" "$ALT"
fail=0

echo "[hamwrite-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamwrite_host.ad -o "$BIN" 2>"$OUT/hw_compile.log"; then
    echo "[hamwrite-host] FAIL: host harness did not compile"; cat "$OUT/hw_compile.log"; exit 1
fi
echo "[hamwrite-host] PASS host harness compiled -> $BIN"

echo "[hamwrite-host] compiling NATIVE hamwrite for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamwrite.ad -o "$OUT/hamwrite_native.elf" 2>"$OUT/hw_native.log"; then
    echo "[hamwrite-host] FAIL: native hamwrite did not compile"; cat "$OUT/hw_native.log"; exit 1
fi
echo "[hamwrite-host] PASS native hamwrite still compiles"

DUMP="$OUT/hw_dump.txt"
if ! "$BIN" "$DOC" "$OUT/hw_before.ppm" "$OUT/hw_after.ppm" \
        'Hello world from HamWrite' "$OUT/hw_showcase.ppm" \
        "$OUT/hw_find.ppm" >"$DUMP" 2>&1; then
    echo "[hamwrite-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after find showcase; do
    if python3 scripts/ppm_to_png.py "$OUT/hw_$f.ppm" "$OUT/hw_$f.png" 2>"$OUT/hw_png.log"; then
        echo "[hamwrite-host] PASS rendered $OUT/hw_$f.png"
    else
        echo "[hamwrite-host] FAIL png conversion ($f)"; cat "$OUT/hw_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamwrite-host] PASS $2";
    else echo "[hamwrite-host] FAIL $2 (missing: $1)"; fail=1; fi
}
# assert_in SECTION REGEX MSG — assert inside a BEGIN/END scene dump only.
# NOTE: awk output is captured FIRST (never piped into grep -q) — under
# `set -o pipefail` an early-exiting grep SIGPIPEs awk and the whole pipeline
# reports failure even when the pattern matched.
section() {
    awk -v b="^$1-BEGIN$" -v e="^$1-END$" \
        '$0 ~ b {f=1;next} $0 ~ e {f=0} f' "$DUMP"
}
assert_in() {
    if grep -Eq -- "$2" <<<"$(section "$1")"; then
        echo "[hamwrite-host] PASS $3"
    else
        echo "[hamwrite-host] FAIL $3 (missing in $1: $2)"; fail=1
    fi
}

# --- window chrome / menu bar / toolbar / page renders ----------------------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 720 552 #dfe3e8'         "hamwrite window background"
assert_grep '^fill 0 0 720 22 #3f6fb5'          "blue title bar"
assert_grep 'glyphs .*\"HamWrite\"'             "app title label"
assert_grep 'glyphs .*\"report.hdoc\"'          "filename shown in the title bar"
assert_grep '^fill 0 22 720 22 #f3f4f6'         "menu bar strip rendered"
assert_grep 'glyphs .*\"File\"'                 "File menu title"
assert_grep 'glyphs .*\"Edit\"'                 "Edit menu title"
assert_grep 'glyphs .*\"Format\"'               "Format menu title"
assert_grep 'glyphs .*\"B\"'                    "Bold toolbar button rendered"
assert_grep 'glyphs .*\"I\"'                    "Italic toolbar button rendered"
assert_grep 'glyphs .*\"U\"'                    "Underline toolbar button rendered"
assert_grep 'glyphs .*\"H1\"'                   "H1 heading toolbar button rendered"
assert_grep 'glyphs .*\"XL\"'                   "XL (title) size button rendered"
assert_grep 'glyphs .*\"Center\"'               "Center alignment button rendered"
assert_grep 'glyphs .*\"Open\"'                 "Open toolbar button rendered"
assert_grep 'glyphs .*\"Save\"'                 "Save toolbar button rendered"
assert_grep '^fill 12 120 696 396 #ffffff'      "white document page rendered"
assert_grep '^PIX 4 4 #3f6fb5'                  "raster title-bar pixel = blue"
assert_grep '^PIX 200 200 #ffffff'              "raster page pixel = white paper"

# --- typing + live word/char count -----------------------------------------
assert_grep '^LEN0 0'                           "document starts empty"
assert_grep '^LEN1 25'                          "typed body is 25 chars"
assert_grep '^WORDS 4'                          "word count = 4"
assert_grep '^DIRTY 1'                          "buffer marked dirty after typing"
assert_grep 'glyphs .*\"4 words  25 chars\"'    "status-bar word/char count rendered"

# --- select the first word + apply BOLD (model AND render) ------------------
assert_grep '^WORDSEL 5'                        "double-click selects the word (\"Hello\", 5 chars)"
assert_grep '^BOLD_HIT 3'                       "clicking the Bold button hit-tests (redraw)"
assert_grep '^BOLD1 5'                          "5 chars are now bold"
# The FORMATTED scene must contain a REAL bold-glyph op (trailing 'b' flag) for
# the bolded word, distinct from the plain remainder run.
assert_in SCENE 'glyphs 30 132 \"Hello\" #[0-9a-f]+ b' \
    "bolded \"Hello\" drawn as a double-struck run"
assert_in SCENE 'glyphs [0-9]+ 132 \" world from HamWrite\" #[0-9a-f]+$' \
    "plain remainder drawn as a normal run"

# --- UNDERLINE toggles the model AND emits a rule under the run ------------
assert_grep '^UNDER_HIT 3'                      "clicking the Underline button hit-tests"
assert_grep '^UNDER1 25'                        "all 25 chars carry the underline bit"

# --- TEXT SIZE: XL re-emits the run per character at a scaled advance ------
assert_grep '^SIZE_HIT 3'                       "clicking the XL size button hit-tests"
assert_grep '^SIZE_TITLE 25'                    "all 25 chars carry the title size class"
# A title-sized run is drawn per character with a second strike one pixel down.
assert_in FMT 'glyphs [0-9]+ 140 \"H\" #[0-9a-f]+ b' \
    "title run emits a per-character glyph op"
assert_in FMT 'glyphs [0-9]+ 141 \"H\" #[0-9a-f]+ b' \
    "title run emits its second (fattening) strike a pixel lower"
assert_in FMT '^line [0-9]+ 15[0-9] [0-9]+ 15[0-9] 1 #[0-9a-f]+' \
    "underlined run draws a real rule under the glyphs"

# --- PARAGRAPH ALIGNMENT: centring moves the row off the left margin -------
assert_grep '^ALIGN_HIT 3'                      "clicking the Center button hit-tests"
assert_grep '^ALIGN_CENTER 25'                  "whole paragraph is centre-aligned"
if grep -Eq 'glyphs [12][0-9][0-9] 140 \"H\"' <<<"$(section FMT)"; then
    echo "[hamwrite-host] PASS centred row starts well right of the 30px text margin"
else
    echo "[hamwrite-host] FAIL centred row did not shift right"; fail=1
fi

# --- MENU BAR: File drop-down opens and its items render -------------------
assert_grep '^MENU_HIT 3'                       "clicking \"File\" hit-tests the menu bar"
assert_grep '^MENU_OPEN 1'                      "the File drop-down is open"
assert_in MENU 'glyphs [0-9]+ [0-9]+ \"New\"'         "File menu draws \"New\""
assert_in MENU 'glyphs [0-9]+ [0-9]+ \"Save As\.\.\.\"' "File menu draws \"Save As...\""
assert_in MENU 'glyphs [0-9]+ [0-9]+ \"Quit\"'        "File menu draws \"Quit\""

# --- SAVE writes a HAMWRITE2 container to disk ------------------------------
assert_grep '^DIRTY_AFTER_SAVE 0'               "Ctrl-S clears the dirty flag"
# File = "HAMWRITE2\n"(10) + "25\n"(3) + 25 text + 25 attr + 25 attr2 = 88.
assert_grep '^FILE_LEN 88'                      "Ctrl-S wrote the 88-byte HAMWRITE2 container"

# --- CLEAR + RE-OPEN off disk: EVERY attribute round-trips -----------------
assert_grep '^LEN_AFTER_CLEAR 0'                "buffer cleared before reopen"
assert_grep '^LEN_AFTER_OPEN 25'                "Ctrl-O reloaded the 25-char body off disk"
assert_grep '^BOLD_AFTER_OPEN 5'                "the bold span SURVIVED the save->load round-trip"
assert_grep '^UNDER_AFTER_OPEN 25'              "the underline SURVIVED the round-trip"
assert_grep '^SIZE_AFTER_OPEN 25'               "the title text size SURVIVED the round-trip"
assert_grep '^ALIGN_AFTER_OPEN 25'              "the centre alignment SURVIVED the round-trip"

# --- the reloaded body text matches exactly --------------------------------
if grep -qx 'Hello world from HamWrite' <<<"$(section BODY)"; then
    echo "[hamwrite-host] PASS reloaded body text is byte-exact"
else
    echo "[hamwrite-host] FAIL reloaded body text mismatch"; fail=1
fi

# --- "Save As..." prompt: type a name, Enter, a SECOND real file appears ----
assert_grep '^PROMPT 1'                         "File > Save As... raises the modal prompt"
assert_grep '^PROMPT_TEXT renamed.hdoc'         "the prompt accepts a typed filename"
assert_grep '^PROMPT_AFTER 0'                   "Enter closes the prompt"
assert_grep '^SAVEAS_NAME renamed.hdoc'         "the document is renamed to the typed name"
assert_grep '^SAVEAS_LEN 88'                    "Save As wrote the container under the new name"

# --- SCROLLING over a document taller than the page ------------------------
assert_grep '^ROWS 41'                          "40 typed lines lay out as 41 rows"
if grep -Eqx '[1-9][0-9]*' <<<"$(awk '/^SCROLL_TOP /{print $2}' "$DUMP")"; then
    echo "[hamwrite-host] PASS the page scrolled to keep the caret in view"
else
    echo "[hamwrite-host] FAIL page did not scroll to the caret"; fail=1
fi
assert_grep '^SCROLL_HOME 0'                    "a wheel-up scroll returns to the top of the document"

# --- SHOWCASE: a realistic mixed-format document, built entirely through the
# --- toolbar hit-tests a user clicks (this is the PNG worth looking at) -----
assert_grep '^SHOWCASE_LEN 307'                 "showcase document assembled via the toolbar"

# --- the document files really exist on disk -------------------------------
if [ -s "$DOC" ]; then echo "[hamwrite-host] PASS $DOC written on disk";
else echo "[hamwrite-host] FAIL document not written to $DOC"; fail=1; fi
if [ -s "$ALT" ]; then echo "[hamwrite-host] PASS $ALT written by Save As";
else echo "[hamwrite-host] FAIL Save As document not written to $ALT"; fail=1; fi
# and its first bytes are the self-describing magic.
if head -c 9 "$DOC" | grep -qx 'HAMWRITE2'; then
    echo "[hamwrite-host] PASS document carries the HAMWRITE2 magic";
else echo "[hamwrite-host] FAIL document missing HAMWRITE2 magic"; fail=1; fi

# --- toolbar row 2 + the ruler render --------------------------------------
assert_grep 'glyphs .*\"H2\"'                   "H2 heading toolbar button rendered"
assert_grep 'glyphs .*\"H3\"'                   "H3 heading toolbar button rendered"
assert_grep 'glyphs .*\"Undo\"'                 "Undo toolbar button rendered"
assert_grep 'glyphs .*\"Redo\"'                 "Redo toolbar button rendered"
assert_grep 'glyphs .*\"Bul\"'                  "bullet-list toolbar button rendered"
assert_grep 'glyphs .*\"Num\"'                  "numbered-list toolbar button rendered"
assert_grep 'glyphs .*\">>\"'                   "indent toolbar button rendered"
assert_grep 'glyphs .*\"<<\"'                   "outdent toolbar button rendered"
assert_grep 'glyphs .*\"HL\"'                   "highlighter toolbar button rendered"
assert_grep 'glyphs .*\"Find\"'                 "Find toolbar button rendered"
assert_grep '^fill 274 81 16 16 #202020'        "colour palette swatch 0 rendered"
assert_grep '^fill 292 81 16 16 #c0392b'        "colour palette swatch 1 (red) rendered"
assert_grep '^fill 30 106 650 12 #ffffff'       "ruler shows the text column"
assert_grep 'glyphs [0-9]+ 103 \"1\"'           "ruler draws its inch marks"
assert_grep 'glyphs .*\"Ln 1, Col 26\"'         "status footer shows the caret Ln/Col"

# --- MULTI-LEVEL UNDO / REDO -----------------------------------------------
assert_grep '^UNDO_LEN0 16'                     "typed \"alpha beta gamma\" (16 chars)"
assert_grep '^UNDO_DEPTH 3'                     "typing coalesced into 3 word-sized undo groups"
assert_grep '^CAN_UNDO 1'                       "undo is available after typing"
assert_grep '^CAN_REDO0 0'                      "nothing to redo before an undo"
assert_grep '^UNDO_LEN1 11'                     "Ctrl-Z removed the last typed word"
assert_grep '^UNDO_LEN2 6'                      "a second Ctrl-Z removed the word before it"
assert_grep '^CAN_REDO1 1'                      "redo becomes available after undoing"
assert_grep '^REDO_LEN1 11'                     "Ctrl-Y put the second word back"
assert_grep '^REDO_LEN2 16'                     "a second Ctrl-Y fully restored the document"
assert_grep '^REDO_AFTER_EDIT 0'                "a fresh edit truncates the redo branch"
assert_grep '^FMT_BOLD 6'                       "bold applied to the whole word"
assert_grep '^FMT_BOLD_UNDONE 0'                "Ctrl-Z undoes a FORMATTING change too"

# --- FIND & REPLACE ---------------------------------------------------------
assert_grep '^FIND_OPEN 1'                      "Ctrl-F opens the Find & Replace dialog"
assert_grep '^FIND_HITS 3'                      "the live hit counter found all 3 matches"
assert_grep '^FIND_CUR1 5'                      "Find Next landed on the first match"
assert_grep '^FIND_SEL1 2'                      "the match is SELECTED, ready to replace"
assert_grep '^FIND_CUR2 9'                      "Find Next advanced to the second match"
assert_grep '^FIND_CI 2'                        "matching is case-INSENSITIVE (\"THE\" finds \"the\")"
assert_grep '^FIND_MISS 1'                      "a needle that is not there reports \"not found\""
assert_grep '^REPL_N 3'                         "Replace All rewrote all 3 matches"
assert_grep '^REPL_HITS 0'                      "no matches remain after Replace All"
assert_grep '^FIND_CLOSED 0'                    "the Find dialog closes"
# the dialog draws, and EVERY hit gets a highlight band on the page
assert_in FIND 'glyphs [0-9]+ [0-9]+ \"Find & Replace\"' "the Find dialog renders"
assert_in FIND 'glyphs [0-9]+ [0-9]+ \"Replace All\"'    "the Replace All button renders"
if [ "$(grep -Ec '^fill [0-9]+ 130 [0-9]+ 20 #ffd24a' <<<"$(section FIND)")" = 3 ]; then
    echo "[hamwrite-host] PASS all 3 matches are highlighted on the page at once"
else
    echo "[hamwrite-host] FAIL find did not highlight every match"; fail=1
fi
if grep -qx 'the cog sog on the mog' <<<"$(section REPLBODY)"; then
    echo "[hamwrite-host] PASS Replace All produced the expected body text"
else
    echo "[hamwrite-host] FAIL Replace All body text mismatch"; fail=1
fi
if grep -qx 'the cat sat on the mat' <<<"$(section REPL_UNDO)"; then
    echo "[hamwrite-host] PASS one Ctrl-Z undoes the WHOLE Replace All"
else
    echo "[hamwrite-host] FAIL Replace All was not a single undo step"; fail=1
fi

# --- LISTS, INDENT, TEXT COLOUR, HIGHLIGHT ---------------------------------
assert_grep '^LIST_BULLET 15'                   "the Bul button made every paragraph a bullet"
assert_grep '^INDENT1 15'                       "the >> button indented the whole list"
assert_grep '^INDENT0 15'                       "the << button outdented it again"
assert_grep '^LIST_NUMBER 15'                   "the Num button switched to a numbered list"
assert_grep '^COLOR1 15'                        "a palette swatch re-inked the selection"
assert_grep '^HILITE 15'                        "the highlighter marked the selection"
assert_grep '^HEAD2 15'                         "the H2 button applied heading level 2"
assert_grep '^HEAD3 15'                         "the H3 button applied heading level 3"
# a bullet paragraph draws its marker in a real gutter and shifts the text right
assert_in LIST '^roundrect 61 [0-9]+ 6 6 3 #[0-9a-f]+' \
    "a bullet marker is drawn in the list gutter"
assert_in LIST 'glyphs 78 [0-9]+ \"Milk\"'      "an indented bullet row starts 48px in"
assert_in LIST 'glyphs 78 [0-9]+ \"Bread\"'     "every item of the list is indented"
# a numbered paragraph draws its ORDINAL, counted down the list
assert_in NUMLIST 'glyphs [0-9]+ [0-9]+ \"1\.\"' "numbered list draws \"1.\""
assert_in NUMLIST 'glyphs [0-9]+ [0-9]+ \"2\.\"' "numbered list draws \"2.\""
assert_in NUMLIST 'glyphs [0-9]+ [0-9]+ \"3\.\"' "numbered list draws \"3.\""
assert_in NUMLIST 'glyphs [0-9]+ [0-9]+ \"Milk\" #c0392b' \
    "the coloured run is drawn in its palette colour"
assert_in NUMLIST '^fill [0-9]+ [0-9]+ [0-9]+ [0-9]+ #fff3a3' \
    "the highlighter paints a band behind the run"

# --- the SECOND attribute plane round-trips through a HAMWRITE2 container ---
assert_grep '^A2_FILE_LEN 58'                   "the 3-plane container is 58 bytes for 15 chars"
assert_grep '^A2_LEN 15'                        "the list document reloaded off disk"
assert_grep '^A2_LIST 15'                       "the NUMBERED LIST survived the round-trip"
assert_grep '^A2_COLOR 15'                      "the TEXT COLOUR survived the round-trip"
assert_grep '^A2_HILITE 15'                     "the HIGHLIGHT survived the round-trip"
assert_grep '^A2_HEAD3 15'                      "the H3 heading level survived the round-trip"
assert_grep '^A2_UNDO_AT_LOAD 0'                "opening a document resets the undo history"

# --- a FULL-CAPACITY document round-trips (3 planes, 12303 bytes) ----------
assert_grep '^BIG_FILE_LEN 12303'               "a 4096-char document serialises to 12303 bytes"
assert_grep '^BIG_LEN 4096'                     "the full-capacity document reloaded intact"
assert_grep '^BIG_COLOR 4096'                   "its colour plane reloaded intact"

if [ "$fail" -ne 0 ]; then echo "[hamwrite-host] OVERALL FAIL"; exit 1; fi
echo "[hamwrite-host] OVERALL PASS"
