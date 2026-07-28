#!/usr/bin/env bash
# scripts/test_hambrowse_entities2_host.sh — FAST, QEMU-free gate for the HTML
# character-reference tokenizer (lib/web/html/entities.ad), W3C html5-parsing
# round 2. Round-2 additions on top of the round-1 set:
#   * Greek letters — uppercase &Alpha;..&Omega; (U+0391..) and lowercase
#     &alpha;..&omega; (U+03B1..) plus the variants &sigmaf;/&thetasym;/&upsih;/
#     &piv;. Ubiquitous in math/science copy. Prefix pairs (&sigma; vs
#     &sigmaf;, &eta; vs &theta;) must not cross-match — the trailing ';' in
#     each literal anchors the match.
#   * Double-struck arrows (&lArr;..&hArr;) + set-theory / logic relations
#     (&forall; &isin; &cap; &sub; &sube; &cong; &perp; …).
#   * Accented Latin-1 letters — case-sensitive &Aacute;/&auml;/&ntilde;/… so
#     café / résumé / Señor / Zürich render.
#
# Asserts on the reconstructed FLOW (decoded UTF-8 text, never glyph-ink
# pixels). Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_entities2.html"
mkdir -p "$OUT"

echo "[hb-e2] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/e2_compile.log"; then
    echo "[hb-e2] FAIL: host harness did not compile"; cat "$OUT/e2_compile.log"; exit 1
fi
echo "[hb-e2] PASS host harness compiled -> $BIN"

echo "[hb-e2] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/e2_native.log"; then
    echo "[hb-e2] FAIL: native hambrowse did not compile"; cat "$OUT/e2_native.log"; exit 1
fi
echo "[hb-e2] PASS native hambrowse still compiles"

fail=0
D0="$OUT/e2_run.txt"
if ! "$BIN" "$FIX" 600 >"$D0" 2>&1; then
    echo "[hb-e2] FAIL: render exited non-zero"; cat "$D0"; exit 1
fi
grep '^FLOW' "$D0" || true

assert_grep() {   # literal-pattern message
    if grep -Fq -- "$1" "$D0"; then
        echo "[hb-e2] PASS $2"
    else
        echo "[hb-e2] FAIL $2 (missing: $1)"; fail=1
    fi
}

# Greek uppercase + lowercase + variant sigma.
assert_grep 'GREEKUP Α Β Γ Δ Θ Σ Φ Ω'   "uppercase Greek &Alpha;..&Omega; decode"
assert_grep 'GREEKLO α β γ δ θ π σ ω'    "lowercase Greek &alpha;..&omega; decode"
assert_grep 'GREEKVAR μ ν ξ ρ τ φ ψ ς'   "&mu;/&nu;/&xi;/&rho;/&tau;/&phi;/&psi;/&sigmaf; decode"
# Prefix disambiguation: &sigma; and &sigmaf; are distinct; &eta;/&theta; too.
assert_grep 'PREFIX σ=ς η/θ ok'           "prefix pairs (&sigma; vs &sigmaf;, &eta; vs &theta;) do not cross-match"

# Double-struck arrows + set-theory / logic relations.
assert_grep 'DBLARR ⇐ ⇑ ⇒ ⇓ ⇔'          "double arrows &lArr;/&uArr;/&rArr;/&dArr;/&hArr; decode"
assert_grep 'LOGIC ∀ ∃ ∅ ∇ ∈ ∉ ∧ ∨'    "logic &forall;/&exist;/&empty;/&nabla;/&isin;/&notin;/&and;/&or; decode"
assert_grep 'SETREL ∩ ∪ ⊂ ⊃ ⊆ ⊇ ≅ ⊥'   "set relations &cap;/&cup;/&sub;/&sup;/&sube;/&supe;/&cong;/&perp; decode"

# Accented Latin-1 letters (case-sensitive; common in names / loanwords).
assert_grep 'ACCENTS café résumé naïve Señor Zürich' "lowercase accented letters &eacute;/&iuml;/&ntilde;/&uuml; decode in words"
assert_grep 'ACCUP Á Ç Ñ Ö Ü Æ Ø Þ'                 "uppercase accented letters &Aacute;/&Ccedil;/&Ntilde;/&Ouml;/&Uuml;/&AElig;/&Oslash;/&THORN; decode"

if [ "$fail" -ne 0 ]; then
    echo "[hb-e2] RESULT: FAIL"; exit 1
fi
echo "[hb-e2] RESULT: PASS"
