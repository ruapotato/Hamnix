#!/usr/bin/env bash
# scripts/test_hamslides_host.sh — FAST, QEMU-free host gate for HamSlides, the
# office PRESENTATION app (lib/hamslidescore.ad drawn through lib/hamscene.ad +
# rasterized by lib/hamui_host.ad).
#
# It drives the SHIPPING core end to end: TYPES a three-slide deck through the
# key path (titles, MULTI-LEVEL bullets via Tab/Backspace, speaker NOTES via
# Ctrl-E), switches LAYOUTS through the Slide MENU and proves the rendered
# GEOMETRY moves with the layout, duplicates / deletes / UNDOES / REORDERS
# slides, cycles the THEME and proves the chrome pixel changes, SAVES a
# HAMSLIDES2 container to a real scratch file, CLEARS and RE-OPENS it (theme,
# layouts, bullet levels, notes and slide ORDER must all survive), then
# PRESENTS (Space / PageDown / Home / End navigation, 'n' notes overlay, 'b'
# blank, Esc exit) and finally loads a legacy HAMSLIDES1 file for backward
# compatibility. Four PNGs a human/agent can LOOK at are produced (EDIT
# two-column, EDIT picture, PRESENT, PRESENT title-slide), and the NATIVE
# Hamnix build is confirmed to still compile from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamslides_host"
DOC="$OUT/hamslides_scratch.hamslides"
V1="$OUT/hamslides_legacy_v1.hamslides"
mkdir -p "$OUT"
rm -f "$DOC"
fail=0

echo "[hamslides-host] compiling core+harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamslides_host.ad -o "$BIN" 2>"$OUT/hsl_compile.log"; then
    echo "[hamslides-host] FAIL: host harness did not compile"; cat "$OUT/hsl_compile.log"; exit 1
fi
echo "[hamslides-host] PASS host harness compiled -> $BIN"

echo "[hamslides-host] compiling NATIVE hamslides for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamslides.ad -o "$OUT/hamslides_native.elf" 2>"$OUT/hsl_native.log"; then
    echo "[hamslides-host] FAIL: native hamslides did not compile"; cat "$OUT/hsl_native.log"; exit 1
fi
echo "[hamslides-host] PASS native hamslides still compiles"

# A LEGACY HAMSLIDES1 document (title + bullets only, no theme/layout/notes/
# levels) — the v2 loader must still read it. Byte counts are literal.
{
    printf 'HAMSLIDES1\n2\n'
    printf '11\nLegacy Deck\n1\n16\nold format loads\n'
    printf '9\nSecond v1\n1\n13\nstill parses!\n'
} > "$V1"

DUMP="$OUT/hsl_dump.txt"
if ! "$BIN" "$DOC" "$OUT/hsl_edit.ppm" "$OUT/hsl_present.ppm" \
        "$OUT/hsl_title.ppm" "$OUT/hsl_picture.ppm" "$V1" >"$DUMP" 2>&1; then
    echo "[hamslides-host] FAIL: host harness exited non-zero"; tail -40 "$DUMP"; exit 1
fi

for f in edit present title picture; do
    if python3 scripts/ppm_to_png.py "$OUT/hsl_$f.ppm" "$OUT/hsl_$f.png" 2>"$OUT/hsl_png.log"; then
        echo "[hamslides-host] PASS rendered $OUT/hsl_$f.png"
    else
        echo "[hamslides-host] FAIL png conversion ($f)"; cat "$OUT/hsl_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamslides-host] PASS $2";
    else echo "[hamslides-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# Assert inside ONE named scene block (the harness brackets each render with
# <NAME>-SCENE-BEGIN/END), so layout-specific geometry is checked per layout.
scene() { sed -n "/^$1-SCENE-BEGIN\$/,/^$1-SCENE-END\$/p" "$DUMP"; }
assert_scene() {
    if scene "$1" | grep -Eq -- "$2"; then echo "[hamslides-host] PASS $3";
    else echo "[hamslides-host] FAIL $3 (missing in $1 scene: $2)"; fail=1; fi
}
refute_scene() {
    if scene "$1" | grep -Eq -- "$2"; then
        echo "[hamslides-host] FAIL $3 (unexpected in $1 scene: $2)"; fail=1;
    else echo "[hamslides-host] PASS $3"; fi
}

# --- window chrome: title bar, MENU BAR, toolbar, status bar ---------------
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 720 500 #e9ebf3'         "hamslides window background"
assert_grep '^fill 0 0 720 22 #2b2d5c'          "indigo title bar"
assert_grep 'glyphs .*"HamSlides"'              "app title label"
assert_grep 'glyphs .*"talk.hamslides"'         "filename shown in the title bar"
for m in File Edit Slide View; do
    assert_grep "glyphs [0-9]+ 26 \"$m\""       "menu bar carries $m"
done
for b in New Dup Del Up Dn Layout Theme Present Open Save; do
    assert_grep "glyphs [0-9]+ 52 \"$b\""       "toolbar button $b rendered"
