#!/usr/bin/env bash
# scripts/test_hambrowse_template_host.sh — FAST, QEMU-free gate that <template>
# CONTENTS ARE INERT on BOTH surfaces: they never render, and they never appear
# in an ancestor's textContent.
#
# WHY: <template> children are parsed into a SEPARATE document fragment ("template
# contents"). They are not part of the document tree — only script reaching
# through .content sees them. We treated them as ordinary markup, so:
#   * LAYOUT laid them out. On tests/fixtures/realsites/mdn_html.html (23
#     templates holding ~59.7 KiB of theme-switcher / language-menu widgets) the
#     real article text was shoved rightward and interleaved with phantom UI
#     (segs 1069->986, rows 612->604, links 461->450).
#   * The DOM TEXT VIEW included them: mdn_html body.textContent reported 79356
#     chars where chromium reports 27320 — over by 52036.
# Templates are ubiquitous on modern (web-component / framework) pages, so both
# surfaces matter for real-website reach.
#
# EXPECTATIONS ARE CHROMIUM-VERIFIED. `chromium --headless --dump-dom` on
# tests/fixtures/hambrowse_template.html (console lines routed into the title):
#   TPL t1=[ALPHAOMEGA] | TPL t2=[BETAGAMMA] | TPL t3=[DELTAEPSILON] |
#   TPL t4=[ZETAETA] | TPL after=[TAILVISIBLE]
# Every assertion below is that value byte-for-byte.
#
# The fixture also plants the traps that broke the first cut of this fix:
# NESTED templates, a "</template>" inside a <script> STRING LITERAL (raw text —
# it must not end the skip early, which it did in the LAYOUT scanner even after
# the DOM view was correct), and a '>' inside a quoted attribute on the
# <template> start tag itself.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler — a regression in either
# target fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_template.html"
mkdir -p "$OUT"

echo "[hb-tpl] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/tpl_compile.log"; then
    echo "[hb-tpl] FAIL: host harness did not compile"; cat "$OUT/tpl_compile.log"; exit 1
fi
echo "[hb-tpl] PASS host harness compiled -> $BIN"

echo "[hb-tpl] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/tpl_native.log"; then
    echo "[hb-tpl] FAIL: native hambrowse did not compile"; cat "$OUT/tpl_native.log"; exit 1
fi
echo "[hb-tpl] PASS native hambrowse still compiles"

D0="$OUT/tpl_run.txt"
if ! "$BIN" "$FIX" 700 >"$D0" 2>&1; then
    echo "[hb-tpl] FAIL: render exited non-zero"; cat "$D0"; exit 1
fi
grep -E '^JSLOG TPL|JSERR' "$D0" || true

fail=0
assert_grep() {   # literal-pattern message
    if grep -Fq -- "$1" "$D0"; then
        echo "[hb-tpl] PASS $2"
    else
        echo "[hb-tpl] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # literal-pattern message
    if grep -Fq -- "$1" "$D0"; then
        echo "[hb-tpl] FAIL $2 (leaked: $1)"; fail=1
    else
        echo "[hb-tpl] PASS $2"
    fi
}

# ---- DOM TEXT VIEW: chromium's exact values. --------------------------------
assert_grep 'TPL t1=[ALPHAOMEGA]'    "textContent skips template contents"
assert_grep 'TPL t2=[BETAGAMMA]'     "textContent skips NESTED template contents"
assert_grep 'TPL t3=[DELTAEPSILON]'  "a '</template>' in a <script> string literal does not end the skip"
assert_grep 'TPL t4=[ZETAETA]'       "a '>' in a quoted attr on the <template> tag does not end it early"
assert_grep 'TPL after=[TAILVISIBLE]' "content AFTER the templates is still reachable"

# ---- LAYOUT: the same contents must not reach the rendered flow. ------------
# (These were the residual: the DOM view was already correct while the layout
# scanner still fell for the raw-text trap and leaked the tail into the flow.)
assert_grep 'FLOW  ALPHAOMEGA'   "template contents do not render (t1)"
assert_grep 'FLOW  BETAGAMMA'    "nested template contents do not render (t2)"
assert_grep 'FLOW  DELTAEPSILON' "raw-text trap does not leak the template tail into the flow (t3)"
assert_grep 'FLOW  ZETAETA'      "quoted-attr template tag does not leak into the flow (t4)"
assert_grep 'FLOW  TAILVISIBLE'  "content after the templates still renders"

assert_nogrep 'TPLHIDDEN'   "no t1 template text anywhere in the output"
assert_nogrep 'B2NESTED'    "no nested-template text anywhere in the output"
assert_nogrep 'T3HIDDEN'    "no post-raw-text template text anywhere in the output"
assert_nogrep 'T4HIDDEN'    "no quoted-attr template text anywhere in the output"
assert_nogrep 'not a real close' "the <script> string literal never reaches the flow"
assert_nogrep 'JSERR'       "no script error"

if [ "$fail" -ne 0 ]; then
    echo "[hb-tpl] RESULT: FAIL"; exit 1
fi
echo "[hb-tpl] RESULT: PASS"
