#!/usr/bin/env bash
# scripts/test_hambrowse_dommut_host.sh — FAST, QEMU-free gate for the DOM
# MUTATION + node-identity surface real pages depend on (browser campaign
# round 3). Rounds 1/2 (#320/#324) shipped the DOM-API surface and the real
# parent/child/sibling tree; this gate proves the node-manipulation gaps that
# frameworks and hand-rolled widgets lean on:
#   - node identity: nodeType (element 1 / text 3 / document 9), nodeName
#     (uppercase tag / #text / #document), nodeValue (text-node data, null on
#     elements) — frameworks branch on `node.nodeType === 1`.
#   - last/previousElement traversal, plus the NODE-level lastChild /
#     previousSibling (Text nodes between the elements, as in a browser).
#   - :nth-child(An+B) incl. even / odd / n+B / -n+B (the parser previously took
#     only a bare integer, and '+' inside the parens split as a combinator).
#   - insertBefore / replaceChild / removeChild keeping the LIVE JS
#     .children/.childNodes array in sync with the mutated tree + parentNode
#     back-links, and replaceChild returning the old node.
#   - a mutation whose text is DERIVED from a node property (st.nodeName) baked
#     into the render (SEG readback, not a glyph-ink pixel).
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot. Exact-output oracle on console.log lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_dommut.html"
mkdir -p "$OUT"

echo "[hb-mut] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/mut_compile.log"; then
    echo "[hb-mut] FAIL: host harness did not compile"; cat "$OUT/mut_compile.log"; exit 1
fi
echo "[hb-mut] PASS host harness compiled -> $BIN"

echo "[hb-mut] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/mut_native.log"; then
    echo "[hb-mut] FAIL: native hambrowse did not compile"; cat "$OUT/mut_native.log"; exit 1
fi
echo "[hb-mut] PASS native hambrowse still compiles"

fail=0
D0="$OUT/mut_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-mut] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-mut] PASS $2"
    else
        echo "[hb-mut] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-mut] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-mut] PASS $2"
    fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# ---- node identity: nodeType / nodeName / nodeValue ----------------------
assert_grep '^JSLOG nid 1 LI 9$'            "nodeType element=1, nodeName==tagName (LI), document.nodeType=9"
assert_grep '^JSLOG text 3 #text hello$'    "createTextNode -> nodeType 3, nodeName #text, nodeValue == data"
assert_grep '^JSLOG nval null$'             "element nodeValue is null"

# ---- traversal aliases ---------------------------------------------------
assert_grep '^JSLOG alias Epsilon Delta$'   "lastElementChild + previousElementSibling"
# NODE-level traversal: with source text nodes in the tree, lastChild and
# previousSibling are the newlines between the <li>s, not the <li>s. Chromium
# --headless --dump-dom on the same list shape reports exactly this (see the
# fixture comment); the old expectation here was the element-only approximation.
assert_grep '^JSLOG nodealias 11 3 3 "[\\]n  "$' "childNodes/firstChild/lastChild are node-level"

# ---- :nth-child(An+B) / even / odd ---------------------------------------
assert_grep '^JSLOG odd 3 even 2$'          ":nth-child(odd)=3, :nth-child(even)=2"
assert_grep '^JSLOG anb 3 1 3$'             ":nth-child(2n+1)=3, (3n)=1, (n+3)=3 ('+' inside parens no longer splits)"
assert_grep '^JSLOG negn 2$'                ":nth-child(-n+2)=2 (negative coefficient)"

# ---- insertBefore / replaceChild / removeChild live .children sync -------
assert_grep '^JSLOG ins 6 Inserted UL$'     "insertBefore mounts a created node at the head + parentNode back-link"
assert_grep '^JSLOG rep 6 Replaced UL Inserted$' "replaceChild swaps in place, sets parentNode, returns the old node"
assert_grep '^JSLOG del 5 Alpha$'           "removeChild drops the node from the live .children"

# ---- no uncaught error ---------------------------------------------------
assert_nogrep '^JSERR'   "no uncaught JS error across the mutation script"
assert_nogrep 'Uncaught' "no 'Uncaught' TypeError from a missing mutation API"

# ---- THE RENDER REFLECTION PROOF -----------------------------------------
# st.textContent = st.nodeName + "-MUT-OK": a value derived from a node property
# must be baked into the render (SEG readback, not a glyph-ink pixel).
assert_grep 'P-MUT-OK'    "nodeName-derived textContent mutation reflects in the render"
assert_nogrep 'mut-pending' "the original placeholder text is replaced"

if [ "$fail" -ne 0 ]; then
    echo "[hb-mut] RESULT: FAIL"; exit 1
fi
echo "[hb-mut] RESULT: PASS"
