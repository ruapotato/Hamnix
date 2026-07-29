#!/usr/bin/env bash
# scripts/test_hambrowse_implicitbody_host.sh — FAST, QEMU-free gate for the
# IMPLIED <body> (browser W3C campaign, dom-core round). test_hambrowse_domcore
# proves document.body/head/documentElement resolve on a page with EXPLICIT
# <html>/<head>/<body> tags. This gate covers the harder HTML5 tree-construction
# edge: a document whose only content is head-only (bare text and/or a single
# <script>, no element that forces the head closed). There the implied <body>
# open-tag splice point lands at end-of-source, which the tag-inserter's main
# `while k < src_len` loop skipped — the closing </body> WAS flushed at the tail
# but the opening <body> never was, so the source read `<head>...</body></html>`
# and document.body came back undefined (while head/documentElement resolved).
# This gate asserts document.body resolves to a real BODY node, is the same
# object querySelector('body') returns, and that appendChild / closest / matches
# all reach the implied body.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot. Exact-output oracle on console.log lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_implicitbody.html"
mkdir -p "$OUT"

echo "[hb-ibody] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/ibody_compile.log"; then
    echo "[hb-ibody] FAIL: host harness did not compile"; cat "$OUT/ibody_compile.log"; exit 1
fi
echo "[hb-ibody] PASS host harness compiled -> $BIN"

echo "[hb-ibody] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/ibody_native.log"; then
    echo "[hb-ibody] FAIL: native hambrowse did not compile"; cat "$OUT/ibody_native.log"; exit 1
fi
echo "[hb-ibody] PASS native hambrowse still compiles"

fail=0
D0="$OUT/ibody_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-ibody] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-ibody] PASS $2"
    else
        echo "[hb-ibody] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-ibody] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-ibody] PASS $2"
    fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# ---- the implied document roots ALL resolve to real element nodes --------
assert_grep '^JSLOG iroots HTML BODY HEAD$' "document.body/head/documentElement resolve to real nodes on a head-only page (implied <body>)"
assert_grep '^JSLOG ibodyqs true$'          "the implied document.body IS the object querySelector('body') returns"

# ---- appendChild / closest / matches all reach the implied body ----------
assert_grep '^JSLOG iappend BODY$'          "appendChild into the implied body threads child.parentNode -> BODY"
assert_grep '^JSLOG iclosest true$'         "closest('body') on a node under the implied body returns document.body"
assert_grep '^JSLOG imatches true$'         "matches('#implanted') is true on the appended node"

# ---- no uncaught error (a missing document.body throws on .appendChild) ---
assert_nogrep '^JSERR'   "no uncaught JS error (undefined document.body would throw)"
assert_nogrep 'Uncaught' "no 'Uncaught' TypeError from a missing implied <body>"

# SCOPED-OUT: the head-only fixture's implied <body> is a ZERO-LENGTH span at
# end-of-source (there is no body-level content), so it has no layout region to
# render an appended node INTO. The DOM is fully correct there (append/closest/
# matches all resolve above) — appendChild no longer throws — but RENDER of a
# node grafted onto a literally-empty implied body needs a layout-region plumb
# that is out of scope for this DOM-core fix. The realistic case (an implied
# <body> that DOES have body-level content, so its region is non-degenerate)
# both threads the DOM AND renders — asserted below against fixture 2.
FIX2="tests/fixtures/hambrowse_implicitbody2.html"
D2="$OUT/ibody2_run.txt"
"$BIN" "$FIX2" 880 >"$D2" 2>&1 || { echo "[hb-ibody] FAIL: fixture2 render exited non-zero"; cat "$D2"; exit 1; }
grep -E 'JSLOG|JSERR' "$D2" || true
if grep -Eq -- '^JSLOG i2roots HTML BODY HEAD$' "$D2"; then
    echo "[hb-ibody] PASS implied <body> WITH content resolves the document roots"
else
    echo "[hb-ibody] FAIL implied <body> WITH content resolves the document roots"; fail=1
fi
if grep -Eq -- '^JSLOG i2append BODY$' "$D2"; then
    echo "[hb-ibody] PASS appendChild into a content-bearing implied body threads parentNode -> BODY"
else
    echo "[hb-ibody] FAIL appendChild into a content-bearing implied body threads parentNode -> BODY"; fail=1
fi
if grep -Eq -- 'APPENDED-INTO-IMPLIED-BODY-2' "$D2"; then
    echo "[hb-ibody] PASS the node appended into a content-bearing implied body RENDERS"
else
    echo "[hb-ibody] FAIL the node appended into a content-bearing implied body RENDERS"; fail=1
fi

if [ "$fail" = 0 ]; then
    echo "[hb-ibody] RESULT: PASS"
else
    echo "[hb-ibody] RESULT: FAIL"; exit 1
fi
