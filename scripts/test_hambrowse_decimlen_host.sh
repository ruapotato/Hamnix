#!/usr/bin/env bash
# scripts/test_hambrowse_decimlen_host.sh — FAST, QEMU-free gate for FRACTIONAL
# / decimal CSS lengths in the native browser engine (lib/web/css/cascade.ad).
#
# The existing cssvalues gate covers rem/calc/var()/min-max-clamp with INTEGER
# operands only. This gate pins the fractional-precision path that nearly every
# modern design system depends on and that an integer-only length scanner
# silently truncates at the '.':
#
# Plain prose now spans the FULL viewport like Chrome (content column =
# 800-2*8 = 784px, boxes at x0=0); percentages resolve against 784.
#
#   * padding: 0.75rem  -> 12px  (0.75 * 16px root-em). A truncating scanner
#     reads 0rem -> padding 0, so the box TEXT would sit at x=8 (the bare content
#     margin) instead of x=20 (8 + 12px left padding), and the fill would be 24px
#     narrower (no left+right padding).
#   * width: 33.3%      -> a width strictly WIDER than an integer 33% (which
#     truncation would produce). Against 784: 33% -> ~275; 33.3% -> 277 (x1).
#   * width: 25.5%      -> a fractional percentage distinct from 25% (25.5% of
#     784 = 199.9 -> 215 x1; 25% would be 212).
#   * font-size:1.5rem / 1.5em -> 24px headings that parse (the host preview is
#     monospace and cannot depict glyph scaling — see feedback_host_preview_
#     monospace_lies — so size is proven by the pixel-accurate length math
#     above, not by glyph width; here we only assert the styled box renders).
#
# Rendered through the frozen Python seed compiler (no QEMU), and the native
# hambrowse target is also compiled so a break in either backend fails here.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_decimlen.html"
mkdir -p "$OUT"

echo "[hb-decimlen] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/decimlen_compile.log"; then
    echo "[hb-decimlen] FAIL: host harness did not compile"; cat "$OUT/decimlen_compile.log"; exit 1
fi
echo "[hb-decimlen] PASS host harness compiled -> $BIN"

DUMP="$OUT/decimlen_dump.txt"
if ! "$BIN" "$FIX" 800 >"$DUMP" 2>&1; then
    echo "[hb-decimlen] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^FILL|^SEG ' "$DUMP" | grep -Ei 'ffcc00|33aa33|2255aa|cc00cc|eeeeee' || true

fail=0
# STALE-ORIGIN RE-PIN (2026-07-27): the box LEFT column below moved from 0 to 8.
# Plain prose used to render inside a centred "readable measure" strip and the
# UA 8px body margin was not honoured, so every block fill started at x=0. The
# engine now lays the page out full-width from the real body margin, which is
# what Chrome does: `chromium --headless` reports getBoundingClientRect().x == 8
# for every block in this fixture. Only the LEFT column moved — every right edge
# below is unchanged, so each assertion still pins exactly the same computed
# width it always did.
assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-decimlen] PASS $msg"
    else
        echo "[hb-decimlen] FAIL $msg  (/$pat/)"; fail=1
    fi
}

# Layout produced content.
assert_grep 'LAYOUT segs=[1-9][0-9]* rows=[1-9][0-9]* ' "layout produced segments/rows"

# --- 0.75rem padding -> 12px (fractional rem) ------------------------
# Integer truncation reads 0rem: the box fill would be 216px wide (no padding)
# and the text would start at x=8, not x=20. The 240px fill (200 width + 24px
# horizontal padding + 16 chrome) and the text at x=20 (8 + 12px left padding)
# both prove the fractional 0.75rem resolved to 12px.
assert_grep '^FILL [0-9]+ [0-9]+ 8 240 #ffcc00'  "padding:0.75rem -> 12px (240px fill = 200 + 24 pad + 16, not 216)"
assert_grep '^SEG [0-9]+ 20 #[0-9a-f]+ b0 u0 s0 l-1 bg#ffcc00 .Padded 0.75rem box.' \
    "padding:0.75rem -> text at x=20 (8 + 12px left padding, not x=8)"

# --- 33.3% width -> right edge WIDER than an integer 33% --------------
# 33.3% of 784 = 261.1 -> 261px width -> x1 277 (33% -> ~259 -> x1 275).
assert_grep '^FILL [0-9]+ [0-9]+ 8 277 #33aa33'  "width:33.3% -> 277px right edge (33% would be 275)"

# --- 25.5% width -> a fractional percentage box ----------------------
# 25.5% of 784 = 199.9 -> 199px width -> x1 215 (25% -> 196 -> x1 212).
assert_grep '^FILL [0-9]+ [0-9]+ 8 215 #2255aa'  "width:25.5% -> 215px right edge (fractional %)"

# --- decimal em/rem font-size boxes render (value path exercised) ----
assert_grep '^SEG 0 8 #[0-9a-f]+ b1 u0 s0 l-1 bg#eeeeee .Heading at 1.5rem.' \
    "font-size:1.5rem heading renders (bold, tinted bg)"
assert_grep '^SEG [0-9]+ 8 #[0-9a-f]+ b0 u0 s0 l-1 bg#cc00cc .Text at 1.5em.' \
    "font-size:1.5em paragraph renders"

echo "[hb-decimlen] compiling native hambrowse for x86_64-adder-user (no regress) ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/decimlen_native.log"; then
    echo "[hb-decimlen] FAIL: native hambrowse did not compile"; cat "$OUT/decimlen_native.log"; exit 1
fi
echo "[hb-decimlen] PASS native hambrowse still compiles"

if [ "$fail" = 0 ]; then
    echo "[hb-decimlen] RESULT: PASS"; exit 0
else
    echo "[hb-decimlen] RESULT: FAIL"; exit 1
fi