done
assert_grep 'glyphs .*"2 / 3"'                  "slide counter (2 / 3) rendered"
assert_grep 'glyphs 10 480 "Slide 2/3   Layout: Two Column   Theme: Indigo"' \
                                                "status bar shows slide/layout/theme"
assert_grep 'glyphs .*"Speaker notes  \(Ctrl-E\)"' "speaker-notes strip rendered"

# --- LAYOUT really changes the rendered geometry ---------------------------
# Two Column: the 3rd/4th bullets are drawn in the RIGHT column (x >= 400);
# Title+Content: the SAME bullets are all in one column at x=200.
assert_scene TWOCOL  'glyphs 192 158 "Thumbnail rail"' \
                     "two-column: bullet 1 in the left column"
assert_scene TWOCOL  'glyphs 466 158 "Four colour themes"' \
                     "two-column: bullet 3 moved to the RIGHT column"
assert_scene CONTENT 'glyphs 200 158 "Thumbnail rail"' \
                     "title+content: bullet 1 in the single column"
assert_scene CONTENT 'glyphs 200 210 "Four colour themes"' \
                     "title+content: bullet 3 stays in the single column"
refute_scene CONTENT 'glyphs 466 [0-9]+ "Four colour themes"' \
                     "title+content has no right-hand column"
assert_scene PICTURE 'glyphs [0-9]+ [0-9]+ "Picture"' \
                     "picture layout draws the image placeholder caption"
assert_scene PICTURE 'glyphs 192 158 "Thumbnail rail"' \
                     "picture layout keeps the bullets in the left half"
assert_grep '^S2_LAYOUT 1'                      "Slide menu set slide 3 to the Title Slide layout"
assert_grep '^S2_LAYOUT_NAME Title Slide'       "layout name reported"
assert_grep '^S1_LAYOUT 2'                      "Slide menu set slide 2 to Two Column"
assert_grep '^MENU_OPEN 3'                      "Slide menu opens"
assert_grep '^MENU_OPEN_AFTER 0'                "picking an item closes the menu"

# --- MULTI-LEVEL bullets ---------------------------------------------------
assert_grep '^S0_NBUL 4'                        "slide 1 has four bullets"
assert_grep '^S0_B1_LVL 1'                      "Tab indented bullet 2 to level 1"
assert_grep '^S0_B2_LVL 2'                      "Tab indented bullet 3 to level 2"
assert_grep '^S0_B3_LVL 0'                      "Backspace outdented bullet 4 back to level 0"
assert_scene PRESENT 'glyphs 124 176 "Native presentation app"' \
                     "present: level-0 bullet at the base indent"
assert_scene PRESENT 'glyphs 148 214 "Multi-level bullets"' \
                     "present: level-1 bullet is indented further"
assert_scene PRESENT 'glyphs 172 252 "Tab indents, Backspace outdents"' \
                     "present: level-2 bullet is indented further still"

# --- speaker NOTES ---------------------------------------------------------
assert_grep '^S0_NOTES Remember to demo the thumbnail rail' \
                                                "Ctrl-E typed speaker notes into slide 1"
assert_grep '^FOCUS_AFTER_NOTES_CLICK 99'       "clicking the notes strip focuses the notes"
assert_grep '^FOCUS_AFTER_TITLE_CLICK 0'        "clicking the title band focuses the title"

# --- deck model: add / duplicate / delete / UNDO / reorder ------------------
assert_grep '^NSLIDES 3'                        "three slides after two Ctrl-N adds"
assert_grep '^CUR 2'                            "current slide is the newly-added slide 3"
assert_grep '^NSLIDES_AFTER_DUP 4'              "Ctrl-U duplicated a slide"
assert_grep '^DUP_TITLE Features'               "the duplicate carries the title"
assert_grep '^DUP_LAYOUT 2'                     "the duplicate carries the layout"
assert_grep '^NSLIDES_AFTER_DEL 3'              "Ctrl-D deleted the duplicate"
assert_grep '^NSLIDES_AFTER_UNDO 4'             "Ctrl-Z undid the delete"
assert_grep '^UNDO_TITLE Features'              "undo restored the slide contents"
assert_grep '^NSLIDES_FINAL 3'                  "deck back to three slides"
assert_grep '^MOVEUP_S0 Features'               "Ctrl-K moved slide 2 up to position 1"
assert_grep '^MOVEUP_S1 Welcome to HamSlides'   "the displaced slide moved down"
assert_grep '^MOVEUP_CUR 0'                     "the moved slide stays current"
assert_grep '^MOVEDN_S0 Welcome to HamSlides'   "Ctrl-L moved it back down"
assert_grep '^MOVEDN_S1 Features'               "deck order restored"

# --- THEME -----------------------------------------------------------------
assert_grep '^THEME 1'                          "Ctrl-T switched to theme 1"
assert_grep '^THEME_NAME Slate'                 "theme 1 is Slate"
assert_grep '^THEME1_TITLEBAR_PIX 2503224'      "Slate repaints the title bar (#263238)"
assert_grep '^THEME_WRAP 0'                     "Ctrl-T wraps back round to Indigo"
assert_grep '^PIX_TITLEBAR 2829660'             "Indigo title-bar pixel restored (#2b2d5c)"
assert_grep '^EDIT_VIEW 0'                      "EDIT view active for the first render"

