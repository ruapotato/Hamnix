#!/usr/bin/env bash
# scripts/test_hambrowse_qsel_created_host.sh — FAST, QEMU-free gate for
# selectors over the CREATED-node tree (browser campaign round 5). Before this,
# querySelector/All + getElementById/ByClassName/ByTagName scanned only the
# SOURCE text, so elements built at runtime via createElement+appendChild or an
# `innerHTML=` setter were invisible to every selector — a huge real-site gap
# (frameworks build UI dynamically then query/mutate it). This gate proves the
# selector engine now ALSO traverses the created-node overlay (cre_*/ap_*/cc_*
# + JS childNodes arrays), matching the same grammar, and crosses up into the
# source tree at a created root so `.source .created` chains resolve:
#   - createElement + appendChild, then querySelector('.card') finds it
#   - descendant across created nodes ('.card .label')
#   - attribute selector over a setAttribute'd created node
#   - getElementById over a created node (SAME object identity)
#   - innerHTML, then querySelectorAll('.para') / querySelector('p.hot') find
#     nodes inside it; element-scoped box.querySelectorAll('p')
#   - getElementById over an innerHTML-created node
#   - combinator/class query SPANNING source (#app.container) + created (.card),
#     both descendant and child ('>') combinators
#   - getElementsByClassName / getElementsByTagName see created nodes
#   - source-scan regression guard (a source-only class still resolves)
#   - :nth-child / :last-child over created siblings
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot. Exact-output oracle on console.log lines
# (deterministic DOM-state readback, never glyph-ink pixels).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_qsel_created.html"
mkdir -p "$OUT"

echo "[hb-qc] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/qc_compile.log"; then
    echo "[hb-qc] FAIL: host harness did not compile"; cat "$OUT/qc_compile.log"; exit 1
fi
echo "[hb-qc] PASS host harness compiled -> $BIN"

echo "[hb-qc] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/qc_native.log"; then
    echo "[hb-qc] FAIL: native hambrowse did not compile"; cat "$OUT/qc_native.log"; exit 1
fi
echo "[hb-qc] PASS native hambrowse still compiles"

fail=0
D0="$OUT/qc_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-qc] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-qc] PASS $2"
    else
        echo "[hb-qc] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-qc] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-qc] PASS $2"
    fi
}

# (1) createElement + appendChild visible to querySelector (document scope;
#     these class/tag names never appear as a literal start-tag in the source).
assert_grep '^JSLOG q_card true$'    "querySelector('.card') finds a createElement+appendChild node"
assert_grep '^JSLOG q_span true$'    "descendant selector '.card .label' spans two created nodes"
assert_grep '^JSLOG q_attr 1$'       "attribute selector over a setAttribute'd created node"
assert_grep '^JSLOG gcls 1$'         "getElementsByClassName sees a created node"
assert_grep '^JSLOG gtag 1$'         "getElementsByTagName sees a created node"
assert_grep '^JSLOG byid true true$' "getElementById over a created node returns the SAME object"

# (3) combinators spanning source + created nodes.
assert_grep '^JSLOG span1 1$'        "descendant '.container .card' crosses source -> created"
assert_grep '^JSLOG span2 1$'        "child combinator '#app > .card' crosses source -> created"

# (2) innerHTML content visible to selectors, proven via element-scoped queries
#     (empty source span => searches ONLY the created subtree, exact + by identity).
assert_grep '^JSLOG box_p 2$'        "element-scoped querySelectorAll('p') counts innerHTML-created nodes"
assert_grep '^JSLOG box_hot true$'   "querySelector('p.hot') resolves a compound over innerHTML nodes"
assert_grep '^JSLOG box_ident true$' "scoped querySelector returns the actual created node (identity)"
assert_grep '^JSLOG box_inner true$' "querySelector('#inner') over an innerHTML-created node"

# Regression: the source-text scan is untouched.
assert_grep '^JSLOG src 1$'          "source-scan selector still resolves a source-only class"

# Structural pseudos over created siblings.
assert_grep '^JSLOG nth true$'       "':nth-child(2)' selects the right created sibling"
assert_grep '^JSLOG last true$'      "':last-child' selects the last created sibling"

# No uncaught error anywhere in the run.
assert_nogrep '^JSERR'               "no uncaught JS error across the created-selector script"
assert_nogrep 'Uncaught'             "no 'Uncaught' error from a missing DOM API"

if [ "$fail" -ne 0 ]; then
    echo "[hb-qc] RESULT: FAIL"; exit 1
fi
echo "[hb-qc] RESULT: PASS"
