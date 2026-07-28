#!/usr/bin/env bash
# scripts/test_hambrowse_attrsel_host.sh — FAST, QEMU-free gate for CSS
# ATTRIBUTE SELECTORS in the native browser cascade (lib/web/css/cascade.ad).
# This is the single listed css-selectors gap ("attribute selectors in the CSS
# cascade"): before this, _parse_compound skipped brackets entirely, so every
# `[attr]` / `[attr=v]` rule was silently dropped. Real component/design-system
# CSS leans on `input[type=...]`, `a[target]`, `[data-*]`, `[lang|=en]`, so a
# regression must fail here without a QEMU boot. It proves all seven forms plus
# specificity ranking and ancestor-attribute descendant matching:
#
#   [attr]    exists          — a[data-active]      -> bg fill
#   [attr=v]  exact           — div[data-role=hero] -> #445566
#   [attr~=v] whitespace list — p[data-tags~=news]  -> red (only on a real token)
#   [attr^=v] prefix          — div[data-x^=abc]    -> #00aa00
#   [attr$=v] suffix          — div[data-y$=zzz]    -> #0000ff
#   [attr*=v] substring       — div[data-z*=mid]    -> #aa00aa
#   [attr|=v] dash-match      — p[lang|=en]         -> teal on en-US, not on fr
#   specificity — div[data-role=card] (011) beats .card (010)
#   descendant  — section[data-theme=dark] span (ancestor attribute)
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either backend is caught with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_attrsel.html"
mkdir -p "$OUT"

echo "[hb-attrsel] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/attrsel_compile.log"; then
    echo "[hb-attrsel] FAIL: host harness did not compile"; cat "$OUT/attrsel_compile.log"; exit 1
fi
echo "[hb-attrsel] PASS host harness compiled -> $BIN"

echo "[hb-attrsel] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/attrsel_native.log"; then
    echo "[hb-attrsel] FAIL: native hambrowse did not compile"; cat "$OUT/attrsel_native.log"; exit 1
fi
echo "[hb-attrsel] PASS native hambrowse still compiles"

fail=0
D0="$OUT/attrsel_run.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-attrsel] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E '^FILL|^SEG' "$D0" || true

# seg line whose text is exactly |$1|
seg_line() { grep -E "^SEG [0-9]+ [0-9]+ .*\|$1\|" "$D0" | head -1; }

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-attrsel] PASS $2"
    else
        echo "[hb-attrsel] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_seg() {    # text  regex  message
    local ln; ln="$(seg_line "$1")"
    if [ -z "$ln" ]; then
        echo "[hb-attrsel] FAIL $3 (no segment for |$1|)"; fail=1; return
    fi
    if echo "$ln" | grep -Eq -- "$2"; then
        echo "[hb-attrsel] PASS $3"
    else
        echo "[hb-attrsel] FAIL $3 (seg: $ln)"; fail=1
    fi
}

# [attr] exists — active link gets the bg, the plain sibling link does NOT.
assert_seg "active link"     'bg#112233' "[data-active] exists selector fills the bg"
assert_seg " plain link no bg" 'bg- '     "link without the attribute is NOT matched"

# [attr=v] exact — hero fills #445566; data-role=other gets nothing.
assert_grep 'FILL 1 2 8 800 #445566'   "[data-role=hero] exact match fills #445566"
assert_seg "other box no bg" 'bg- '       "[data-role=hero] does not match data-role=other"

# [attr~=v] whitespace token — a real token matches, a substring does NOT.
assert_seg "tagged para red"      '#ff0000' "[data-tags~=news] matches the 'news' token -> red"
assert_seg "not tokenized para"   '#101010' "[data-tags~=news] does NOT match inside 'sportsnews'"

# [attr^=v] prefix — abcdef matches, xabc does not.
assert_grep 'FILL 7 8 8 800 #00aa00'   "[data-x^=abc] prefix match fills #00aa00"
assert_seg "no prefix box" 'bg- '          "[data-x^=abc] does not match a non-prefix"

# [attr$=v] suffix / [attr*=v] substring.
assert_grep 'FILL 9 10 8 800 #0000ff'  "[data-y\$=zzz] suffix match fills #0000ff"
assert_grep 'FILL 10 11 8 800 #aa00aa'  "[data-z*=mid] substring match fills #aa00aa"

# [attr|=v] dash-match — en-US matches, fr does not.
assert_seg "english dashmatch teal" '#008080' "[lang|=en] matches en-US -> teal"
assert_seg "french no color"        '#101010' "[lang|=en] does NOT match lang=fr"

# specificity — div[data-role=card] (0,1,1) beats .card (0,1,0): box is #123456,
# NOT the plain-class #eeeeee.
assert_grep 'FILL 15 16 8 800 #123456'  "tag+attr specificity (011) beats bare class (010)"

# descendant combinator with an ATTRIBUTE on the ancestor.
assert_seg "themed span orange" '#ffaa00'  "section[data-theme=dark] span matches ancestor attribute"

if [ "$fail" -ne 0 ]; then
    echo "[hb-attrsel] RESULT: FAIL"; exit 1
fi
echo "[hb-attrsel] RESULT: PASS"
