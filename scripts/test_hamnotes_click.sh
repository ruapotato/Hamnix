#!/usr/bin/env bash
# scripts/test_hamnotes_click.sh — FAST, QEMU-free host gate for the #315
# click-to-position + selection propagation into the Notes app. It drives the
# SAME hit-test the compositor feeds pointer events into (hamnotes_hit /
# hamnotes_drag) at pixels computed from the PROPORTIONAL glyph advances and
# asserts the caret lands on the clicked glyph (title AND the word-wrapped body)
# instead of the buffer end — the user-reported "cursor doesn't move until you
# type" bug — and that a click-drag builds the right selection range. Two PNGs a
# human/agent can LOOK at are produced (title mid-caret, body selection band).
# Also confirms the NATIVE Notes driver (which does the Ctrl+C/V /dev/snarf I/O)
# still compiles for x86_64-adder-user.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamnotes_click"
mkdir -p "$OUT"
fail=0

echo "[notes-click] compiling host click/selection gate (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamnotes_click_host.ad "$BIN" 2>"$OUT/notes_click_compile.log"; then
    echo "[notes-click] FAIL: host harness did not compile"
    cat "$OUT/notes_click_compile.log"; exit 1
fi
echo "[notes-click] PASS host harness compiled"

echo "[notes-click] compiling NATIVE hamnotesscene (Ctrl+C/V driver) ..."
if ! adder_bin x86_64-adder-user user/hamnotesscene.ad "$OUT/hamnotes_native.elf" 2>"$OUT/notes_click_native.log"; then
    echo "[notes-click] FAIL: native hamnotesscene did not compile"
    cat "$OUT/notes_click_native.log"; exit 1
fi
echo "[notes-click] PASS native hamnotesscene still compiles"

DUMP="$OUT/notes_click_dump.txt"
if ! "$BIN" "$OUT/notes_click_title.ppm" "$OUT/notes_click_body.ppm" >"$DUMP" 2>&1; then
    echo "[notes-click] host gate reported failures:"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

if ! grep -q "^\[notes-click\] RESULT PASS" "$DUMP"; then
    echo "[notes-click] FAIL: RESULT PASS marker missing"; fail=1
fi
if grep -q "^FAIL " "$DUMP"; then
    echo "[notes-click] FAIL: an assertion failed"; fail=1
fi

for f in title body; do
    if python3 scripts/ppm_to_png.py "$OUT/notes_click_$f.ppm" \
            "$OUT/notes_click_$f.png" 2>"$OUT/notes_click_png.log"; then
        echo "[notes-click] PASS rendered $OUT/notes_click_$f.png"
    else
        echo "[notes-click] FAIL png conversion ($f)"; cat "$OUT/notes_click_png.log"; fail=1
    fi
done

if [ "$fail" -ne 0 ]; then echo "[notes-click] OVERALL FAIL"; exit 1; fi
echo "[notes-click] OVERALL PASS"