# --- SAVE writes a HAMSLIDES2 container to disk ----------------------------
assert_grep '^FILE_LEN [1-9][0-9][0-9]'         "Ctrl-S wrote the document container (>=100 bytes)"

# --- CLEAR + RE-OPEN off disk: FULL round-trip proof ------------------------
assert_grep '^NSLIDES_AFTER_CLEAR 1'            "deck cleared to a single slide before reopen"
assert_grep '^NSLIDES_AFTER_OPEN 3'             "Ctrl-O reloaded all three slides off disk"
assert_grep '^S0_TITLE_RELOAD Welcome to HamSlides' "slide 1 title survived the round-trip"
assert_grep '^S0_B0_RELOAD Native presentation app' "slide 1 bullet survived the round-trip"
assert_grep '^S0_B1_LVL_RELOAD 1'               "bullet indent level 1 survived the round-trip"
assert_grep '^S0_B2_LVL_RELOAD 2'               "bullet indent level 2 survived the round-trip"
assert_grep '^S0_NOTES_RELOAD Remember to demo the thumbnail rail' \
                                                "speaker notes survived the round-trip"
assert_grep '^S1_TITLE_RELOAD Features'         "slide 2 title survived the round-trip"
assert_grep '^S1_LAYOUT_RELOAD 2'               "slide 2 Two-Column layout survived the round-trip"
assert_grep '^S1_NBUL_RELOAD 4'                 "slide 2 bullet count survived the round-trip"
assert_grep '^S2_TITLE_RELOAD Thank You'        "slide ORDER survived the round-trip"
assert_grep '^S2_LAYOUT_RELOAD 1'               "slide 3 Title-Slide layout survived the round-trip"
assert_grep '^THEME_RELOAD 0'                   "deck theme survived the round-trip"

# --- PRESENT view ----------------------------------------------------------
assert_grep '^PRESENT_VIEW 1'                   "toggled into PRESENT view"
assert_grep '^PRESENT_PIX 4477880'              "PRESENT accent title band pixel is the accent (#4453b8)"
assert_grep '^PRESENT_CUR_AFTER_SPACE 1'        "Space advanced the presentation to slide 2"
assert_grep '^PRESENT_CUR_AFTER_PGDN 2'         "PageDown (CSI 6~) advanced to slide 3"
assert_grep '^PRESENT_CUR_AFTER_HOME 0'         "Home (CSI H) jumped to the first slide"
assert_grep '^PRESENT_CUR_AFTER_END 2'          "End (CSI F) jumped to the last slide"
assert_grep '^PRESENT_NOTES 1'                  "'n' opened the speaker-notes overlay"
assert_grep '^PRESENT_BLACK 1'                  "'b' blanked the presentation screen"
assert_grep '^BLACK_PIX 0'                      "the blanked screen really renders black"
assert_grep '^PRESENT_BLACK_OFF 0'              "'b' again restores the slide"
assert_grep '^ESC_PENDING 1'                    "a bare ESC is held pending (arrow keys start with ESC)"
assert_grep '^VIEW_AFTER_ESC 0'                 "Esc resolved on idle exited PRESENT back to EDIT"
assert_scene TITLESLIDE 'glyphs [0-9]+ 172 "Thank You" #[0-9a-f]+ b' \
                        "title-slide layout centres the title, no accent band"
refute_scene TITLESLIDE '^fill 0 54 720 66' \
                        "title-slide layout drops the title band"
assert_scene TITLESLIDE 'glyphs [0-9]+ [0-9]+ "Speaker notes"' \
                        "present notes overlay drawn over the slide"
assert_scene PRESENT '^fill 0 54 720 66 #4453b8' \
                     "content layout keeps the accent title band in PRESENT"

# --- legacy HAMSLIDES1 documents still load --------------------------------
assert_grep '^V1_NSLIDES 2'                     "legacy HAMSLIDES1 deck loaded"
assert_grep '^V1_S0_TITLE Legacy Deck'          "legacy title parsed"
assert_grep '^V1_S0_B0 old format loads'        "legacy bullet parsed"
assert_grep '^V1_S1_TITLE Second v1'            "legacy second slide parsed"
assert_grep '^V1_S1_NBUL 1'                     "legacy bullet count parsed"
assert_grep '^V1_S0_LAYOUT 0'                   "legacy slides default to Title+Content"

# --- the document file really exists on disk with the magic ----------------
if [ -s "$DOC" ]; then echo "[hamslides-host] PASS $DOC written on disk";
else echo "[hamslides-host] FAIL document not written to $DOC"; fail=1; fi
if head -c 10 "$DOC" | grep -qx 'HAMSLIDES2'; then
    echo "[hamslides-host] PASS document carries the HAMSLIDES2 magic";
else echo "[hamslides-host] FAIL document missing HAMSLIDES2 magic"; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "[hamslides-host] OVERALL FAIL"; exit 1; fi
echo "[hamslides-host] OVERALL PASS"
