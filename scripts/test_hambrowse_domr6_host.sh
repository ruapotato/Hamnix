#!/usr/bin/env bash
# scripts/test_hambrowse_domr6_host.sh — FAST, QEMU-free gate for W3C DOM
# conformance ROUND 6 (browser campaign). Proves the DOM/dom-events/html-forms
# depth added this round in lib/web/dom/{query,canvas,bindings}.ad:
#   1. Event / CustomEvent / MouseEvent / KeyboardEvent CONSTRUCTORS with
#      .type/.bubbles/.cancelable/.detail + basic Mouse/Keyboard fields, usable
#      with dispatchEvent; preventDefault() -> dispatchEvent() returns false and
#      event.defaultPrevented flips true.
#   2. event.stopImmediatePropagation() (no further listeners on the element),
#      addEventListener {once:true} (auto-remove after first fire) and the
#      useCapture boolean 3rd argument.
#   3. Element.childElementCount + first/last/next element traversal.
#   4. Element.getAttributeNames() + hasAttributes() (source-tag attribute list).
#   5. Constraint Validation: input.checkValidity() (required-empty -> false),
#      form.checkValidity() over form.elements, and form.elements.length (the
#      round-2 JS-array regression, retried now that the array allocator is fixed).
# Each feature group renders as its own small fixture (the engine's console
# capture stays compact per page). Exact-output oracle on console.log lines.
# Builds host (x86_64-linux) AND native (x86_64-adder-user) targets.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
mkdir -p "$OUT"

echo "[hb-r6] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/r6_compile.log"; then
    echo "[hb-r6] FAIL: host harness did not compile"; cat "$OUT/r6_compile.log"; exit 1
fi
echo "[hb-r6] PASS host harness compiled -> $BIN"

echo "[hb-r6] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/r6_native.log"; then
    echo "[hb-r6] FAIL: native hambrowse did not compile"; cat "$OUT/r6_native.log"; exit 1
fi
echo "[hb-r6] PASS native hambrowse still compiles"

fail=0
D0="$OUT/r6_run.txt"
: >"$D0"
for fx in ctor listen traverse attrs validity; do
    F="tests/fixtures/hambrowse_domr6_${fx}.html"
    "$BIN" "$F" 880 >>"$D0" 2>&1 || { echo "[hb-r6] FAIL: render of $fx exited non-zero"; cat "$D0"; exit 1; }
done

assert_grep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-r6] PASS $2"; else echo "[hb-r6] FAIL $2 (missing: $1)"; fail=1; fi
}
assert_nogrep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-r6] FAIL $2 (present: $1)"; fail=1; else echo "[hb-r6] PASS $2"; fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# ---- (1) Event/CustomEvent/MouseEvent/KeyboardEvent constructors -------------
assert_grep '^JSLOG EVT click\|true\|true$'    "new Event(type,{bubbles,cancelable}) reflects type/bubbles/cancelable"
assert_grep '^JSLOG CE build\|42$'             "new CustomEvent(type,{detail}) carries type + numeric detail"
assert_grep '^JSLOG CEFIRE hi$'                "dispatchEvent(new CustomEvent(...)) fires a listener that reads event.detail"
assert_grep '^JSLOG PD false\|true$'           "preventDefault() -> dispatchEvent()==false and event.defaultPrevented==true"
assert_grep '^JSLOG ME 10\|20\|1$'             "new MouseEvent carries clientX/clientY/button"
assert_grep '^JSLOG KE keydown\|Enter$'        "new KeyboardEvent carries type + key"

# ---- (2) stopImmediatePropagation / once / capture ---------------------------
assert_grep '^JSLOG SIP A$'                    "stopImmediatePropagation halts remaining same-element listeners (B never ran)"
assert_grep '^JSLOG ONCE 1$'                   "addEventListener {once:true} fires exactly once across two dispatches"
assert_grep '^JSLOG CAP 1$'                    "useCapture boolean 3rd arg is accepted and the listener still fires"

# ---- (3) childElementCount + element traversal -------------------------------
assert_grep '^JSLOG CEC 3$'                    "childElementCount counts element children (3 <li>)"
assert_grep '^JSLOG FLC a\|c\|c$'              "first/lastElementChild + children[1].nextElementSibling resolve"

# ---- (4) getAttributeNames + hasAttributes -----------------------------------
assert_grep '^JSLOG GAN 4\|id,src,alt,data-role$' "getAttributeNames() returns the source-tag attribute names in order"
assert_grep '^JSLOG HAS true$'                 "hasAttributes() true for an element with attributes"
assert_grep '^JSLOG HAS3 false$'               "hasAttributes() false for an element with no attributes"

# ---- (5) constraint validation + form.elements -------------------------------
assert_grep '^JSLOG CV false\|true$'           "checkValidity(): required+empty is invalid, non-required is valid"
assert_grep '^JSLOG CV2 true$'                 "checkValidity() becomes valid once the required field has a value"
assert_grep '^JSLOG FEL 3\|false$'             "form.elements.length is 3 (JS-array fix) and form.checkValidity() is false while a required field is empty"
assert_grep '^JSLOG FVOK true$'                "form.checkValidity() flips true after every required control is filled"

assert_nogrep '^JSERR'                         "no uncaught JS error across the round-6 scripts"
assert_nogrep 'Uncaught'                       "no 'Uncaught' TypeError from a missing DOM/event API"

if [ "$fail" -ne 0 ]; then echo "[hb-r6] RESULT: FAIL"; exit 1; fi
echo "[hb-r6] RESULT: PASS"
