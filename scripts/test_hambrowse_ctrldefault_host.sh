#!/usr/bin/env bash
# scripts/test_hambrowse_ctrldefault_host.sh — FAST, QEMU-free gate for the UA
# DEFAULT SIZING of unstyled form controls in the native browser engine
# (lib/web/dom/forms.ad). This is the "the search box is a tiny box I can't click
# into" fix: an <input>/<textarea> with NO CSS width/height and NO size/cols/rows
# attribute must render at the UA default (Chrome/Firefox parity), not a
# content-hugging 8-cell / single-row sliver.
#
#   UA defaults (HTML spec + Chrome/Firefox):
#     <input type=text/search/...>     size=20  -> a 20-avg-char-wide field box
#     <textarea>                       cols=20, rows=2 -> 20 wide x 2 rows tall
#   Explicit attributes still win:
#     <input size=10>                  -> 10 cells
#     <textarea cols=30 rows=4>        -> 30 wide x 4 rows tall
#
# BEFORE this fix the engine padded every unstyled text field to just 8 cells and
# every textarea to 8 cells x 1 row — a ~64px sliver the user could not reliably
# click. Measured against `chromium --headless`, google.com's <textarea name=q>
# (cols=20, rows=2) is 182x36px; the engine now renders it 182px wide x 2 rows,
# matching Chrome. This gate pins the default so a regression back to the tiny
# box fails here without a QEMU boot.
#
# Two oracles:
#   * the TEXT harness (x86_64-linux) — inner field-cell count from the SEG dump;
#   * the PIXEL backend (x86_64-linux) — the SEGCTRL <kind> <appear> <rows> line
#     gives the ENGINE-resolved control height in text rows.
# The native browser (x86_64-adder-user) is also rebuilt so a regression in
# either target fails here.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_host_gfx"
FIX="tests/fixtures/hambrowse_ctrldefault.html"
mkdir -p "$OUT"
fail=0

echo "[hb-ctrldef] compiling text harness (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/ctrldef_host.log"; then
    echo "[hb-ctrldef] FAIL: text harness did not compile"; cat "$OUT/ctrldef_host.log"; exit 1
fi
echo "[hb-ctrldef] PASS text harness compiled"

echo "[hb-ctrldef] compiling pixel backend (x86_64-linux) ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/ctrldef_gfx.log"; then
    echo "[hb-ctrldef] FAIL: pixel backend did not compile"; cat "$OUT/ctrldef_gfx.log"; exit 1
fi
echo "[hb-ctrldef] PASS pixel backend compiled"

echo "[hb-ctrldef] confirming NATIVE hambrowse still compiles (x86_64-adder-user) ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/ctrldef_native.elf" 2>"$OUT/ctrldef_native.log"; then
    echo "[hb-ctrldef] FAIL: native hambrowse did not compile"; cat "$OUT/ctrldef_native.log"; exit 1
fi
echo "[hb-ctrldef] PASS native hambrowse still compiles"

check() { # label actual expect
    if [ "$2" -ne "$3" ]; then echo "[hb-ctrldef] FAIL: $1 — got $2 want $3"; fail=1;
    else echo "[hb-ctrldef] PASS: $1 ($2)"; fi
}

# ---- (1) TEXT harness: inner field-cell count for each control run ----------
D="$OUT/ctrldef.txt"
"$BIN" "$FIX" 900 >"$D" 2>&1 || { echo "[hb-ctrldef] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# Nth (1-based) field-run '[....]' inner char count from the SEG dump.
inner() { # nth
    grep -oE '\[_[^]]*\]|\[[^]]*_\]' "$D" | sed -n "${1}p" \
        | sed 's/^\[//;s/\]$//' | tr -d '\n' | wc -c
}
i1=$(inner 1); i2=$(inner 2); i3=$(inner 3); i4=$(inner 4); i5=$(inner 5)
echo "[hb-ctrldef] inner cells: input=$i1 search=$i2 input_size10=$i3 textarea=$i4 textarea_cols30=$i5"
check "unstyled <input type=text> = 20 cells (UA size=20)"   "$i1" 20
check "unstyled <input type=search> = 20 cells"              "$i2" 20
check "<input size=10> honours size -> 10 cells"             "$i3" 10
check "unstyled <textarea> = 20 cols (UA default)"           "$i4" 20
check "<textarea cols=30> honours cols -> 30 cells"          "$i5" 30

# ---- (2) PIXEL backend: control height in rows (SEGCTRL <kind> <appear> <rows>)
DG="$OUT/ctrldef_gfx.txt"
"$GFX" "$FIX" "$OUT/ctrldef.ppm" 900 >"$DG" 2>&1 \
    || { echo "[hb-ctrldef] FAIL: pixel render exited non-zero"; cat "$DG"; exit 1; }
# rows field of the Nth SEGCTRL line.
rows() { grep -E "^SEGCTRL " "$DG" | sed -n "${1}p" | awk '{print $4}'; }
# SEGCTRL order follows the controls: 1-3 = the three inputs (single row),
# 4 = the default <textarea>, 5 = the <textarea rows=4>.
r4=$(rows 4); r5=$(rows 5)
echo "[hb-ctrldef] textarea rows: default=$r4 rows4=$r5"
check "unstyled <textarea> defaults to 2 rows tall"          "$r4" 2
check "<textarea rows=4> honours rows -> 4 rows tall"        "$r5" 4

if [ "$fail" -ne 0 ]; then echo "[hb-ctrldef] RESULT: FAIL"; exit 1; fi
echo "[hb-ctrldef] RESULT: PASS — unstyled controls render at UA default sizes (clickable)"
