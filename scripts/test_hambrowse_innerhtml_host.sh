#!/usr/bin/env bash
# scripts/test_hambrowse_innerhtml_host.sh — FAST, QEMU-free gate for the
# .innerHTML SETTER (browser campaign round 4). Frameworks and hand-rolled
# widgets build UI by assigning `el.innerHTML = "<...>"`; the round-3 engine
# only stashed the string for the raw-render path, so the assigned markup was
# invisible to the DOM (childNodes/tree walk saw the OLD children). This gate
# proves the setter now PARSES the fragment into REAL child nodes on the live
# tree, so a subsequent same-script read reflects the new subtree:
#   - childNodes length + per-node tagName / className / textContent / nodeType
#     (element nodes 1, text nodes 3), firstChild / lastChild
#   - the target's own textContent recomputed from the new subtree
#   - a NESTED fragment (<ul><li>..</li><li>..</li></ul>) exposing real child
#     arrays on the created descendants
#   - the assigned markup still RENDERS (the <b> lays out bold), proving the
#     raw-render path and the node model agree (SEG readback, not glyph ink).
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot. Exact-output oracle on console.log lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_innerhtml.html"
mkdir -p "$OUT"

echo "[hb-ih] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/ih_compile.log"; then
    echo "[hb-ih] FAIL: host harness did not compile"; cat "$OUT/ih_compile.log"; exit 1
fi
echo "[hb-ih] PASS host harness compiled -> $BIN"

echo "[hb-ih] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/ih_native.log"; then
    echo "[hb-ih] FAIL: native hambrowse did not compile"; cat "$OUT/ih_native.log"; exit 1
fi
echo "[hb-ih] PASS native hambrowse still compiles"

fail=0
D0="$OUT/ih_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-ih] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-ih] PASS $2"
    else
        echo "[hb-ih] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-ih] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-ih] PASS $2"
    fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# ---- fragment parsed into REAL child nodes -------------------------------
assert_grep '^JSLOG cn 3$'                 "innerHTML='<span>..<b>..</b> tail' -> 3 real child nodes (2 elem + 1 text)"
assert_grep '^JSLOG t0 SPAN a hi$'         "child 0 is <span class=a>hi</span>: tagName + className + textContent"
assert_grep '^JSLOG t1 B bold$'            "child 1 is <b>bold</b>: tagName + textContent"
assert_grep '^JSLOG t2 3  tail$'           "child 2 is a TEXT node (nodeType 3) carrying ' tail'"
assert_grep '^JSLOG htext hibold tail$'    "target textContent recomputed from the new subtree"
assert_grep '^JSLOG first SPAN last 3$'    "firstChild (<span>) + lastChild (text node) rewired"

# ---- nested fragment: real child arrays on created descendants -----------
assert_grep '^JSLOG ul UL kids 2$'         "<ul> child has 2 <li> children (nested parse)"
assert_grep '^JSLOG li0 LI one$'           "first <li> tagName + textContent"
assert_grep '^JSLOG li1 two$'              "second <li> textContent"
assert_grep '^JSLOG ultext onetwo$'        "<ul> textContent is the concatenation of its descendants"

# ---- no uncaught error ---------------------------------------------------
assert_nogrep '^JSERR'   "no uncaught JS error across the innerHTML script"
assert_nogrep 'Uncaught' "no 'Uncaught' TypeError from the setter path"

# ---- THE RENDER REFLECTION PROOF -----------------------------------------
# the parsed <b> must reach layout as a bold segment (SEG readback, stable
# chrome: bold flag b1 on the 'bold' word — NOT a glyph-ink pixel assertion).
assert_grep '^SEG .* b1 .*\|bold\|'  "innerHTML-assigned <b> renders bold"
assert_nogrep 'old inner'            "the original inner markup was dropped from the render"

if [ "$fail" -ne 0 ]; then
    echo "[hb-ih] RESULT: FAIL"; exit 1
fi
echo "[hb-ih] RESULT: PASS"
