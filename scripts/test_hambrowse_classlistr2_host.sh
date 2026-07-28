#!/usr/bin/env bash
# scripts/test_hambrowse_classlistr2_host.sh — FAST, QEMU-free gate for the
# round-2 DOM Element.classList completeness (W3C dom-core / DOMTokenList):
#   - toggle(name, force): force=true keeps/adds, force=false removes, returns
#     the resulting membership (real toolbars/menus use the forced form).
#   - replace(oldName, newName): swaps a token, returning whether it happened.
#   - item(index): the class token at index, or null when out of range.
# Round 1 shipped add/remove/toggle/contains only. Exact console.log oracle;
# builds host + native targets. NOTE kept to 6 log lines: the shared JS console
# capture has a pre-existing low-line-count ceiling (unrelated to this feature).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_classlist_r2.html"
mkdir -p "$OUT"

echo "[hb-clr2] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/clr2_compile.log"; then
    echo "[hb-clr2] FAIL: host harness did not compile"; cat "$OUT/clr2_compile.log"; exit 1
fi
echo "[hb-clr2] PASS host harness compiled -> $BIN"

echo "[hb-clr2] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/clr2_native.log"; then
    echo "[hb-clr2] FAIL: native hambrowse did not compile"; cat "$OUT/clr2_native.log"; exit 1
fi
echo "[hb-clr2] PASS native hambrowse still compiles"

fail=0
D0="$OUT/clr2_run.txt"
"$BIN" "$FIX" 400 >"$D0" 2>&1 || { echo "[hb-clr2] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-clr2] PASS $2"; else echo "[hb-clr2] FAIL $2 (missing: $1)"; fail=1; fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep '^JSLOG force-add true one two$'  "toggle('one', true) keeps the class + returns true"
assert_grep '^JSLOG force-rem false one$'     "toggle('two', false) removes the class + returns false"
assert_grep '^JSLOG replace true x$'          "replace('one','x') swaps the token + returns true"
assert_grep '^JSLOG replace-miss false$'      "replace('nope','q') returns false when the old token is absent"
assert_grep '^JSLOG item0 x$'                 "item(0) returns the first class token"
assert_grep '^JSLOG item-oob null$'           "item(5) returns null when out of range"

if [ "$fail" -ne 0 ]; then echo "[hb-clr2] RESULT: FAIL"; exit 1; fi
echo "[hb-clr2] RESULT: PASS"
