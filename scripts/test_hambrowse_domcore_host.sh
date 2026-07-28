#!/usr/bin/env bash
# scripts/test_hambrowse_domcore_host.sh — FAST, QEMU-free gate for the DOM
# document-root accessors (browser W3C campaign, dom-core round). Prior rounds
# exposed document.getElementById/createElement/querySelector*/forms/title but
# NOT the document roots every page reaches for: document.body,
# document.documentElement, document.head. This gate proves each resolves to the
# real element node (spec-uppercase tagName), is the SAME object querySelector
# returns, carries a live .className / .style / .classList, and that
# document.body.appendChild(document.createElement(...)) renders — coexisting
# with a mutation on a node NESTED under body (the recursive-rewrite fix). Also
# covers element scrollTop / scrollLeft (readable + writable static offsets) and
# document.body.scrollHeight.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot. Exact-output oracle on console.log lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_domcore.html"
mkdir -p "$OUT"

echo "[hb-core] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/core_compile.log"; then
    echo "[hb-core] FAIL: host harness did not compile"; cat "$OUT/core_compile.log"; exit 1
fi
echo "[hb-core] PASS host harness compiled -> $BIN"

echo "[hb-core] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/core_native.log"; then
    echo "[hb-core] FAIL: native hambrowse did not compile"; cat "$OUT/core_native.log"; exit 1
fi
echo "[hb-core] PASS native hambrowse still compiles"

fail=0
D0="$OUT/core_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-core] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-core] PASS $2"
    else
        echo "[hb-core] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-core] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-core] PASS $2"
    fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# ---- document roots resolve to the real element nodes --------------------
assert_grep '^JSLOG roots HTML BODY HEAD$'  "document.documentElement/body/head resolve to <html>/<body>/<head> (spec-uppercase tagName)"
assert_grep '^JSLOG bodycls page true$'     "document.body carries its class + IS the object querySelector('body') returns"
assert_grep '^JSLOG docel true$'            "document.documentElement.classList is live (add + contains)"

# ---- document.body.appendChild(document.createElement('div')) ------------
assert_grep '^JSLOG append BODY$'           "appendChild into document.body sets child.parentNode -> BODY"
assert_grep '^JSLOG scroll number$'         "document.body.scrollHeight is a number"

# ---- scrollTop / scrollLeft ----------------------------------------------
assert_grep '^JSLOG scroll0 0 0$'           "element scrollTop/scrollLeft default to 0"
assert_grep '^JSLOG scrollset 42 7$'        "element scrollTop/scrollLeft are writable (survive assignment)"

# ---- no uncaught error ---------------------------------------------------
assert_nogrep '^JSERR'   "no uncaught JS error across the document-root script"
assert_nogrep 'Uncaught' "no 'Uncaught' TypeError from a missing document-root accessor"

# ---- RENDER REFLECTION: append + nested mutation coexist -----------------
# document.body.appendChild(div) renders the div AND a textContent mutation on
# a node nested under body still bakes in (recursive-rewrite fix).
assert_grep 'appended-into-body' "document.body.appendChild'd <div> renders into the page"
assert_grep 'BODY-CORE-OK'       "a mutation on a node NESTED under the appended-to body still renders"
assert_nogrep 'core-pending'     "the original placeholder text is replaced (nested override not dropped)"

if [ "$fail" -ne 0 ]; then
    echo "[hb-core] RESULT: FAIL"; exit 1
fi
echo "[hb-core] RESULT: PASS"
