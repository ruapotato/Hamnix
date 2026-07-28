#!/usr/bin/env bash
# scripts/test_hambrowse_insadj_host.sh — FAST, QEMU-free gate for
# Element.insertAdjacentHTML(position, html) (W3C DOM Parsing). 'beforeend'
# appends the parsed fragment inside the element (after existing content);
# 'afterbegin' prepends it; both render through the innerHTML raw-override path.
# The sibling positions 'beforebegin'/'afterend' are not modelled and must be
# safe no-ops (no throw, no corruption). Asserts render ORDER on the SEG list:
# BEGIN (afterbegin) < orig (original) < END (beforeend). Builds host + native.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_insadj.html"
mkdir -p "$OUT"

echo "[hb-iah] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/iah_compile.log"; then
    echo "[hb-iah] FAIL: host harness did not compile"; cat "$OUT/iah_compile.log"; exit 1
fi
echo "[hb-iah] PASS host harness compiled -> $BIN"

echo "[hb-iah] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/iah_native.log"; then
    echo "[hb-iah] FAIL: native hambrowse did not compile"; cat "$OUT/iah_native.log"; exit 1
fi
echo "[hb-iah] PASS native hambrowse still compiles"

fail=0
D0="$OUT/iah_run.txt"
"$BIN" "$FIX" 600 >"$D0" 2>&1 || { echo "[hb-iah] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'SEG .*\|(BEGIN|orig|END|SIB)\|' "$D0" || true

assert_grep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-iah] PASS $2"; else echo "[hb-iah] FAIL $2 (missing: $1)"; fail=1; fi
}
assert_nogrep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-iah] FAIL $2 (present: $1)"; fail=1; else echo "[hb-iah] PASS $2"; fi
}

assert_grep 'SEG .*\|BEGIN\|'  "afterbegin fragment rendered (BEGIN)"
assert_grep 'SEG .*\|orig\|'   "original content preserved (orig)"
assert_grep 'SEG .*\|END\|'    "beforeend fragment rendered (END)"
assert_nogrep 'SEG .*\|SIB\|'  "the unsupported 'afterend' position is a safe no-op (no SIB)"

# render order: BEGIN before orig before END
lb=$(grep -Fn '|BEGIN|' "$D0" | head -1 | cut -d: -f1)
lo=$(grep -Fn '|orig|'  "$D0" | head -1 | cut -d: -f1)
le=$(grep -Fn '|END|'   "$D0" | head -1 | cut -d: -f1)
if [ -n "$lb" ] && [ -n "$lo" ] && [ -n "$le" ] && [ "$lb" -lt "$lo" ] && [ "$lo" -lt "$le" ]; then
    echo "[hb-iah] PASS render order is BEGIN < orig < END"
else
    echo "[hb-iah] FAIL render order (BEGIN=$lb orig=$lo END=$le)"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-iah] RESULT: FAIL"; exit 1; fi
echo "[hb-iah] RESULT: PASS"
