#!/usr/bin/env bash
# scripts/test_hambrowse_domapi_host.sh — FAST, QEMU-free gate for the DOM /
# element API surface real web pages call (task #320, browser campaign round 1):
# querySelectorAll / getElementsByClassName / getElementsByTagName returning
# array-like NodeLists (length / indexing / forEach), element-scoped queries,
# attribute selectors + compound tag.class, dataset, hasAttribute /
# removeAttribute, addEventListener + dispatchEvent + removeEventListener +
# event.target, and cloneNode — plus proof that a querySelector-driven
# textContent mutation is REFLECTED in the rendered page.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot. Exact-output oracle on the script's
# console.log lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_dom_api.html"
mkdir -p "$OUT"

echo "[hb-dom] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/dom_compile.log"; then
    echo "[hb-dom] FAIL: host harness did not compile"; cat "$OUT/dom_compile.log"; exit 1
fi
echo "[hb-dom] PASS host harness compiled -> $BIN"

echo "[hb-dom] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/dom_native.log"; then
    echo "[hb-dom] FAIL: native hambrowse did not compile"; cat "$OUT/dom_native.log"; exit 1
fi
echo "[hb-dom] PASS native hambrowse still compiles"

fail=0
D0="$OUT/dom_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-dom] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-dom] PASS $2"
    else
        echo "[hb-dom] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-dom] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-dom] PASS $2"
    fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# NodeList selectors: length, forEach, indexing.
assert_grep '^JSLOG qsa 3$'                 "querySelectorAll('.item') -> NodeList of length 3"
assert_grep '^JSLOG each AlphaBetaGamma$'   "NodeList.forEach iterates + reads textContent"
assert_grep '^JSLOG tag 3$'                 "getElementsByTagName('li') -> 3"
assert_grep '^JSLOG cls Beta$'              "getElementsByClassName('item')[1].textContent"
# Selector richness: attribute + compound tag.class.
assert_grep '^JSLOG attr 1$'                "attribute selector [data-role] matches 1"
assert_grep '^JSLOG comp Gamma$'            "compound selector li.last resolves"
# Element-scoped query (subtree only).
assert_grep '^JSLOG scoped 3$'              "element.querySelectorAll scopes to the subtree"
# dataset (camelCased data-* attributes).
assert_grep '^JSLOG data 10/lead$'          "dataset.id / dataset.role read data-* attributes"
# hasAttribute.
assert_grep '^JSLOG has truefalse$'         "hasAttribute true for present / false for absent"
# classList composes with the new surface.
assert_grep '^JSLOG clist true$'            "classList.add + contains still work"
# Events: addEventListener + dispatchEvent counted twice, removeEventListener stops it.
assert_grep '^JSLOG evt 2$'                 "dispatchEvent fires the listener; removeEventListener detaches it"
# cloneNode.
assert_grep '^JSLOG clone LI Alpha$'        "cloneNode copies spec-uppercase tagName + textContent"
# No uncaught error anywhere in the run.
assert_nogrep '^JSERR'                      "no uncaught JS error across the DOM-API script"
assert_nogrep 'Uncaught'                    "no 'Uncaught' TypeError from a missing DOM API"

# THE REFLECTION PROOF: a querySelector('#status').textContent = "DOM-OK" write
# must be baked into the render (status was "pending" in source).
assert_grep 'DOM-OK'                        "querySelector-driven textContent mutation reflects in the render"
assert_nogrep '\|pending\|'                 "the original placeholder text is replaced"

# ---- (2) a NEWS/ANALYTICS-shaped page: the gbar pattern from #317 ----------
# querySelectorAll('nav.gb .gb-link').forEach(...) + dataset tracking + scoped
# getElementsByTagName + a class toggle — the exact shape that used to throw
# "cannot read property of null". A clean run wires the page and pings a
# visible footer mutation.
D1="$OUT/dom_news.txt"
"$BIN" "tests/fixtures/hambrowse_news.html" 880 >"$D1" 2>&1
grep -E 'JSLOG|JSERR' "$D1" || true
assert2() {  # pattern message
    if grep -Eq -- "$1" "$D1"; then echo "[hb-dom] PASS $2";
    else echo "[hb-dom] FAIL $2 (missing: $1)"; fail=1; fi
}
assert2 '^JSLOG links 3 home,world,tech$'  "descendant selector nav.gb .gb-link iterates 3 links + dataset"
assert2 '^JSLOG active tech$'              "compound .gb-link.active resolves the current nav item"
assert2 '^JSLOG post 4471$'               "getElementsByClassName + dataset.postId (data-post-id camelCase)"
assert2 '^JSLOG paras 3$'                 "scoped getElementsByTagName('p') counts only the article's paragraphs"
assert2 '^JSLOG head Native browsers are back seen=true$' "headline textContent + classList toggle"
assert2 'loaded:3'                        "analytics footer mutation reflects in the render"
if grep -Eq 'JSERR|Uncaught' "$D1"; then
    echo "[hb-dom] FAIL news page threw an uncaught error"; fail=1
else
    echo "[hb-dom] PASS news/analytics page runs with ZERO uncaught errors"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-dom] RESULT: FAIL"; exit 1
fi
echo "[hb-dom] RESULT: PASS"
