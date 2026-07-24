#!/usr/bin/env bash
# scripts/test_hamwrite_host.sh — FAST, QEMU-free host gate for HamWrite, the
# native office-suite WORD PROCESSOR (lib/hamwritecore.ad drawn through
# lib/hamscene.ad + rasterized by lib/hamui_host.ad). It drives the SHIPPING
# core through a full editing session and asserts, at every step, that both the
# document MODEL and the RENDER agree:
#
#   1. window chrome — title bar, File/Edit/Format MENU BAR, the formatting
#      toolbar (B / I / U / H1, the S-M-L-XL size buttons, Left/Center/Right)
#      and the white page all render;
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
#   5. SAVE/LOAD ROUND-TRIPS EVERY ATTRIBUTE — a HAMWRITE1 container is written
#      to a real file, the buffer is cleared, the file is re-opened off disk and
#      the text, the bold span, the underline, the size class AND the paragraph
#      alignment all come back byte-exact; "Save As" writes a second real file;
#   6. SCROLLING — a document longer than the page scrolls to keep the caret in
#      view, and a wheel-up returns to the top.
#
#   7. a SHOWCASE render — a realistic mixed-format document (centred XL title,
#      bold sub-head, a wrapped body with an underlined and an italic run, a
#      right-aligned small sign-off) assembled entirely through the toolbar
#      hit-tests a user clicks.
#
# Three PNGs a human/agent can LOOK at are produced (build/host/hw_before.png,
# hw_after.png, hw_showcase.png), and the NATIVE Hamnix build is confirmed to
# still compile from the same core.

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
        'Hello world from HamWrite' "$OUT/hw_showcase.ppm" >"$DUMP" 2>&1; then
    echo "[hamwrite-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after showcase; do
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
assert_in() {
    if awk -v b="^$1-BEGIN$" -v e="^$1-END$" \
            '$0 ~ b {f=1;next} $0 ~ e {f=0} f' "$DUMP" | grep -Eq -- "$2"; then
        echo "[hamwrite-host] PASS $3"
    else
        echo "[hamwrite-host] FAIL $3 (missing in $1: $2)"; fail=1
    fi
}

# --- window chrome / menu bar / toolbar / page renders ----------------------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 640 452 #dfe3e8'         "hamwrite window background"
assert_grep '^fill 0 0 640 22 #3f6fb5'          "blue title bar"
assert_grep 'glyphs .*\"HamWrite\"'             "app title label"
assert_grep 'glyphs .*\"report.hdoc\"'          "filename shown in the title bar"
assert_grep '^fill 0 22 640 22 #f3f4f6'         "menu bar strip rendered"
assert_grep 'glyphs .*\"File\"'                 "File menu title"
assert_grep 'glyphs .*\"Edit\"'                 "Edit menu title"
assert_grep 'glyphs .*\"Format\"'               "Format menu title"
assert_grep 'glyphs .*\"B\"'                    "Bold toolbar button rendered"
assert_grep 'glyphs .*\"I\"'                    "Italic toolbar button rendered"
assert_grep 'glyphs .*\"U\"'                    "Underline toolbar button rendered"
assert_grep 'glyphs .*\"H1\"'                   "Heading toolbar button rendered"
assert_grep 'glyphs .*\"XL\"'                   "XL (title) size button rendered"
assert_grep 'glyphs .*\"Center\"'               "Center alignment button rendered"
assert_grep 'glyphs .*\"Open\"'                 "Open toolbar button rendered"
assert_grep 'glyphs .*\"Save\"'                 "Save toolbar button rendered"
assert_grep '^fill 12 82 616 330 #ffffff'       "white document page rendered"
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
assert_in SCENE 'glyphs 26 92 \"Hello\" #[0-9a-f]+ b' \
    "bolded \"Hello\" drawn as a double-struck run"
assert_in SCENE 'glyphs [0-9]+ 92 \" world from HamWrite\" #[0-9a-f]+$' \
    "plain remainder drawn as a normal run"

# --- UNDERLINE toggles the model AND emits a rule under the run ------------
assert_grep '^UNDER_HIT 3'                      "clicking the Underline button hit-tests"
assert_grep '^UNDER1 25'                        "all 25 chars carry the underline bit"

# --- TEXT SIZE: XL re-emits the run per character at a scaled advance ------
assert_grep '^SIZE_HIT 3'                       "clicking the XL size button hit-tests"
assert_grep '^SIZE_TITLE 25'                    "all 25 chars carry the title size class"
# A title-sized run is drawn per character with a second strike one pixel down.
assert_in FMT 'glyphs [0-9]+ 100 \"H\" #[0-9a-f]+ b' \
    "title run emits a per-character glyph op"
assert_in FMT 'glyphs [0-9]+ 101 \"H\" #[0-9a-f]+ b' \
    "title run emits its second (fattening) strike a pixel lower"
assert_in FMT '^line [0-9]+ 11[0-9] [0-9]+ 11[0-9] 1 #[0-9a-f]+' \
    "underlined run draws a real rule under the glyphs"

