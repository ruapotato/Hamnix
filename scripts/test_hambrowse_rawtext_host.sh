#!/usr/bin/env bash
# scripts/test_hambrowse_rawtext_host.sh — FAST, QEMU-free gate for the
# source-text selector engine's RAW-TEXT (CDATA) scope (browser campaign
# round 6). The source-text scanners (_dom_collect_selector / _dom_find_by_id /
# _dom_build_tree_index in lib/htmlengine.ad) walk the ENTIRE source byte span.
# Before this fix they also walked the bodies of <script> and <style>, so
# markup that exists only as a JS string literal (box.innerHTML = '<p class=
# "para">') or inside a CSS string value was FALSELY matched as real DOM —
# double-counting nodes (the round-5 `.para` count of 4 instead of 2) and
# returning phantom getElementById hits.
#
# HTML rule: script/style are raw-text/CDATA elements; their body ends only at
# the literal </script> / </style> close tag. This gate proves the scanners now
# skip those bodies while keeping the tags themselves and every real element
# before/after them matchable. Exact-output oracle on console.log lines
# (deterministic DOM-state readback, never glyph-ink pixels).
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_rawtext_scope.html"
mkdir -p "$OUT"

echo "[hb-rt] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/rt_compile.log"; then
    echo "[hb-rt] FAIL: host harness did not compile"; cat "$OUT/rt_compile.log"; exit 1
fi
echo "[hb-rt] PASS host harness compiled -> $BIN"

echo "[hb-rt] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/rt_native.log"; then
    echo "[hb-rt] FAIL: native hambrowse did not compile"; cat "$OUT/rt_native.log"; exit 1
fi
echo "[hb-rt] PASS native hambrowse still compiles"

fail=0
D0="$OUT/rt_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-rt] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-rt] PASS $2"
    else
        echo "[hb-rt] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-rt] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-rt] PASS $2"
    fi
}

# The page has exactly 3 real <p class="para"> (two before the scripts, one
# after). A <style> string value and a <script> string literal each hide one
# phantom <p class="para">; with the bug this reported 5.
assert_grep '^JSLOG para 3$'   "querySelectorAll('.para') counts only the 3 real elements (not script/style phantoms)"

# .ghost exists ONLY inside the <script> body (two string literals). No real
# element uses it, so the correct count is 0 (bug reported 2).
assert_grep '^JSLOG ghost 0$'  "a class present only in a <script> string literal is not matched"

# getElementsByTagName('p'): 3 real, the phantom <p> in the script string ignored.
assert_grep '^JSLOG ptag 3$'   "getElementsByTagName('p') ignores the phantom <p> in the script body"

# getElementById over ids that live only in a <script> / <style> string => null.
assert_grep '^JSLOG ghostid true$' "getElementById of an id only in a <script> string returns null"
assert_grep '^JSLOG cssid true$'   "getElementById of an id only in a <style> string returns null"

# Regression: a real element AFTER the two raw-text blocks still matches, and
# the second console.log (from the trailing script) also sees all 3.
assert_grep '^JSLOG after 3$'  "a real element after the script/style blocks still matches"

# No uncaught error anywhere in the run (bare '<' inside JS body parsed fine).
assert_nogrep '^JSERR'  "no uncaught JS error across the raw-text script"
assert_nogrep 'Uncaught' "no 'Uncaught' error from a missing DOM API"

# BUTTON-LABEL RAW-TEXT SCOPE: a <button> whose first child is a nested <style>
# (google's search button shape) must render only its real label — the rawtext
# CSS body must NOT leak as the visible button label. Before the fix the button
# read as "[ .leakcls{display:flex;…}Search Now ]".
assert_grep '\[ Search Now \]' "button with a nested <style> renders its real label"
assert_nogrep 'leakcls'        "nested <style> class selector does not leak as button-label text"
assert_nogrep 'display:flex'   "nested <style> declarations do not leak as button-label text"

if [ "$fail" -ne 0 ]; then
    echo "[hb-rt] RESULT: FAIL"; exit 1
fi
echo "[hb-rt] RESULT: PASS"
