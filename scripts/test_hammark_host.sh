#!/usr/bin/env bash
# scripts/test_hammark_host.sh — FAST, QEMU-free host gate for HamMark, the
# native Markdown viewer (lib/hammarkcore.ad composited into an RGBA backbuffer
# via lib/chrometext.ad). It drives the SAME core the native app ships with a
# KNOWN, injected markdown string so the run is deterministic, and asserts:
#   * the parsed BLOCK structure — heading / paragraph / unordered + ordered
#     list / fenced code / blockquote / hr land as the right block types,
#   * the rendered scene is non-blank with the expected ELEMENTS at expected
#     positions — an H1 painted LARGER (taller) than body text, list markers,
#     the code block's distinct background slab, the blockquote accent bar,
#   * the document is taller than the viewport and SCROLLING moves the content.
# It renders the view (and a scrolled view) to PNGs a human/agent can LOOK at,
# and confirms the NATIVE Hamnix build still compiles from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hammark_host"
mkdir -p "$OUT"
fail=0

echo "[hammark-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hammark_host.ad "$BIN" 2>"$OUT/hm_compile.log"; then
    echo "[hammark-host] FAIL: host harness did not compile"; cat "$OUT/hm_compile.log"; exit 1
fi
echo "[hammark-host] PASS host harness compiled -> $BIN"

echo "[hammark-host] compiling NATIVE hammark for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hammark.ad "$OUT/hammark_native.elf" 2>"$OUT/hm_native.log"; then
    echo "[hammark-host] FAIL: native hammark did not compile"; cat "$OUT/hm_native.log"; exit 1
fi
echo "[hammark-host] PASS native hammark still compiles"

DUMP="$OUT/hm_dump.txt"
if ! "$BIN" "$OUT/hm_view.ppm" "$OUT/hm_scrolled.ppm" >"$DUMP" 2>&1; then
    echo "[hammark-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in view scrolled; do
    if python3 scripts/ppm_to_png.py "$OUT/hm_$f.ppm" "$OUT/hm_$f.png" 2>"$OUT/hm_png.log"; then
        echo "[hammark-host] PASS rendered $OUT/hm_$f.png"
    else
        echo "[hammark-host] FAIL png conversion ($f)"; cat "$OUT/hm_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hammark-host] PASS $2";
    else echo "[hammark-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# helper: assert "KEY value" where value >= a threshold
assert_ge() {
    local key="$1" min="$2" msg="$3"
    local v
    v=$(grep -E "^$key " "$DUMP" | awk '{print $2}')
    if [ -n "$v" ] && [ "$v" -ge "$min" ]; then
        echo "[hammark-host] PASS $msg ($key=$v >= $min)"
    else
        echo "[hammark-host] FAIL $msg ($key=$v, want >= $min)"; fail=1
    fi
}

# --- parsed block structure -------------------------------------------------
assert_grep '^B0_TYPE 1'        "first block is a heading (MK_HEADING=1)"
assert_grep '^B0_LEVEL 1'       "first heading is level 1"
assert_grep '^B1_TYPE 2'        "second block is a paragraph (MK_PARA=2)"
assert_grep '^N_HEADING 2'      "two ATX headings parsed"
assert_grep '^N_UL 2'           "two unordered list items parsed"
assert_grep '^N_OL 2'           "two ordered list items parsed"
assert_grep '^N_CODE 2'         "two fenced-code lines parsed"
assert_grep '^N_QUOTE 1'        "one blockquote line parsed"
assert_grep '^N_HR 1'           "one horizontal rule parsed"
assert_ge   'N_PARA' 3          "several paragraphs parsed"

# --- render: heading LARGER than body, markers, code slab, quote bar --------
assert_ge   'HEAD_INK'  200     "the heading band has substantial ink"
assert_ge   'HEAD_ROWS' 18      "H1 glyphs span many rows (taller than a body line ~10px)"
assert_ge   'CODE_BG_Y' 1       "code block has its distinct background slab"
assert_ge   'QUOTE_BAR_Y' 1     "blockquote left accent bar rendered"
assert_ge   'BULLET_Y'  1       "list bullet marker rendered"

# --- scrollable + scrolling changes the viewport ----------------------------
# document taller than viewport
CH=$(grep -E '^CONTENT_H ' "$DUMP" | awk '{print $2}')
VH=$(grep -E '^VIEW_H ' "$DUMP" | awk '{print $2}')
if [ -n "$CH" ] && [ -n "$VH" ] && [ "$CH" -gt "$VH" ]; then
    echo "[hammark-host] PASS document taller than viewport (CONTENT_H=$CH > VIEW_H=$VH -> scrollable)"
else
    echo "[hammark-host] FAIL document not taller than viewport (CONTENT_H=$CH VIEW_H=$VH)"; fail=1
fi
assert_grep '^SCROLL0 0'        "starts scrolled to the top"
assert_ge   'SCROLL1' 1         "Space paged the document down"
assert_ge   'VIEW_CHANGED' 1    "the viewport ink changed after scrolling"
assert_grep '^SCROLL_TOP 0'     "'g' returned to the top of the document"

# --- the two PNGs really exist ----------------------------------------------
for f in view scrolled; do
    if [ -s "$OUT/hm_$f.png" ]; then echo "[hammark-host] PASS $OUT/hm_$f.png on disk";
    else echo "[hammark-host] FAIL $OUT/hm_$f.png not written"; fail=1; fi
done

if [ "$fail" -ne 0 ]; then echo "[hammark-host] OVERALL FAIL"; exit 1; fi
echo "[hammark-host] OVERALL PASS"
