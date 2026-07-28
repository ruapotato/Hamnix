#!/usr/bin/env bash
# scripts/test_filepick_host.sh — FAST, QEMU-free host gate for the SHARED
# Save/Open dialog (lib/filepick.ad) that every office app now raises.
#
# The user's report was that each app had its own ad-hoc filename prompt:
#
#   "they all need a way to save as, using the same pathway as the text editor
#    / all apps use some kind of similar path so that each save window is like
#    a GTK save window and based on the file browser."
#
# So there is now ONE dialog component, and it is genuinely backed by the file
# BROWSER: lib/filepick.ad is a thin chooser shell over lib/hamfmcore.ad, the
# same directory model / dir-walk / sort / icon-grid paint / hit-test that
# user/hamfmscene.ad (the file manager) itself runs on. HamWrite, HamSheet,
# HamSlides and hamedit all raise this one component, so the Save window is
# identical everywhere.
#
# This gate drives the SHIPPING component through a full Save-As and Open
# session and asserts that the model and the RENDER agree:
#
#   1. the centred floating PANEL draws over a live document — scrim, drop
#      shadow, "Save As" / "Open File" title bar, the shared browse grid inside
#      it, the Name entry and the Save/Cancel buttons;
#   2. it is a real MODAL: points inside it belong to the dialog, points
#      outside do not, so a click can never leak onto the document beneath;
#   3. NAVIGATION runs through the browse core — a folder cell selects on the
#      first click and DESCENDS on the second, and the breadcrumb follows;
#   4. the filename ENTRY takes typed keys and Backspace;
#   5. the Save/Cancel BUTTONS are live click targets (they used to be painted
#      decoration: filepick_click only forwarded to fmc_cell_at, which reports
#      -1 inside the reserved bottom strip, so they could not be clicked);
#   6. OVERWRITE is surfaced — typing the name of a file that already exists
#      in the listing raises a "replaces existing file" warning;
#   7. SAVE composes <browsed dir>/<typed name> as an ABSOLUTE path, so the
#      user can save ANYWHERE instead of into one hard-coded directory;
#   8. OPEN returns the picked file's full path;
#   9. Cancel and Esc dismiss WITHOUT producing a result;
#  10. the full-window renderer (user/hameditscene.ad's existing path) still
#      paints from the window origin after the panel has moved it.
#
# Two PNGs a human/agent can LOOK at are produced:
#   build/host/fp_save.png  — the Save dialog over a document, mid-overwrite
#   build/host/fp_open.png  — the dialog over a second app
#
# Directory ENUMERATION is a kernel path the dev host cannot run, so the
# listing is injected with the browse core's own model primitives
# (fmc_model_reset / fmc_add_entry / fmc_sort_entries) — the exact records
# fmc_load_dir yields on-device — and everything downstream is the real code.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="build/host"
BIN="$OUT/filepick_host"
mkdir -p "$OUT"
fail=0

echo "[filepick-host] compiling the shared dialog + harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/filepick_host.ad "$BIN" 2>"$OUT/fp_compile.log"; then
    echo "[filepick-host] FAIL: host harness did not compile"
    cat "$OUT/fp_compile.log"; exit 1
fi
echo "[filepick-host] PASS host harness compiled -> $BIN"

# The dialog must stay usable by the apps that raise it natively.
for app in hamwrite hamsheet hamslides hameditscene; do
    if python3 -m compiler.adder compile --target=x86_64-adder-user \
            "user/$app.ad" -o "$OUT/${app}_dlg.elf" 2>"$OUT/fp_${app}.log"; then
        echo "[filepick-host] PASS native $app still compiles against the dialog"
    else
        echo "[filepick-host] FAIL native $app did not compile"
        cat "$OUT/fp_${app}.log"; fail=1
    fi
done

