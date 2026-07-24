#!/usr/bin/env bash
# scripts/test_hambrowse_inputtypes_host.sh — FAST, QEMU-free gate for
# specialized <input type=...> rendering (W3C html-forms round, w3c/dom-core).
# Before this every non-checkbox/radio/button/hidden input fell through to the
# generic text box, leaking a password's plaintext value and giving file/range/
# color no distinct affordance. This gate renders one of each and asserts the
# real render tokens (FLOW line), including that the password value is masked
# and NEVER surfaced as plaintext.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_input_types.html"
mkdir -p "$OUT"

echo "[hb-it] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/it_compile.log"; then
    echo "[hb-it] FAIL: host harness did not compile"; cat "$OUT/it_compile.log"; exit 1
fi
echo "[hb-it] PASS host harness compiled -> $BIN"

echo "[hb-it] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/it_native.log"; then
    echo "[hb-it] FAIL: native hambrowse did not compile"; cat "$OUT/it_native.log"; exit 1
fi
echo "[hb-it] PASS native hambrowse still compiles"

fail=0
D0="$OUT/it_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-it] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

FLOW=$(grep -E '^FLOW' "$D0" | head -1)
echo "$FLOW"

assert_has()  { if printf '%s' "$FLOW" | grep -Fq -- "$1"; then echo "[hb-it] PASS $2"; else echo "[hb-it] FAIL $2 (missing: $1)"; fail=1; fi; }
assert_lacks(){ if printf '%s' "$FLOW" | grep -Fq -- "$1"; then echo "[hb-it] FAIL $2 (present: $1)"; fail=1; else echo "[hb-it] PASS $2"; fi; }

assert_has  '[hello_______________]'  "text field renders value padded to the 20-cell UA default width"
assert_has  '[******______________]'  "password value masked to '*' (6 chars) and padded to 20 cells"
assert_lacks 'secret'         "password plaintext value NEVER appears in the render"
assert_has  '[ Choose File ]' "type=file renders a Choose File button affordance"
assert_has  '[--O--]'         "type=range renders a slider track+thumb glyph"
assert_has  '[#ff8800]'       "type=color renders the value as a swatch token"
assert_has  '[#000000]'       "type=color with no value defaults to #000000"

if [ "$fail" -ne 0 ]; then
    echo "[hb-it] RESULT: FAIL"; exit 1
fi
echo "[hb-it] RESULT: PASS"
