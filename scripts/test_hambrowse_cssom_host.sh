#!/usr/bin/env bash
# scripts/test_hambrowse_cssom_host.sh — FAST, QEMU-free gate for RUNTIME CSSOM
# stylesheet mutation feeding back into the cascade (browser campaign: the
# "run most websites" JS-driven-reveal gap). Real pages (e.g. google's
# `.gb_R{display:none}` -> injected `.gb_R{display:block}`) reveal content by
# MUTATING stylesheets at runtime; this proves the engine re-cascades so a
# `display:none` element becomes visible after the JS runs:
#   1. CSSStyleSheet.insertRule() on document.styleSheets[0]  -> `.ins` shows.
#   2. new CSSStyleSheet()+replaceSync()+document.adoptedStyleSheets -> `.adopt` shows.
#   3. createElement('style')+textContent+head.appendChild()   -> `.dyn` shows.
#   4. insertRule() then deleteRule() the same rule            -> `.del` STAYS hidden.
#   A `.keep` control stays hidden (display:none really hides), and the STATIC
#   fixture (same markup, no <script>) proves all four markers are ABSENT until
#   the JS runs — the reveal is the mutation's effect, not a rendering accident.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot. Exact-output oracle on SEG/console lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_cssom.html"
STATIC="tests/fixtures/hambrowse_cssom_static.html"
mkdir -p "$OUT"

echo "[hb-cssom] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/cssom_compile.log"; then
    echo "[hb-cssom] FAIL: host harness did not compile"; cat "$OUT/cssom_compile.log"; exit 1
fi
echo "[hb-cssom] PASS host harness compiled -> $BIN"

echo "[hb-cssom] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/cssom_native.log"; then
    echo "[hb-cssom] FAIL: native hambrowse did not compile"; cat "$OUT/cssom_native.log"; exit 1
fi
echo "[hb-cssom] PASS native hambrowse still compiles"

fail=0
D0="$OUT/cssom_run.txt"
DS="$OUT/cssom_static.txt"
"$BIN" "$FIX"    900 >"$D0" 2>&1 || { echo "[hb-cssom] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
"$BIN" "$STATIC" 900 >"$DS" 2>&1 || { echo "[hb-cssom] FAIL: static render exited non-zero"; cat "$DS"; exit 1; }

apass() {   # file pattern message
    if grep -Eq -- "$2" "$1"; then echo "[hb-cssom] PASS $3"
    else echo "[hb-cssom] FAIL $3 (missing: $2 in $1)"; fail=1; fi
}
anot() {    # file pattern message
    if grep -Eq -- "$2" "$1"; then echo "[hb-cssom] FAIL $3 (present: $2 in $1)"; fail=1
    else echo "[hb-cssom] PASS $3"; fi
}

grep -E 'JSLOG|JSERR' "$D0" || true

# ---- BEFORE: every marker hidden without the mutating script ----
anot "$DS" 'CSSOM-INSERTRULE-SHOWN' "static (no JS): insertRule target starts display:none (hidden)"
anot "$DS" 'CSSOM-ADOPTED-SHOWN'    "static (no JS): adoptedStyleSheets target starts hidden"
anot "$DS" 'CSSOM-DYNSTYLE-SHOWN'   "static (no JS): dynamic-<style> target starts hidden"
anot "$DS" 'CSSOM-DELETERULE-HIDDEN' "static (no JS): deleteRule target starts hidden"

# ---- no uncaught error across the mutation script ----
anot "$D0" '^JSERR'   "no uncaught JS error across the CSSOM mutation script"
anot "$D0" 'Uncaught' "no 'Uncaught' TypeError from a missing CSSOM API"

# ---- the CSSOM surface is wired ----
apass "$D0" '^JSLOG SSLEN 1$'      "document.styleSheets exposes the one <style> sheet"
apass "$D0" '^JSLOG PRERULES 5$'   "cssRules reflects the 5 source rules before insertRule"
apass "$D0" '^JSLOG POSTRULES 6$'  "insertRule grows cssRules to 6"
apass "$D0" '^JSLOG ADOPTRULES 1$' "replaceSync populates the constructible sheet's cssRules"
apass "$D0" '^JSLOG ADOPTLEN 1$'   "document.adoptedStyleSheets holds the adopted sheet"
apass "$D0" '^JSLOG FINALRULES 6$' "deleteRule shrinks cssRules back after the temporary insert"

# ---- AFTER: the mutation re-cascades and the elements RENDER ----
apass "$D0" 'CSSOM-INSERTRULE-SHOWN' "insertRule('.ins{display:block}') un-hides the element"
apass "$D0" 'CSSOM-ADOPTED-SHOWN'    "adoptedStyleSheets + replaceSync un-hides the element"
apass "$D0" 'CSSOM-DYNSTYLE-SHOWN'   "dynamically-appended <style> un-hides the element"

# ---- deleteRule really removes the rule from the cascade (stays hidden) ----
anot "$D0" 'CSSOM-DELETERULE-HIDDEN' "deleteRule removes the reveal rule -> element stays hidden"
# ---- a never-touched display:none control stays hidden ----
anot "$D0" 'CSSOM-CONTROL-HIDDEN'    "an unmutated display:none element stays hidden"

if [ "$fail" -ne 0 ]; then
    echo "[hb-cssom] RESULT: FAIL"; exit 1
fi
echo "[hb-cssom] RESULT: PASS"