DUMP="$OUT/fp_dump.txt"
if ! "$BIN" "$OUT/fp_save.ppm" "$OUT/fp_open.ppm" >"$DUMP" 2>&1; then
    echo "[filepick-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in save open; do
    if python3 scripts/ppm_to_png.py "$OUT/fp_$f.ppm" "$OUT/fp_$f.png" \
            2>"$OUT/fp_png.log"; then
        echo "[filepick-host] PASS rendered $OUT/fp_$f.png"
    else
        echo "[filepick-host] FAIL png conversion ($f)"; cat "$OUT/fp_png.log"
        fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[filepick-host] PASS $2";
    else echo "[filepick-host] FAIL $2 (missing: $1)"; fail=1; fi
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
    local body; body="$(section "$1")"
    if printf '%s\n' "$body" | grep -Eq -- "$2"; then
        echo "[filepick-host] PASS $3"
    else
        echo "[filepick-host] FAIL $3 (missing in $1: $2)"; fail=1
    fi
}

# --- (1) the dialog opens in SAVE mode, seeded ------------------------------
assert_grep '^ACTIVE 2'                     "the dialog opens in SAVE mode"
assert_grep '^SEEDNAME report.hdoc'         "SAVE mode pre-fills the caller's filename"

# --- (2) it is a CENTRED FLOATING panel, and it is MODAL --------------------
assert_grep '^PANEL 85 80 470 320'          "the dialog is a centred floating panel, not full-window"
assert_grep '^OWNS_CENTER 1'                "a click in the panel belongs to the dialog"
assert_grep '^OWNS_CORNER 0'                "a click outside the panel does NOT belong to the dialog"

# --- (3) the panel CHROME: a GTK-shaped save window -------------------------
assert_in SAVEPANEL 'glyphs [0-9]+ [0-9]+ \"Save As\" #ffffff b' \
                                            "panel draws a bold \"Save As\" title bar"
assert_in SAVEPANEL 'glyphs [0-9]+ [0-9]+ \"Save in: /home/live/Documents \([0-9]+\)\"' \
                                            "panel draws the file-browser breadcrumb + item count"
assert_in SAVEPANEL 'glyphs [0-9]+ [0-9]+ \"Name: report.hdoc_\"' \
                                            "panel draws the Name entry with a caret"
assert_in SAVEPANEL 'glyphs [0-9]+ [0-9]+ \"Save\"'   "panel draws the Save button"
assert_in SAVEPANEL 'glyphs [0-9]+ [0-9]+ \"Cancel\"' "panel draws the Cancel button"
assert_in SAVEPANEL 'fill 0 0 640 480 #00000033'      "panel dims the document behind it (modal scrim)"

# --- (4) it is backed by the REAL FILE BROWSER ------------------------------
# Folder + file icons and the dirs-first sort come from lib/hamfmcore.ad, the
# same core user/hamfmscene.ad paints with.
assert_in SAVEPANEL 'glyphs [0-9]+ [0-9]+ \"Archive\"' "the browse grid lists a directory"
assert_in SAVEPANEL 'glyphs [0-9]+ [0-9]+ \"Reports\"' "the browse grid lists a second directory"
assert_in SAVEPANEL 'glyphs [0-9]+ [0-9]+ \"\.\./\"'   "the browse grid offers the parent row"
# The gold folder body (#e8b94e) is hamscene_icon_folder's own colour: the
# dialog is painting the file manager's REAL icons, not a bespoke list widget.
assert_in SAVEPANEL 'fill [0-9]+ [0-9]+ [0-9]+ [0-9]+ #e8b94e' \
                                            "the browse grid draws the file manager's folder icons"
assert_in SAVEPANEL 'fill [0-9]+ [0-9]+ [0-9]+ [0-9]+ #f6f5f3' \
                                            "the browse grid paints the file-manager canvas"

# --- (5) NAVIGATION through the browse core ---------------------------------
assert_grep '^REPORTS_IDX 2'                "the listing sorted dirs-first (.., Archive, Reports)"
assert_grep '^SEL_AFTER_CLICK 2'            "one click SELECTS a folder cell"
assert_grep '^CWD_AFTER_ENTER /home/live/Documents/Reports' \
                                            "a second click DESCENDS into the folder"

# --- (6) the filename ENTRY -------------------------------------------------
assert_grep '^NAME_CLEARED 0'               "Backspace clears the Name field"
assert_grep '^TYPED q3.hdoc'                "the Name field accepts typed characters"

