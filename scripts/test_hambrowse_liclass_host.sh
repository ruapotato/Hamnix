#!/usr/bin/env bash
# scripts/test_hambrowse_liclass_host.sh — FAST, QEMU-free gate for the round-13
# rung in the native browser engine (lib/htmlengine.ad): <li> elements now apply
# their OWN class/inline cascade (colour, text-decoration:line-through,
# font-weight, …) — matching how <p>/<blockquote> route through _open_style.
# Before this, the <li> handler bypassed _open_style, so a styled todo/nav item
# like `<li class="done">` rendered in the default colour with NO strike.
#
# The hazard this guards: real HTML routinely OMITS </li> (`<li>a<li>b<li>c`).
# The engine's scanner does not synthesise implicit closes, so a naive push-on-
# <li>/pop-on-</li> would LEAK the colour/deco style stack whenever </li> is
# absent, bleeding the last item's style onto following content. The fix
# synthesises an implicit </li> at the next <li> / </ul> / </ol> at that level,
# so the stack stays balanced. This gate proves BOTH:
#
#   (A) a properly-closed styled list: `<li class="done">` renders struck (s1)
#       in its class colour, a plain sibling <li> renders default (s0), and a
#       `<li class="warn">` renders bold in its colour — via SEG readback (the
#       strike/colour/weight FLAGS), not glyph ink.
#   (B) an UNCLOSED list `<ul><li>a<li>b<li>c</ul>` renders 3 correctly-styled
#       items on 3 distinct rows with NO style bleed into the following <p> — the
#       style-stack-leak guard.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a regression in either fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_liclass.html"
mkdir -p "$OUT"

echo "[hb-liclass] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/liclass_compile.log"; then
    echo "[hb-liclass] FAIL: host harness did not compile"; cat "$OUT/liclass_compile.log"; exit 1
fi
echo "[hb-liclass] PASS host harness compiled -> $BIN"

echo "[hb-liclass] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/liclass_native.log"; then
    echo "[hb-liclass] FAIL: native hambrowse did not compile"; cat "$OUT/liclass_native.log"; exit 1
fi
echo "[hb-liclass] PASS native hambrowse still compiles"

fail=0
D0="$OUT/liclass_run.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-liclass] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

# The text-run SEG line for the item whose text is exactly $1 (skip the '-'
# marker segment). Fields: SEG <row> <x> #rrggbb b<0|1> u<0|1> s<0|1> l.. bg..
seg_line() { grep -E "^SEG [0-9]+ [0-9]+ .*\|$1\|" "$D0" | head -1; }
seg_row()  { seg_line "$1" | awk '{print $2}'; }

grep -E '^SEG ' "$D0" || true

assert_seg() {  # text  regex  message
    local ln; ln="$(seg_line "$1")"
    if [ -z "$ln" ]; then
        echo "[hb-liclass] FAIL $3 (no segment for |$1|)"; fail=1; return
    fi
    if echo "$ln" | grep -Eq -- "$2"; then
        echo "[hb-liclass] PASS $3"
    else
        echo "[hb-liclass] FAIL $3 (seg: $ln)"; fail=1
    fi
}

# ---- (A) properly-closed styled list --------------------------------------
# `<li class="done">` : class colour #8a94a3 AND line-through (s1).
assert_seg "Struck" '#8a94a3 .* s1 '  ".done <li> renders its class colour AND strike (s1)"
# plain sibling <li> : default colour, NO strike (s0) — proves no bleed from the
# preceding styled item and that plain items are untouched.
assert_seg "Plainitem" ' s0 '                 "plain sibling <li> renders default (s0, no strike)"
assert_seg "Plainitem" '#101010'              "plain sibling <li> keeps the default colour (no bleed)"
# `<li class="warn">` : class colour #cc4400 AND bold (b1).
assert_seg "Urgent" '#cc4400 b1 '     ".warn <li> renders its class colour AND bold weight"

# ---- (B) UNCLOSED list: 3 styled items, no leak into following content -----
# `<ul><li class=done>Xone<li class=done>Xtwo<li class=done>Xthree</ul>` — every
# item struck + class-coloured even though </li> is omitted.
assert_seg "Xone"   '#8a94a3 .* s1 '  "unclosed <li> #1 still struck + class-coloured"
assert_seg "Xtwo"   '#8a94a3 .* s1 '  "unclosed <li> #2 still struck + class-coloured"
assert_seg "Xthree" '#8a94a3 .* s1 '  "unclosed <li> #3 still struck + class-coloured"
r1="$(seg_row Xone)"; r2="$(seg_row Xtwo)"; r3="$(seg_row Xthree)"
if [ -n "$r1" ] && [ -n "$r2" ] && [ -n "$r3" ] && \
   [ "$r2" -gt "$r1" ] && [ "$r3" -gt "$r2" ]; then
    echo "[hb-liclass] PASS unclosed <li>s stack on 3 distinct rows ($r1 < $r2 < $r3)"
else
    echo "[hb-liclass] FAIL unclosed <li>s did not stack (rows $r1 $r2 $r3)"; fail=1
fi
# THE LEAK GUARD: the <p> after the unclosed </ul> must be DEFAULT — no strike,
# not the .done grey. A style-stack leak would paint it #8a94a3 s1.
assert_seg "Trailer" ' s0 '                   "content after the unclosed list is NOT struck (no stack leak)"
assert_seg "Trailer" '#101010'                "content after the unclosed list keeps default colour (no leak)"

if [ "$fail" -ne 0 ]; then
    echo "[hb-liclass] RESULT: FAIL"; exit 1
fi
echo "[hb-liclass] RESULT: PASS"
