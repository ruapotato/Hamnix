#!/usr/bin/env bash
# scripts/test_hambrowse_qsa_host.sh — FAST, QEMU-free gate for the FULL common
# CSS selector grammar in document.querySelector / querySelectorAll (+ matches /
# closest). Frameworks and site scripts depend on complex selectors, so this
# gate proves the DOM-side query matcher (lib/web/dom/{domtree,query,bindings,
# canvas}.ad) handles, over the SOURCE tree:
#   - combinators: descendant (space), child '>', adjacent '+', general '~'
#   - attribute operators: [a], [a=v], [a^=v], [a$=v], [a*=v], [a~=v], [a|=v]
#   - structural pseudo-classes incl. :nth-child(An+B) (2n / odd / 3n+1),
#     :not(simple), :first-child, :last-child
#   - compound selectors (a.btn[data-x]) and SELECTOR LISTS ('h1, h2' union,
#     document-order first for querySelector, de-duplicated for querySelectorAll)
#   - element.matches(sel) with the full combinator/pseudo chain + closest(sel)
# Exact console.log oracle (deterministic DOM-state readback, never ink pixels).
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) so a regression in either target fails here with no QEMU.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_qsa.html"
mkdir -p "$OUT"

echo "[hb-qsa] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/qsa_compile.log"; then
    echo "[hb-qsa] FAIL: host harness did not compile"; cat "$OUT/qsa_compile.log"; exit 1
fi
echo "[hb-qsa] PASS host harness compiled -> $BIN"

echo "[hb-qsa] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/qsa_native.log"; then
    echo "[hb-qsa] FAIL: native hambrowse did not compile"; cat "$OUT/qsa_native.log"; exit 1
fi
echo "[hb-qsa] PASS native hambrowse still compiles"

fail=0
D0="$OUT/qsa_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-qsa] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG|JSERR|Uncaught' "$D0" || true

assert_grep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-qsa] PASS $2"; else echo "[hb-qsa] FAIL $2 (missing: $1)"; fail=1; fi
}

# combinators
assert_grep '^JSLOG CHILD 4$'        "child combinator 'ul > li' count"
assert_grep '^JSLOG DESC 4$'         "descendant combinator '#root li' count"
assert_grep '^JSLOG CHILD0 0$'       "child combinator does NOT match a deeper descendant"
assert_grep '^JSLOG ADJ 1$'          "adjacent sibling 'h1 + p' count"
assert_grep '^JSLOG ADJ_ID p1$'      "adjacent sibling matches the immediately following element"
assert_grep '^JSLOG GEN 2$'          "general sibling 'h1 ~ p' count"

# attribute operators
assert_grep '^JSLOG ATTR_EQ 1$'      "[attr=value] exact"
assert_grep '^JSLOG ATTR_PFX 1$'     "[attr^=value] prefix"
assert_grep '^JSLOG ATTR_SFX 1$'     "[attr\$=value] suffix"
assert_grep '^JSLOG ATTR_SUB 1$'     "[attr*=value] substring"
assert_grep '^JSLOG ATTR_WORD 1$'    "[attr~=value] whitespace word"
assert_grep '^JSLOG ATTR_DASH 1$'    "[attr|=value] dash-match (en-US)"
assert_grep '^JSLOG ATTR_HAS 1$'     "[attr] presence"

# structural pseudo-classes + An+B math
assert_grep '^JSLOG EVEN 2$'         ":nth-child(2n) selects the even children"
assert_grep '^JSLOG ODD 2$'          ":nth-child(odd) selects the odd children"
assert_grep '^JSLOG NB 2$'           ":nth-child(3n+1) An+B math"
assert_grep '^JSLOG NOT 3$'          ":not(.skip) excludes the matching sibling"
assert_grep '^JSLOG FIRST i1$'       ":first-child"
assert_grep '^JSLOG LAST i4$'        ":last-child"

# compound + selector list
assert_grep '^JSLOG COMPOUND 1$'     "compound 'a.btn[data-x=\"1\"]'"
assert_grep '^JSLOG LIST 2$'         "selector list 'h1, h2' union"
assert_grep '^JSLOG LIST_ORDER t1$'  "querySelector list returns first in DOCUMENT order"
assert_grep '^JSLOG LIST_UNIQ 4$'    "querySelectorAll list is de-duplicated"

# matches()
assert_grep '^JSLOG M_COMP true$'    "matches() compound"
assert_grep '^JSLOG M_CHILD true$'   "matches() honours a child combinator"
assert_grep '^JSLOG M_FIRST true$'   "matches() honours :first-child"
assert_grep '^JSLOG M_ATTR true$'    "matches() attribute prefix operator"
assert_grep '^JSLOG M_LIST true$'    "matches() selector list"
assert_grep '^JSLOG M_NEG false$'    "matches() negative case"

# closest()
assert_grep '^JSLOG CL_UL list$'     "closest('ul') finds nearest ancestor"
assert_grep '^JSLOG CL_ROOT root$'   "closest('#root') finds ancestor by id"

if [ "$fail" -ne 0 ]; then echo "[hb-qsa] RESULT: FAIL"; exit 1; fi
echo "[hb-qsa] RESULT: PASS"
