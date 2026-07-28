#!/usr/bin/env bash
# scripts/test_hambrowse_domtree_host.sh — FAST, QEMU-free gate for the REAL
# DOM tree (task #324, browser campaign round 2). Round 1 (#320) shipped the
# DOM-API surface but the DOM was flat/source-anchored, so tree-walking failed
# and selector combinators were a rightmost-compound approximation. This gate
# proves the real parent/child/sibling tree + true combinators:
#   - traversal: parentNode/parentElement, children/childNodes, first/last-
#     ElementChild, next/previousElementSibling — including the exact chain the
#     flat model could not do: el.parentNode.children[0].nextElementSibling
#   - combinators: child (a>b), adjacent (a+b), general sibling (a~b),
#     descendant (a b), + child-vs-descendant distinction
#   - structural pseudo-classes: :first-child / :last-child / :nth-child(n)
#   - spec-uppercase .tagName (el.tagName === 'DIV')
#   - appendChild mutating the live tree (.children length + parentNode backlink)
#   - a status mutation reached PURELY by walking the tree, reflected in render.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot. Exact-output oracle on console.log lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_domtree.html"
mkdir -p "$OUT"

echo "[hb-tree] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/tree_compile.log"; then
    echo "[hb-tree] FAIL: host harness did not compile"; cat "$OUT/tree_compile.log"; exit 1
fi
echo "[hb-tree] PASS host harness compiled -> $BIN"

echo "[hb-tree] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/tree_native.log"; then
    echo "[hb-tree] FAIL: native hambrowse did not compile"; cat "$OUT/tree_native.log"; exit 1
fi
echo "[hb-tree] PASS native hambrowse still compiles"

fail=0
D0="$OUT/tree_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-tree] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-tree] PASS $2"
    else
        echo "[hb-tree] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-tree] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-tree] PASS $2"
    fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# ---- traversal: parent / child / sibling links (spec-uppercase tagName) ---
assert_grep '^JSLOG nav UL NAV$'         "parentNode + grandparent, both spec-uppercase tagName"
assert_grep '^JSLOG walk World Home Tech$' "el.parentNode.children[0].nextElementSibling.textContent (the flat model could not) + first/lastElementChild"
assert_grep '^JSLOG sibs Home Tech 3$'   "previous/nextElementSibling + element-only children.length (whitespace text ignored)"

# ---- true selector combinators -------------------------------------------
assert_grep '^JSLOG comb 3 2 1$'         "child (.menu > li=3), adjacent (li + li=2), general-sibling (.intro ~ p=1)"
assert_grep '^JSLOG desc 3 2$'           "descendant (#content p=3) vs child (#content > p=2, excludes the article-nested p)"

# ---- structural pseudo-classes -------------------------------------------
assert_grep '^JSLOG pseudo Home Tech World$' ":first-child / :last-child / :nth-child(2)"
assert_grep '^JSLOG sib NAV$'            "getElementById(...).nextElementSibling.tagName (NAV)"

# ---- appendChild on the LIVE tree ----------------------------------------
assert_grep '^JSLOG append 4 UL$'        "appendChild grows the parent's live .children + sets child.parentNode"

# ---- no uncaught error ---------------------------------------------------
assert_nogrep '^JSERR'   "no uncaught JS error across the tree-walking script"
assert_nogrep 'Uncaught' "no 'Uncaught' TypeError from a missing traversal API"

# ---- THE RENDER REFLECTION PROOF -----------------------------------------
# tgt.textContent = tgt.parentNode.tagName + "-WALK-OK": a mutation whose value
# is computed by walking UP the tree must be baked into the render.
assert_grep 'BODY-WALK-OK'  "tree-walk-driven textContent mutation reflects in the render"
assert_nogrep 'walk-pending' "the original placeholder text is replaced"
# the appended <li>News</li> must render too (real-tree appendChild reaches layout)
assert_grep '\|News\|'      "appendChild'd <li> renders into the page"

if [ "$fail" -ne 0 ]; then
    echo "[hb-tree] RESULT: FAIL"; exit 1
fi
echo "[hb-tree] RESULT: PASS"
