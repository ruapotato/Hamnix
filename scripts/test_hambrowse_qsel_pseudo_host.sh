#!/usr/bin/env bash
# scripts/test_hambrowse_qsel_pseudo_host.sh — FAST, QEMU-free gate for the
# EXTENDED structural pseudo-class family in the selectors API (W3C css-selectors
# round, w3c/dom-core). Before this the query engine understood only
# :first-child / :last-child / :nth-child; this gate proves the added set, over
# BOTH the source tree and the created-node overlay:
#   - :first-of-type / :last-of-type / :only-of-type / :nth-of-type(n)
#   - :nth-last-child(n)
#   - :only-child
#   - :empty (incl. whitespace-only content)
#   - :not(<simple compound>)  (tag / .class / #id / [attr])
# and a render reflection driven by an of-type-selected node.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot. Exact-output oracle on console.log lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_qsel_pseudo.html"
mkdir -p "$OUT"

echo "[hb-ps] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/ps_compile.log"; then
    echo "[hb-ps] FAIL: host harness did not compile"; cat "$OUT/ps_compile.log"; exit 1
fi
echo "[hb-ps] PASS host harness compiled -> $BIN"

echo "[hb-ps] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/ps_native.log"; then
    echo "[hb-ps] FAIL: native hambrowse did not compile"; cat "$OUT/ps_native.log"; exit 1
fi
echo "[hb-ps] PASS native hambrowse still compiles"

fail=0
D0="$OUT/ps_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-ps] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-ps] PASS $2"
    else
        echo "[hb-ps] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-ps] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-ps] PASS $2"
    fi
}

# ---- of-type over the source tree ----------------------------------------
assert_grep '^JSLOG otype P1 P3 P2$'      ":first-of-type / :last-of-type / :nth-of-type(2) over source"
assert_grep '^JSLOG onlytype Head S2$'    ":only-of-type (single h2) + :last-of-type (span)"
# ---- nth-last-child ------------------------------------------------------
assert_grep '^JSLOG nlc Four Three$'      ":nth-last-child(1)/(2) index from the end"
# ---- :not() + :only-child + :empty ---------------------------------------
assert_grep '^JSLOG not 3 P3$'            ":not(.mid) excludes 1 of 4 li; :not(.a) selects the non-.a p"
assert_grep '^JSLOG only only 3$'         ":only-child (single <b>) + div:empty counts 3 (incl. whitespace-only + empty divs)"
# ---- the SAME pseudos over CREATED nodes ---------------------------------
assert_grep '^JSLOG cre 2 C3 C1 C3$'      ":not / :nth-last-child / :first-of-type / :last-of-type over createElement nodes"
# ---- no uncaught error ---------------------------------------------------
assert_nogrep '^JSERR'   "no uncaught JS error across the pseudo-class script"
assert_nogrep 'Uncaught' "no 'Uncaught' TypeError from a missing pseudo-class"
# ---- render reflection ---------------------------------------------------
assert_grep 'P3-PSEUDO-OK'   "an of-type-selected node's textContent mutation reflects in the render"
assert_nogrep 'pseudo-pending' "the original placeholder text is replaced"

if [ "$fail" -ne 0 ]; then
    echo "[hb-ps] RESULT: FAIL"; exit 1
fi
echo "[hb-ps] RESULT: PASS"
