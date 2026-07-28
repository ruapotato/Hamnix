#!/usr/bin/env bash
# scripts/test_hamedit_syntax_host.sh — FAST, QEMU-free host gate for the
# scene-DE editor's SYNTAX HIGHLIGHTING (lib/hameditcore's per-row tokenizer +
# colored-glyph renderer, drawn through lib/hamscene + rasterized by
# lib/hamui_host). It renders a handful of sample source lines the way the
# native editor draws its body text (same hamedit_draw_row_syntax code path),
# writes a PNG a human/agent can LOOK at, and asserts BOTH the emitted scene
# ops (each token class in its color) AND the per-class rasterized-pixel counts
# (proof the colors reached the framebuffer). It also confirms the NATIVE
# Hamnix editor still compiles from the same core.
#
# Pass marker:  PASS: hamedit syntax highlight intact
# Fail marker:  FAIL: <which link broke>

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamedit_host"
mkdir -p "$OUT"
fail=0

echo "[edit-syntax] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hameditscene_host.ad "$BIN" 2>"$OUT/edit_compile.log"; then
    echo "[edit-syntax] FAIL: host harness did not compile"; cat "$OUT/edit_compile.log"; exit 1
fi
echo "[edit-syntax] PASS host harness compiled -> $BIN"

echo "[edit-syntax] compiling NATIVE hameditscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hameditscene.ad "$OUT/hamedit_native.elf" 2>"$OUT/edit_native.log"; then
    echo "[edit-syntax] FAIL: native hameditscene did not compile"; cat "$OUT/edit_native.log"; exit 1
fi
echo "[edit-syntax] PASS native hameditscene still compiles"

echo "[edit-syntax] running host harness ..."
DUMP="$OUT/edit_dump.txt"
PPM="$OUT/hamedit_syntax.ppm"
PNG="$OUT/hamedit_syntax.png"
if ! "$BIN" "$PPM" >"$DUMP" 2>&1; then
    echo "[edit-syntax] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/edit_png.log"; then
    echo "[edit-syntax] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[edit-syntax] FAIL png conversion"; cat "$OUT/edit_png.log"; fail=1
fi

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[edit-syntax] PASS $2";
    else echo "[edit-syntax] FAIL $2 (missing: $1)"; fail=1; fi
}

# --- scene / canvas / gutter -----------------------------------------------
assert_grep '^# scene v1 hamui'                       "scene header emitted"
assert_grep '^fill 0 0 400 160 #fbfbf7'               "editor canvas background"
assert_grep '^fill 0 18 30 142 #eceae2'               "line-number gutter band"
assert_grep '^line 30 18 30 160 1 #d2cfc4'            "gutter separator line"
assert_grep 'glyphs .*"1" #909088'                    "gutter line number 1"
assert_grep 'glyphs .*"5" #909088'                    "gutter line number 5"

# --- syntax coloring: each token class in its color ------------------------
assert_grep 'glyphs .*"# a comment line" #1a7f2a'     "comment -> green"
assert_grep 'glyphs .*"42" #1560bd'                   "decimal number -> blue"
assert_grep 'glyphs .*"0xdeadbeef" #1560bd'           "hex number -> blue"
assert_grep 'glyphs .*"3.14" #1560bd'                 "float number -> blue"
assert_grep 'glyphs .*"count = " #101010'             "plain code -> default near-black"
assert_grep 'glyphs .*"plain body text" #101010'      "plain line -> default near-black"
# The string literal keeps its span colored orange (the scene layer sanitizes a
# literal double-quote to a space, a pre-existing hamscene behavior, so match
# the inner text rather than the quote glyphs).
assert_grep 'glyphs .*hello.* #b5651d'                "string literal -> orange"

# --- rasterized-pixel proof (colors actually reached the framebuffer) ------
assert_pos() {
    v="$(grep -oE "^$1 [0-9]+" "$DUMP" | grep -oE '[0-9]+$' | head -1)"
    if [ -n "$v" ] && [ "$v" -gt 0 ]; then echo "[edit-syntax] PASS $1=$v (>0)";
    else echo "[edit-syntax] FAIL $1 not positive (got '${v:-none}')"; fail=1; fi
}
assert_pos GREENPIX
assert_pos ORANGEPIX
assert_pos BLUEPIX

if [ "$fail" = "0" ]; then
    echo "PASS: hamedit syntax highlight intact"
    exit 0
fi
echo "FAIL: hamedit syntax highlight regressed" >&2
exit 1
