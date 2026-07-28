#!/usr/bin/env bash
# scripts/test_hambrowse_style_host.sh — FAST, QEMU-free gate for the
# element.style property API (browser campaign round 7). Real pages drive
# layout via JS inline style constantly (el.style.display='none',
# el.style.color='red', el.style.width='100px'). This gate proves the native
# engine (lib/htmlengine.ad) routes JS `.style` writes into the SAME inline-
# style store that `<div style="...">` uses, so they participate in the cascade
# at inline specificity and AFFECT THE RENDER:
#
#   - .style.display='none' removes the element from layout entirely
#   - .style.color beats a stylesheet class rule (inline specificity)
#   - .style.backgroundColor paints the element box (SEG bg + FILL readback)
#   - .style.fontWeight='bold' renders a bold segment
#   - .style.width getter returns exactly what was set AND constrains layout
#     (a short line wraps because the box is narrow)
#   - .style.cssText = 'a:x; b:y' parses a multi-declaration replace
#   - setAttribute('style','...') routes into the SAME store (no clobber);
#     getAttribute('style') serializes it back; an unset prop reads ''
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_style.html"
mkdir -p "$OUT"

echo "[hb-style] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/style_compile.log"; then
    echo "[hb-style] FAIL: host harness did not compile"; cat "$OUT/style_compile.log"; exit 1
fi
echo "[hb-style] PASS host harness compiled -> $BIN"

echo "[hb-style] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/style_native.log"; then
    echo "[hb-style] FAIL: native hambrowse did not compile"; cat "$OUT/style_native.log"; exit 1
fi
echo "[hb-style] PASS native hambrowse still compiles"

fail=0
D0="$OUT/style_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-style] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-style] PASS $2"
    else
        echo "[hb-style] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-style] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-style] PASS $2"
    fi
}

grep -E 'JSLOG|JSERR|SEG .*(WORD|BOX)|FILL' "$D0" || true

# ---- getters / cssText / setAttribute / getAttribute (DOM readback) -------
assert_grep '^JSLOG widget 120px$'                       ".style.width getter returns what was set (120px)"
assert_grep '^JSLOG csscol #33bbff csswt bold$'          "cssText parsed color + font-weight into routed props"
assert_grep '^JSLOG attrcol #7788aa attrwd 90px$'        "setAttribute('style') routes into the .style store"
assert_grep '^JSLOG attrget color:#7788aa;width:90px;$'  "getAttribute('style') serializes the .style store"
assert_grep '^JSLOG unset \[\]$'                         "unset .style.width getter returns '' "
assert_nogrep '^JSERR'                                   "no uncaught JS error across the style script"

# ---- RENDER REFLECTION ---------------------------------------------------
# display:none removes the element from layout entirely (no segment at all).
assert_nogrep 'HIDEME'   ".style.display='none' removes the element from the painted output"

# inline .style.color beats the .red stylesheet class (#111111) -> #ee2244.
assert_grep '^SEG .* #ee2244 .*\|COLORWORD'  ".style.color paints the recoloured region (SEG readback)"
assert_nogrep '#111111'                      "inline .style.color beats the stylesheet class rule (specificity)"

# backgroundColor paints the box: a per-segment bg AND a box FILL record.
assert_grep '^SEG .* bg#22cc66 .*\|BOXWORD'  ".style.backgroundColor sets the segment background"
assert_grep '^FILL .* #22cc66'               ".style.backgroundColor paints the element box (FILL)"

# fontWeight='bold' -> a bold segment (b1 flag, not a glyph-ink pixel).
assert_grep '^SEG .* b1 .*\|WEIGHTWORD'      ".style.fontWeight='bold' renders a bold segment"

# width constrains layout: "WIDTHBOX sized box" (3 short words) wraps because
# the box is only 120px wide; the remainder 'box' lands on its own segment.
assert_grep '^SEG .*\|WIDTHBOX sized\|'      ".style.width constrains the box (line wraps at the narrow width)"
assert_grep '^SEG .*\|box\|'                 ".style.width forced the remainder onto a new line"

if [ "$fail" -ne 0 ]; then
    echo "[hb-style] RESULT: FAIL"; exit 1
fi
echo "[hb-style] RESULT: PASS"
