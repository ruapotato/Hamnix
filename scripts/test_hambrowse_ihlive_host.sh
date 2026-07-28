#!/usr/bin/env bash
# scripts/test_hambrowse_ihlive_host.sh — FAST, QEMU-free gate for the LIVE DOM:
# innerHTML as a re-serialisation of the CURRENT tree (not a slice of the
# original source), and the IMPLIED elements the HTML5 tree builder inserts.
#
# WHY THIS EXISTS
# ===============
# The DOM is anchored to byte spans in the source, so for a long time an
# element's innerHTML was literally src[cstart..cend) — correct at parse time
# and frozen forever after. Measured against chromium --headless on this very
# fixture, EVERY script mutation was invisible: appendChild, a descendant's
# textContent= and removeChild all read back the untouched markup. Only
# `innerHTML =` worked, because that path stored an override.
#
# The same span anchoring meant a node with NO start tag in the source — the
# <html>/<head>/<body>/<tbody> the tree builder implies — could not exist at
# all, so the element census came up short by exactly those nodes.
#
# ORACLE
# ======
# Every expected value below was produced by chromium --headless --dump-dom
# running THIS fixture with the same assertions written into document.title
# (2026-07-28). They are not guesses; each line is chromium's own answer.
#
#   tags 14   tbody 1   documentElement HTML   body.children 4 (first DIV)
#   initial      <p id="p1">one</p><span>two</span>
#   append       <p id="p1">one</p><span>two</span><b>NEW</b>
#   textcontent  <p id="p1">CHANGED</p><span>two</span><b>NEW</b>
#   remove       <span>two</span><b>NEW</b>
#   assign       <i>set</i>
#   sibling      <i>keep</i>          (an UNMUTATED element still reads its slice)
#   hidden       present              (display:none is NOT removal — a browser
#                                      still serialises a hidden element)
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) so a regression in either target fails here with NO QEMU.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_innerhtml_live.html"
mkdir -p "$OUT"

echo "[hb-ihlive] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/ihlive_compile.log"; then
    echo "[hb-ihlive] FAIL: host harness did not compile"
    cat "$OUT/ihlive_compile.log"; exit 1
fi
echo "[hb-ihlive] PASS host harness compiled -> $BIN"

echo "[hb-ihlive] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/ihlive_native.elf" 2>"$OUT/ihlive_native.log"; then
    echo "[hb-ihlive] FAIL: native hambrowse did not compile"
    cat "$OUT/ihlive_native.log"; exit 1
fi
echo "[hb-ihlive] PASS native hambrowse still compiles"

fail=0
D0="$OUT/ihlive_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-ihlive] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG IH|JSERR' "$D0" || true

assert_line() {   # exact-line pattern, message
    if grep -Fxq -- "JSLOG $1" "$D0"; then
        echo "[hb-ihlive] PASS $2"
    else
        echo "[hb-ihlive] FAIL $2 (missing exact line: JSLOG $1)"; fail=1
    fi
}

# ---- implied elements (measured on the UNTOUCHED tree) ----------------------
assert_line 'IH tags :: 14'      "element census matches chromium (implied <html>+<head>+<tbody> counted)"
assert_line 'IH tbody :: 1'      "the <table> with no <tbody> in source still has one in the DOM"
assert_line 'IH htmlel :: HTML'  "document.documentElement is the (implied-capable) <html>"
assert_line 'IH bodykids :: 4'   "document.body.children is a live collection of 4 (was undefined)"
assert_line 'IH bodykid0 :: DIV' "body.children[0] is the first DIV"

# ---- live innerHTML ---------------------------------------------------------
assert_line 'IH initial :: <p id="p1">one</p><span>two</span>' \
    "initial innerHTML is the source slice"
assert_line 'IH append :: <p id="p1">one</p><span>two</span><b>NEW</b>' \
    "appendChild is VISIBLE to innerHTML"
assert_line 'IH textcontent :: <p id="p1">CHANGED</p><span>two</span><b>NEW</b>' \
    "a descendant's textContent= is VISIBLE to innerHTML"
assert_line 'IH remove :: <span>two</span><b>NEW</b>' \
    "removeChild of a SOURCE child is VISIBLE to innerHTML"
assert_line 'IH assign :: <i>set</i>' \
    "innerHTML= still reads back what was assigned"
assert_line 'IH sibling :: <i>keep</i>' \
    "an unmutated element still reads back its exact source slice"
assert_line 'IH hidden :: present' \
    "display:none is not removal — a hidden element is still serialised"

if grep -q '^JSERR' "$D0"; then
    echo "[hb-ihlive] FAIL uncaught JS error during the live-DOM walk"
    grep '^JSERR' "$D0"; fail=1
else
    echo "[hb-ihlive] PASS no uncaught JS error"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-ihlive] RESULT: FAIL"; exit 1
fi
echo "[hb-ihlive] RESULT: PASS — innerHTML re-serialises the live tree and the implied elements exist"
