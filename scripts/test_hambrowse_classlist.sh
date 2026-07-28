#!/usr/bin/env bash
# scripts/test_hambrowse_classlist.sh — FAST, QEMU-free gate for the DOM
# Element.classList token-list API (lib/htmlengine.ad): a script (or an inline
# onclick handler) can classList.add/remove/toggle/contains a class and have
# the CHANGE reflected in the rendered output through the normal className
# re-layout path (the CSS cascade re-applies).
#
# classList is the way real interactive pages flip a visual state — far more
# common than assigning a whole `className` string. Before this the property
# was undefined (e.classList.add threw a TypeError), so a huge class of
# interactive pages could not toggle a style.
#
# The gate runs the SAME parse+layout+JS engine compiled for x86_64-linux
# (user/hambrowse_host.ad) directly on a fixture, in milliseconds:
#   (query)  at load, contains()/toggle() report + flip membership correctly;
#   (mutate) an onclick that classList.add('hot')s a paragraph turns it RED +
#            BOLD in the rendered SEG list (it was default #101010 before);
#   (mutate) an onclick that classList.remove('hide')s a display:none element
#            makes its text APPEAR in the render (absent before);
#   (control) the pre-click render is NOT red and does NOT contain the hidden
#            text, so the assertions prove the mutation, not a tautology.
# It also confirms the NATIVE hambrowse still compiles from the same engine.
#
# Built with the frozen Python seed compiler; no QEMU, no boot.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_classlist.html"
mkdir -p "$OUT"
fail=0

echo "[hb-clslist] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/clslist_compile.log"; then
    echo "[hb-clslist] FAIL: host harness did not compile"
    cat "$OUT/clslist_compile.log"; exit 1
fi
echo "[hb-clslist] PASS host harness compiled"

echo "[hb-clslist] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/clslist_native.log"; then
    echo "[hb-clslist] FAIL: native hambrowse did not compile"
    cat "$OUT/clslist_native.log"; exit 1
fi
echo "[hb-clslist] PASS native hambrowse still compiles"

BEFORE="$OUT/clslist_before.txt"
AFTON="$OUT/clslist_afton.txt"
AFTOFF="$OUT/clslist_aftoff.txt"

echo "[hb-clslist] rendering (before / click on / click off) ..."
"$BIN" "$FIX" 600                 >"$BEFORE" 2>&1
"$BIN" "$FIX" 600 click on        >"$AFTON"  2>&1
"$BIN" "$FIX" 600 click off       >"$AFTOFF" 2>&1
echo "---- load-time console ----"; grep -E '^JSLOG' "$BEFORE"

assert_grep() { # <file> <regex> <label>
    if grep -Eq "$2" "$1"; then
        echo "[hb-clslist] PASS $3"
    else
        echo "[hb-clslist] FAIL $3"; fail=1
    fi
}
refute_grep() { # <file> <regex> <label>
    if grep -Eq "$2" "$1"; then
        echo "[hb-clslist] FAIL $3"; fail=1
    else
        echo "[hb-clslist] PASS $3"
    fi
}

# ---- (1) QUERY semantics at load time (console) ----
assert_grep "$BEFORE" '^JSLOG start hot = false$' \
    "classList.contains('hot') is false initially"
assert_grep "$BEFORE" '^JSLOG toggle probe = true$' \
    "classList.toggle('probe') returns true (added)"
assert_grep "$BEFORE" '^JSLOG after toggle = probe$' \
    "className is 'probe' after the add-toggle"
assert_grep "$BEFORE" '^JSLOG untoggle probe = false$' \
    "classList.toggle('probe') returns false (removed)"
assert_grep "$BEFORE" '^JSLOG final class = $' \
    "className is empty after the remove-toggle"

# ---- (2) CONTROL: pre-click state ----
# The target is default grey (#101010), NOT the .hot red, before any click.
assert_grep "$BEFORE" '^SEG .*#101010 b0 .*\|status line\|' \
    "control: target is default grey + not bold before the click"
refute_grep "$BEFORE" 'SEG .*#ff0000.*\|status line\|' \
    "control: target is NOT red before the click"
# The .hide element's text is display:none — absent from the render.
refute_grep "$BEFORE" '\|now visible\|' \
    "control: hidden element's text is absent before the click"

# ---- (3) MUTATE via onclick: classList.add('hot') -> red + bold ----
awk '/^CLICK/{c=1} c' "$AFTON" > "$OUT/clslist_afton_seg.txt"
assert_grep "$OUT/clslist_afton_seg.txt" 'SEG .*#ff0000 b1 .*\|status line\|' \
    "classList.add('hot') rendered target RED + BOLD after the click"

# ---- (4) MUTATE via onclick: classList.remove('hide') -> element appears ----
awk '/^CLICK/{c=1} c' "$AFTOFF" > "$OUT/clslist_aftoff_seg.txt"
assert_grep "$OUT/clslist_aftoff_seg.txt" '\|now visible\|' \
    "classList.remove('hide') un-hid the element (text now renders)"

if [ "$fail" -eq 0 ]; then
    echo "[hb-clslist] PASS"
else
    echo "[hb-clslist] FAIL"; exit 1
fi