# --- (7) OVERWRITE awareness ------------------------------------------------
assert_grep '^OVERWRITE_NEW 0'              "a brand-new filename is not flagged as an overwrite"
assert_grep '^OVERWRITE_EXISTING 1'         "an EXISTING filename is flagged as an overwrite"
assert_in OVERWRITEPANEL 'glyphs [0-9]+ [0-9]+ \"replaces existing file\"' \
                                            "the overwrite warning is drawn in the dialog"

# --- (8) the SAVE BUTTON commits an ABSOLUTE path ---------------------------
assert_grep '^SAVE_RESULT 1'                "clicking Save committed a pick"
assert_grep '^SAVE_MODE 2'                  "the pick came back tagged SAVE"
assert_grep '^SAVE_PATH /home/live/Documents/Reports/q3.hdoc' \
                                            "Save composes <browsed dir>/<typed name>"
assert_grep '^CLOSED_AFTER_SAVE 0'          "the dialog closes once it has committed"

# --- (9) OPEN mode ----------------------------------------------------------
assert_in OPENPANEL 'glyphs [0-9]+ [0-9]+ \"Open File\" #ffffff b' \
                                            "OPEN mode draws an \"Open File\" title bar"
assert_in OPENPANEL 'glyphs [0-9]+ [0-9]+ \"Open\"'  "OPEN mode's commit button reads \"Open\""
assert_in OPENPANEL 'glyphs [0-9]+ [0-9]+ \"Open: /home/live/Documents \([0-9]+\)\"' \
                                            "OPEN mode's breadcrumb reads \"Open:\""
assert_grep '^OPEN_RESULT 1'                "double-clicking a file committed an OPEN pick"
assert_grep '^OPEN_MODE 1'                  "the pick came back tagged OPEN"
assert_grep '^OPEN_PATH /home/live/Documents/deck.hamslides' \
                                            "OPEN returns the picked file's full path"

# --- (10) CANCEL paths produce NO result ------------------------------------
assert_grep '^CANCEL_BTN_CLOSED 0'          "the Cancel button dismisses the dialog"
assert_grep '^CANCEL_NO_RESULT 0'           "Cancel produces no pick for the host to act on"
assert_grep '^ESC_CLOSED 0'                 "Esc dismisses the dialog"

# --- (11) the full-window renderer still works ------------------------------
# user/hameditscene.ad draws the picker full-window; the panel's paint origin
# must not leak into it.
assert_in FULLWIN 'glyphs 4 4 \"Open: /home/live/Documents \([0-9]+\)\"' \
                                            "full-window mode still paints from the window origin"
assert_grep '^FULLWIN_OWNS_CORNER 1'        "full-window mode owns the whole canvas"

# --- (12) the dialog itself does NO file I/O --------------------------------
# It RESOLVES a path; the host performs the open/save. That separation is what
# lets the same component serve four apps with different container formats.
if grep -Eq 'sys_open_write|sys_write|sys_unlink' lib/filepick.ad; then
    echo "[filepick-host] FAIL the shared dialog must not perform file I/O"; fail=1
else
    echo "[filepick-host] PASS the shared dialog performs no file I/O itself"
fi

# --- (13) every office app really does route through the ONE component ------
for app in hamwrite hamsheet hamslides; do
    if grep -q 'from lib.filepick import' "user/$app.ad"; then
        echo "[filepick-host] PASS $app raises the SHARED dialog"
    else
        echo "[filepick-host] FAIL $app does not import lib/filepick.ad"; fail=1
    fi
    if grep -Eq 'filepick_emit_panel' "user/$app.ad"; then
        echo "[filepick-host] PASS $app renders it as the centred panel"
    else
        echo "[filepick-host] FAIL $app does not render the shared panel"; fail=1
    fi
done
if grep -q 'from lib.filepick import' user/hameditscene.ad; then
    echo "[filepick-host] PASS hamedit raises the SHARED dialog"
else
    echo "[filepick-host] FAIL hamedit does not import lib/filepick.ad"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[filepick-host] OVERALL PASS"; exit 0
else
    echo "[filepick-host] OVERALL FAIL"; exit 1
fi
