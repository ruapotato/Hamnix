#!/usr/bin/env bash
# scripts/test_hambrowse_flexmin_host.sh — FAST, QEMU-free gate for the flex
# item MIN-CONTENT floor in the native browser engine (lib/htmlengine.ad).
#
# THE BUG (round-11 audit finding #8): flex items over-shrank and SPLIT WORDS.
# A `display:flex; justify-content:space-between` bar sizes each child's track
# to the child's CONTENT width — but that width was estimated on the CELL_W
# monospace grid at container-open. Under the PROPORTIONAL measure hook (the
# real device / the gfx render driver) a bold/large brand word is far wider than
# the monospace estimate, so its track was too narrow and _emit_word HARD
# char-broke the word across two rows: the brand "Nimbostratus" rendered as
# "Nimbos"/"tratus" and the link "Log in" wrapped between its words. Nearly every
# real site has a flex nav/header bar, so this garbled brand + nav labels.
#
# THE FIX: a flex item's CSS automatic minimum size is min-content, so its track
# must never shrink below its widest unbreakable word — a word wider than the
# track stays INTACT (overflows the track) instead of splitting mid-run. And a
# natural-path (content-sized) item is treated as white-space:nowrap so a
# two-word link stays on one line. See lib/htmlengine.ad _emit_word.
#
# This gate renders with the PROPORTIONAL gfx driver (user/hambrowse_host_gfx.ad)
# — the plain monospace host harness cannot exhibit the bug (its measure == its
# render). It asserts, via SEGTXT readback, that the brand word and the nav link
# each land as ONE segment (one row), never split. Builds BOTH targets so a break
# in either the host harness or the native browser is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_flexmin.html"
DUMP="$OUT/flexmin.txt"
PPM="$OUT/flexmin.ppm"
mkdir -p "$OUT"

echo "[hb-flexmin] compiling gfx driver for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/flexmin_compile.log"; then
    echo "[hb-flexmin] FAIL: gfx driver did not compile"; cat "$OUT/flexmin_compile.log"; exit 1
fi
echo "[hb-flexmin] PASS gfx driver compiled -> $BIN"

echo "[hb-flexmin] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/flexmin_native.log"; then
    echo "[hb-flexmin] FAIL: native hambrowse did not compile"; cat "$OUT/flexmin_native.log"; exit 1
fi
echo "[hb-flexmin] PASS native hambrowse still compiles"

fail=0
# Render at a CONSTRAINED width so the flex bar really is tight around its
# variable-width children (the condition that used to over-shrink the tracks).
if ! "$BIN" "$FIX" "$PPM" 400 >"$DUMP" 2>&1; then
    echo "[hb-flexmin] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi

# (1) the bold brand word is ONE unbroken segment — never split mid-word.
NBRAND=$(grep -c '^SEGTXT Nimbostratus$' "$DUMP")
if [ "$NBRAND" -eq 1 ]; then
    echo "[hb-flexmin] PASS brand 'Nimbostratus' stayed on one line (min-content floor)"
else
    echo "[hb-flexmin] FAIL brand word split by flex shrink (SEGTXT Nimbostratus count=$NBRAND)"
    grep -E '^SEGTXT' "$DUMP" | head; fail=1
fi

# (2) no mid-word fragment of the brand leaked onto its own segment.
if grep -Eq '^SEGTXT (Nimbos|tratus|Nimbo|stratus)$' "$DUMP"; then
    echo "[hb-flexmin] FAIL brand word fragment present (mid-word char-break)"; fail=1
else
    echo "[hb-flexmin] PASS no brand-word fragment segment"
fi

# (3) the two-word nav link stays on one line (content-sized track = nowrap).
if grep -Eq '^SEGTXT +Log in$' "$DUMP"; then
    echo "[hb-flexmin] PASS nav link 'Log in' stayed on one line"
else
    echo "[hb-flexmin] FAIL nav link 'Log in' wrapped between words"
    grep -E '^SEGTXT' "$DUMP" | head; fail=1
fi

# (4) the whole bar still fits on a single text row (no spurious extra rows from
#     a mid-word break) and does not overflow the viewport.
ROWS=$(awk '$1=="REFLOW"{for(i=1;i<=NF;i++) if($i=="textrows") print $(i+1)}' "$DUMP")
OVER=$(awk '$1=="REFLOW"{for(i=1;i<=NF;i++) if($i=="overflow") print $(i+1)}' "$DUMP")
if [ "${ROWS:-9}" = "1" ] && [ "${OVER:-1}" = "0" ]; then
    echo "[hb-flexmin] PASS flex bar is a single text row, no overflow (rows=$ROWS overflow=$OVER)"
else
    echo "[hb-flexmin] FAIL bar not single-row/clean (textrows=$ROWS overflow=$OVER)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-flexmin] RESULT: PASS"
else
    echo "[hb-flexmin] RESULT: FAIL"; exit 1
fi
