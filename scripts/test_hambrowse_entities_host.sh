#!/usr/bin/env bash
# scripts/test_hambrowse_entities_host.sh — FAST, QEMU-free gate for the HTML
# character-reference tokenizer (lib/web/html/entities.ad) — W3C html5-parsing
# round.
#
# Covers the round's three tokenizer features, all decoded to their UTF-8 form
# during TEXT parsing and asserted on the reconstructed FLOW (never glyph-ink
# pixels):
#   1. EXPANDED named references — arrows / math / card-suits / extra Latin-1
#      punctuation (&larr; &ne; &infin; &spades; &check; &iexcl; …).
#   2. NUMERIC-reference sanitisation — the C1 range 0x80-0x9F is remapped via
#      the Windows-1252 table (the ubiquitous legacy &#151; -> em dash,
#      &#133; -> ellipsis, &#146; -> ') and lone surrogates / out-of-range map
#      to U+FFFD (replacement char).
#   3. LEGACY semicolon-less references — &amp &copy &reg &nbsp … match without
#      a trailing ';', but the match is suppressed before '=' / alphanumerics
#      so query strings (?a=1&reg=2) and words (&notanentity;) are untouched.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler — a regression in either
# target fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_entities_ext.html"
mkdir -p "$OUT"

echo "[hb-ent] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/ent_compile.log"; then
    echo "[hb-ent] FAIL: host harness did not compile"; cat "$OUT/ent_compile.log"; exit 1
fi
echo "[hb-ent] PASS host harness compiled -> $BIN"

echo "[hb-ent] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/ent_native.log"; then
    echo "[hb-ent] FAIL: native hambrowse did not compile"; cat "$OUT/ent_native.log"; exit 1
fi
echo "[hb-ent] PASS native hambrowse still compiles"

fail=0
D0="$OUT/ent_run.txt"
if ! "$BIN" "$FIX" 600 >"$D0" 2>&1; then
    echo "[hb-ent] FAIL: render exited non-zero"; cat "$D0"; exit 1
fi
grep '^FLOW' "$D0" || true

assert_grep() {   # literal-pattern message
    if grep -Fq -- "$1" "$D0"; then
        echo "[hb-ent] PASS $2"
    else
        echo "[hb-ent] FAIL $2 (missing: $1)"; fail=1
    fi
}

# 1. Expanded named references.
assert_grep 'FLOW  ARROWS ← ↑ → ↓ ↔'          "arrows &larr;/&uarr;/&rarr;/&darr;/&harr; decode"
assert_grep 'FLOW  MATHREL ≠ ≤ ≥ ≈ ≡ ∞'       "math relations &ne;/&le;/&ge;/&asymp;/&equiv;/&infin; decode"
assert_grep 'FLOW  MATHOP a − b ⋅ c √ d'       "math ops &minus;/&sdot;/&radic; decode"
assert_grep 'FLOW  SUITS ♠ ♣ ♥ ♦ ◊ ★'         "card suits &spades;/&clubs;/&hearts;/&diams;/&loz;/&starf; decode"
assert_grep 'FLOW  MARKS ✓ ✗ ‡ ‰'             "&check;/&cross;/&Dagger;/&permil; decode"
assert_grep 'FLOW  LATINX ¡ ¿ ¦ ¤ ¬A'          "extra Latin-1 &iexcl;/&iquest;/&brvbar;/&curren;/&not; decode"

# 2. Numeric-reference sanitisation.
# &#151; -> — (U+2014), &#133; -> … , &#146; -> ' , &#128; -> € , &#149; -> •
assert_grep "FLOW  WIN1252 — … ’ € •"          "Windows-1252 C1 remap (&#151; -> em dash, &#133; -> …, &#146; -> ', &#128; -> €, &#149; -> •)"
assert_grep 'FLOW  WIN1252HEX — …'             "hex C1 refs remap too (&#x97; -> —, &#x85; -> …)"
# Lone surrogate (&#xD800;) and out-of-range (&#x110000;) -> U+FFFD (�).
assert_grep 'FLOW  SURR � � end'               "surrogate / out-of-range numeric refs map to U+FFFD"
# Astral-plane (>U+FFFF) numeric refs decode to a real 4-byte UTF-8 code point,
# via BOTH decimal (&#127820; -> U+1F34C 🍌, &#128512; -> U+1F600 😀) and hex
# (&#x1F3A8; -> U+1F3A8 🎨) — surrogate-pair-free full-Unicode coverage.
assert_grep 'FLOW  ASTRAL 🍌 🎨 😀 end'         "astral-plane decimal + hex refs (&#127820;/&#x1F3A8;/&#128512;) decode to real code points"

# 3. Legacy semicolon-less references + ambiguous-ampersand guard.
assert_grep 'FLOW  LEGACY fish & chips © 2026' "legacy &amp / &copy (no ';', followed by space) decode"
assert_grep '® pending'                         "legacy &reg (no ';') decodes"
assert_grep 'FLOW  LEGACYURL go?a=1&reg=2&amp=3 done' "ampersand before '=' is left literal (?a=1&reg=2 URL untouched)"
assert_grep 'FLOW  NOTENT &notanentity; kept &notreal here' "&not is NOT matched inside a longer word (ambiguous-ampersand guard)"

if [ "$fail" -ne 0 ]; then
    echo "[hb-ent] RESULT: FAIL"; exit 1
fi
echo "[hb-ent] RESULT: PASS"
