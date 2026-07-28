#!/usr/bin/env bash
# scripts/test_hambrowse_reactmount_host.sh — FAST, QEMU-free gate for the
# FRAMEWORK-MOUNT wall (§5 of docs/hambrowse_real_web_review_2026-07-25.md).
#
# The review found a second wall, serial with (and upstream of) the live-DOM
# interaction keystone: real React 18 UMD loaded and evaluated cleanly, then
# `ReactDOM.createRoot(container)` THREW, because the DOM primitives its renderer
# reaches for did not exist. This gate pins both halves of the fix:
#
#   (A) tests/fixtures/hambrowse_reactmount.html — the plumbing in isolation:
#       ownerDocument (element / created element / document), namespaceURI,
#       document.defaultView, document.head, the Node/Element/HTMLElement/
#       DocumentFragment/Text/Comment interface objects + their nodeType
#       constants + real `instanceof` branding, createComment /
#       createElementNS / createDocumentFragment (including the spec's
#       "append a fragment moves its CHILDREN and empties it"),
#       appendChild(textNode) actually extending .textContent,
#       style.setProperty / getPropertyValue / removeProperty (kebab-case AND
#       `--custom` names), and MessageChannel delivering as a MACROTASK.
#       Every assertion below was verified byte-identical against
#       `chromium --headless --dump-dom` on the same fixture.
#
#       It also pins the JS-engine miscompile the review's symptom hid: a `var`
#       declared in one `switch` clause and assigned bare in another must stay
#       FUNCTION-scoped. Minified React does that in beginWork(); unhoisted, the
#       bare assignment escaped to the GLOBAL scope and overwrote the page's own
#       `var e = React.createElement` mid-render, so the app silently stopped
#       rendering with no error.
#
#   (B) tests/fixtures/realweb/react_spa.html — the END-TO-END proof: 142 KB of
#       genuine React 18.3.1 + ReactDOM 18.3.1 UMD, client-rendering a hooks
#       component with useState, a mapped list and two buttons. The page's own
#       census must report `REACT all=15 li=2 btn=Count: 0` — the EXACT string
#       chromium produces (the review's §8 acceptance target), and the rendered
#       React tree must reach layout.
#
# NOT covered here (a separate, still-open blocker): user-interaction event
# dispatch cannot resolve JS-created nodes, so clicking React's buttons does not
# advance state. See §4 of the review — this gate pins the FIRST FRAME only.
#
# Builds host + native targets so a regression in either fails here, no QEMU.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_reactmount.html"
SPA="tests/fixtures/realweb/react_spa.html"
mkdir -p "$OUT"

# The pixel/host binaries are CACHED by other harnesses; a stale one would test
# the previous engine (docs/browser_framediff.md gotcha).
rm -f "$OUT/hambrowse_gfx" "$OUT/hambrowse_host_gfx" "$BIN"

echo "[hb-react] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/react_compile.log"; then
    echo "[hb-react] FAIL: host harness did not compile"; cat "$OUT/react_compile.log"; exit 1
fi
echo "[hb-react] PASS host harness compiled -> $BIN"

echo "[hb-react] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/react_native.log"; then
    echo "[hb-react] FAIL: native hambrowse did not compile"; cat "$OUT/react_native.log"; exit 1
fi
echo "[hb-react] PASS native hambrowse still compiles"

fail=0
D0="$OUT/reactmount_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-react] FAIL: plumbing render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {
    if grep -Fxq -- "$1" "$D0"; then echo "[hb-react] PASS $2"
    else echo "[hb-react] FAIL $2 (missing line: $1)"; fail=1; fi
}
assert_nogrep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-react] FAIL $2 (present: $1)"; fail=1
    else echo "[hb-react] PASS $2"; fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# ---- (A1) node identity -----------------------------------------------------
assert_grep 'JSLOG OWNERDOC true'         "source element .ownerDocument === document"
assert_grep 'JSLOG OWNERDOC-CREATED true' "createElement()'d node .ownerDocument === document"
assert_grep 'JSLOG OWNERDOC-DOC true'     "document.ownerDocument is null (not undefined)"
assert_grep 'JSLOG NSURI http://www.w3.org/1999/xhtml' "element .namespaceURI is the XHTML namespace"
assert_grep 'JSLOG DEFAULTVIEW true'      "document.defaultView === window"
assert_grep 'JSLOG HEAD HEAD'             "document.head resolves to the <head> element"

# ---- (A2) DOM interface objects + instanceof branding -----------------------
assert_grep 'JSLOG IFACE function/function/function/function/function/function' \
            "Node/Element/HTMLElement/DocumentFragment/Text/Comment are global constructors"
assert_grep 'JSLOG NODECONST 1,3,8,9,11'  "Node.{ELEMENT,TEXT,COMMENT,DOCUMENT,DOCUMENT_FRAGMENT}_NODE constants"
assert_grep 'JSLOG INSTOF-EL true/true/true' \
            "an element is instanceof Element AND Node AND HTMLElement"