# --- PARAGRAPH ALIGNMENT: centring moves the row off the left margin -------
assert_grep '^ALIGN_HIT 3'                      "clicking the Center button hit-tests"
assert_grep '^ALIGN_CENTER 25'                  "whole paragraph is centre-aligned"
if awk '/^FMT-BEGIN$/{f=1;next}/^FMT-END$/{f=0}f' "$DUMP" \
        | grep -Eq 'glyphs 1[0-9][0-9] 100 \"H\"'; then
    echo "[hamwrite-host] PASS centred row starts well right of the 26px text margin"
else
    echo "[hamwrite-host] FAIL centred row did not shift right"; fail=1
fi

# --- MENU BAR: File drop-down opens and its items render -------------------
assert_grep '^MENU_HIT 3'                       "clicking \"File\" hit-tests the menu bar"
assert_grep '^MENU_OPEN 1'                      "the File drop-down is open"
assert_in MENU 'glyphs [0-9]+ [0-9]+ \"New\"'         "File menu draws \"New\""
assert_in MENU 'glyphs [0-9]+ [0-9]+ \"Save As\.\.\.\"' "File menu draws \"Save As...\""
assert_in MENU 'glyphs [0-9]+ [0-9]+ \"Quit\"'        "File menu draws \"Quit\""

# --- SAVE writes a HAMWRITE1 container to disk ------------------------------
assert_grep '^DIRTY_AFTER_SAVE 0'               "Ctrl-S clears the dirty flag"
# File = "HAMWRITE1\n"(10) + "25\n"(3) + 25 text + 25 attr = 63 bytes.
assert_grep '^FILE_LEN 63'                      "Ctrl-S wrote the 63-byte document container"

# --- CLEAR + RE-OPEN off disk: EVERY attribute round-trips -----------------
assert_grep '^LEN_AFTER_CLEAR 0'                "buffer cleared before reopen"
assert_grep '^LEN_AFTER_OPEN 25'                "Ctrl-O reloaded the 25-char body off disk"
assert_grep '^BOLD_AFTER_OPEN 5'                "the bold span SURVIVED the save->load round-trip"
assert_grep '^UNDER_AFTER_OPEN 25'              "the underline SURVIVED the round-trip"
assert_grep '^SIZE_AFTER_OPEN 25'               "the title text size SURVIVED the round-trip"
assert_grep '^ALIGN_AFTER_OPEN 25'              "the centre alignment SURVIVED the round-trip"

# --- the reloaded body text matches exactly --------------------------------
if awk '/^BODY-BEGIN$/{f=1;next} /^BODY-END$/{f=0} f' "$DUMP" \
        | grep -qx 'Hello world from HamWrite'; then
    echo "[hamwrite-host] PASS reloaded body text is byte-exact"
else
    echo "[hamwrite-host] FAIL reloaded body text mismatch"; fail=1
fi

# --- "Save As..." prompt: type a name, Enter, a SECOND real file appears ----
assert_grep '^PROMPT 1'                         "File > Save As... raises the modal prompt"
assert_grep '^PROMPT_TEXT renamed.hdoc'         "the prompt accepts a typed filename"
assert_grep '^PROMPT_AFTER 0'                   "Enter closes the prompt"
assert_grep '^SAVEAS_NAME renamed.hdoc'         "the document is renamed to the typed name"
assert_grep '^SAVEAS_LEN 63'                    "Save As wrote the container under the new name"

# --- SCROLLING over a document taller than the page ------------------------
assert_grep '^ROWS 41'                          "40 typed lines lay out as 41 rows"
if awk '/^SCROLL_TOP /{print $2}' "$DUMP" | grep -Eqx '[1-9][0-9]*'; then
    echo "[hamwrite-host] PASS the page scrolled to keep the caret in view"
else
    echo "[hamwrite-host] FAIL page did not scroll to the caret"; fail=1
fi
assert_grep '^SCROLL_HOME 0'                    "a wheel-up scroll returns to the top of the document"

# --- SHOWCASE: a realistic mixed-format document, built entirely through the
# --- toolbar hit-tests a user clicks (this is the PNG worth looking at) -----
assert_grep '^SHOWCASE_LEN 184'                 "showcase document assembled via the toolbar"

# --- the document files really exist on disk -------------------------------
if [ -s "$DOC" ]; then echo "[hamwrite-host] PASS $DOC written on disk";
else echo "[hamwrite-host] FAIL document not written to $DOC"; fail=1; fi
if [ -s "$ALT" ]; then echo "[hamwrite-host] PASS $ALT written by Save As";
else echo "[hamwrite-host] FAIL Save As document not written to $ALT"; fail=1; fi
# and its first bytes are the self-describing magic.
if head -c 9 "$DOC" | grep -qx 'HAMWRITE1'; then
    echo "[hamwrite-host] PASS document carries the HAMWRITE1 magic";
else echo "[hamwrite-host] FAIL document missing HAMWRITE1 magic"; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "[hamwrite-host] OVERALL FAIL"; exit 1; fi
echo "[hamwrite-host] OVERALL PASS"
