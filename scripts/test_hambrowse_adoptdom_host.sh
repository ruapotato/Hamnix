#!/usr/bin/env bash
# scripts/test_hambrowse_adoptdom_host.sh — FAST, QEMU-free gate for the HTML5
# adoption-agency / reconstruct-the-active-formatting-elements recovery at the
# DOM-TREE layer (WHATWG tree construction), in the modular web engine
# (lib/web/dom/domtree.ad _adoption_fixup). Browser W3C campaign.
#
# The companion gate test_hambrowse_adoption asserts the VISUAL (bold/italic)
# result of a misnest via SEGFLAGS. This gate asserts the DOM NODE TREE the
# scripts see: for  <b>A<i>B</b>C</i>  the spec DOM is  <b>A<i>B</i></b><i>C</i>
# — i.e. the "C" text lives in a RECONSTRUCTED <i> that is a SIBLING of the <b>
# (child of the same parent), NOT a child of <b>. A naive depth-counter would
# leave "C" nested inside the single <i> under <b>. Also proves the fix is not
# b/i-specific (em/strong) and that WELL-NESTED formatting is left untouched.
#
# Exact-output oracle on console.log lines. Builds the host harness
# (x86_64-linux) AND the native browser (x86_64-adder-user) so a regression in
# either target fails here with NO QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_adoptdom.html"
mkdir -p "$OUT"

echo "[hb-adoptdom] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/adoptdom_compile.log"; then
    echo "[hb-adoptdom] FAIL: host harness did not compile"
    cat "$OUT/adoptdom_compile.log"; exit 1
fi
echo "[hb-adoptdom] PASS host harness compiled -> $BIN"

echo "[hb-adoptdom] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/adoptdom_native.elf" 2>"$OUT/adoptdom_native.log"; then
    echo "[hb-adoptdom] FAIL: native hambrowse did not compile"
    cat "$OUT/adoptdom_native.log"; exit 1
fi
echo "[hb-adoptdom] PASS native hambrowse still compiles"

fail=0
D0="$OUT/adoptdom_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-adoptdom] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-adoptdom] PASS $2"
    else
        echo "[hb-adoptdom] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-adoptdom] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-adoptdom] PASS $2"
    fi
}

# --- Case 1: <b>A<i>B</b>C</i> ------------------------------------------------
assert_grep '^JSLOG c1 I B 1$'   "the <i> holding B is the SOLE child of <b> (tagName I, text B)"
assert_grep '^JSLOG c1r I C$'    "C lives in a RECONSTRUCTED <i> (tagName I, text C)"
assert_grep '^JSLOG c1p sib$'    "the reconstructed <i> is a SIBLING of <b> (same parentNode), not a child"

# --- Case 2: <em>P<strong>Q</em>R</strong> (not b/i-specific) -----------------
assert_grep '^JSLOG c2 STRONG Q 1$' "the <strong> holding Q is the sole child of <em>"
assert_grep '^JSLOG c2r STRONG R$'  "R lives in a reconstructed <strong>"
assert_grep '^JSLOG c2p sib$'       "the reconstructed <strong> is a sibling of <em>"

# --- Regression: well-nested <b><i>Z</i></b> untouched ------------------------
assert_grep '^JSLOG c3 1 none$'  "well-nested formatting is NOT split (one child, no reconstructed sibling)"

# --- No uncaught JS error ----------------------------------------------------
assert_nogrep '^JSERR'   "no uncaught JS error across the adoption tree-walk"
assert_nogrep 'Uncaught' "no 'Uncaught' from a missing traversal API"

if [ "$fail" -ne 0 ]; then
    echo "[hb-adoptdom] RESULT: FAIL"; exit 1
fi
echo "[hb-adoptdom] RESULT: PASS — misnested-inline recovery matches the spec adoption-agency DOM tree"