assert_grep 'JSLOG INSTOF-TEXT true/true/false' \
            "a text node is instanceof Node + Text but NOT Element"
assert_grep 'JSLOG INSTOF-DOC true/true'  "document is instanceof Node + Document"

# ---- (A3) node factories ----------------------------------------------------
assert_grep 'JSLOG COMMENT 8/#comment/boundary' "createComment -> nodeType 8, #comment, data"
assert_grep 'JSLOG CREATENS svg/http://www.w3.org/2000/svg' \
            "createElementNS records the requested namespace"
assert_grep 'JSLOG FRAG 11/#document-fragment/0' "createDocumentFragment -> empty nodeType-11 node"
assert_grep 'JSLOG FRAG-FILL 2'   "a fragment collects appended children"
assert_grep 'JSLOG FRAG-FLUSH 2/0' \
            "appending a fragment MOVES its children into the parent and empties it"

# ---- (A4) appended text nodes attach ---------------------------------------
assert_grep 'JSLOG TEXT-CREATED [q]'      "appendChild(textNode) extends a CREATED node's textContent"
assert_grep 'JSLOG TEXT-SOURCE [mounted]' "appendChild(textNode) extends a SOURCE node's textContent"

# ---- (A5) CSSStyleDeclaration methods --------------------------------------
assert_grep 'JSLOG SETPROP function/function/function' \
            "style.setProperty/getPropertyValue/removeProperty exist"
assert_grep 'JSLOG SETPROP-KEBAB rgb(1, 2, 3)/rgb(1, 2, 3)' \
            "setProperty('background-color') lands on the same slot as .backgroundColor"
assert_grep 'JSLOG SETPROP-CUSTOM 7'      "setProperty('--brand') round-trips a custom property"
assert_grep 'JSLOG REMOVEPROP []'         "removeProperty clears the value"

# ---- (A6) MessageChannel is a real MACROTASK hop ---------------------------
assert_grep 'JSLOG MSGCHAN function'      "MessageChannel is a global constructor"
assert_grep 'JSLOG MSGCHAN-PORTS function/function' "both ports expose postMessage"
assert_grep 'JSLOG MSGCHAN-DELIVERED'     "port2.postMessage delivers to port1.onmessage"
# ordering: the delivery must NOT be synchronous (React's scheduler would recurse)
if [ "$(grep -n 'MSGCHAN-ASYNC' "$D0" | cut -d: -f1)" -lt \
     "$(grep -n 'MSGCHAN-DELIVERED' "$D0" | cut -d: -f1)" ]; then
    echo "[hb-react] PASS postMessage delivery is deferred (macrotask, not synchronous)"
else
    echo "[hb-react] FAIL postMessage delivered synchronously"; fail=1
fi

# ---- (A7) var-in-switch hoisting -------------------------------------------
assert_grep 'JSLOG SWITCH-HOIST PAGE-GLOBAL' \
            "a var declared in one switch clause + assigned in another stays function-scoped"

assert_nogrep '^JSERR'   "no uncaught JS error across the plumbing fixture"
assert_nogrep 'Uncaught' "no 'Uncaught' TypeError from a missing DOM API"

# ---- (B) real React 18 UMD mounts AND renders -------------------------------
D1="$OUT/react_spa_run.txt"
"$BIN" "$SPA" 1024 >"$D1" 2>&1 || { echo "[hb-react] FAIL: react_spa render exited non-zero"; exit 1; }

# The fixture's own census writes the answer into <title>. This is chromium's
# EXACT string (verified with `chromium --headless --dump-dom` on the same file).
if grep -Fxq 'TITLE REACT all=15 li=2 btn=Count: 0' "$D1"; then
    echo "[hb-react] PASS real React 18 renders chromium's exact DOM census (all=15 li=2 btn=Count: 0)"
else
    echo "[hb-react] FAIL react_spa census mismatch:"
    grep -E '^TITLE|^JSERR' "$D1" | head -5; fail=1
fi
for want in 'Real React counter' 'Count: 0' 'milk' 'eggs' 'Add'; do
    if grep -Fq "$want" "$D1"; then
        echo "[hb-react] PASS React-created content reaches layout: '$want'"
    else
        echo "[hb-react] FAIL React-created content missing from layout: '$want'"; fail=1
    fi
done
if grep -Eq '^JSERR' "$D1"; then
    echo "[hb-react] FAIL react_spa raised a JS error"; grep -E '^JSERR' "$D1" | head -3; fail=1
else
    echo "[hb-react] PASS react_spa evaluates + mounts with no JS error"
fi

if [ "$fail" -ne 0 ]; then echo "[hb-react] RESULT: FAIL"; exit 1; fi
echo "[hb-react] RESULT: PASS"
