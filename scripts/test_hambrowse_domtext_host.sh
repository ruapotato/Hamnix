#!/usr/bin/env bash
# scripts/test_hambrowse_domtext_host.sh — FAST, QEMU-free gate for the DOM TEXT
# VIEW: document.body.textContent, el.innerHTML, decoded character references,
# and the lazy style/classList/dataset accessors.
#
# WHY: all of this was measurably broken on real pages (round 9).
#   * Every element snapshotted its FULL textContent AND full raw innerHTML into
#     ONE shared 64 KiB buffer, so <html>/<body> exhausted it immediately and
#     document.body.textContent came back "" (archlinux "" vs chromium 6797
#     chars; react_spa 0 vs 144092). Both are lazy accessors now.
#   * _find_close counted "<body"/"</body>"/"<html" appearing inside <script>
#     STRING LITERALS and inside HTML COMMENTS as real markup, so on
#     books.toscrape.com (5x "<html") and google.com (3x "<body") the close tag
#     was never found and <body> got an EMPTY content span. The fixture plants
#     exactly those traps.
#   * _extract_text copied source bytes verbatim while the LAYOUT path decoded
#     entities, so script saw "a&nbsp;b &amp; c" where chromium hands back text.
#
# EXPECTATIONS ARE CHROMIUM-VERIFIED. `chromium --headless --dump-dom` on the
# same fixture (with the console lines routed into document.title) reports:
#   ent a<NBSP>b & c 'd' <e> © | dtext outer bold tail |
#   dhtml outer <b>bold</b> tail | ds card 7 | cls true x | sty red |
#   bodyhas true true | bodylen>500 true | htmllen>600 true
# Every line below is that value byte-for-byte, with ONE documented divergence:
# we decode &nbsp; to a normal space (U+0020), because the DOM text view reuses
# the RENDERER's entity table (lib/web/html/entities.ad), which maps it that way
# for layout. Chromium keeps U+00A0.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_domtext.html"
mkdir -p "$OUT"

echo "[hb-domtext] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/domtext_compile.log"; then
    echo "[hb-domtext] FAIL: host harness did not compile"; cat "$OUT/domtext_compile.log"; exit 1
fi
echo "[hb-domtext] PASS host harness compiled -> $BIN"

echo "[hb-domtext] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/domtext_native.log"; then
    echo "[hb-domtext] FAIL: native hambrowse did not compile"; cat "$OUT/domtext_native.log"; exit 1
fi
echo "[hb-domtext] PASS native hambrowse still compiles"

D0="$OUT/domtext_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-domtext] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E 'JSLOG|JSERR' "$D0" || true

fail=0
assert_grep() {
    if grep -Fqx -- "$1" "$D0"; then echo "[hb-domtext] PASS $2"
    else echo "[hb-domtext] FAIL $2 (missing exact line: $1)"; fail=1; fi
}

assert_grep "JSLOG ent a b & c 'd' <e> ©"          "character references decoded in textContent (&nbsp;->space, chromium keeps U+00A0)"
assert_grep "JSLOG dtext outer bold tail"          "textContent strips tags"
assert_grep "JSLOG dhtml outer <b>bold</b> tail"   "innerHTML returns the raw source span"
assert_grep "JSLOG ds card 7"                      "lazy el.dataset: data-role + camelCased data-item-id"
assert_grep "JSLOG cls true x"                     "lazy el.classList.contains + className"
assert_grep "JSLOG sty red"                        "lazy el.style is writable and reads back"
assert_grep "JSLOG bodyhas true true"              "body.textContent spans the WHOLE document incl. script source"
assert_grep "JSLOG bodylen>500 true"               "body.textContent is not truncated (the shared-64KB-arena bug)"
assert_grep "JSLOG htmllen>600 true"               "documentElement.innerHTML survives <body>/<html> traps in script + comments"

if grep -q '^JSERR' "$D0"; then
    echo "[hb-domtext] FAIL: the page's scripts errored"; fail=1
else
    echo "[hb-domtext] PASS no JSERR"
fi

# The page must still RENDER (the readback must not mistake an untouched <body>
# for a rewritten one and re-emit the document as flat escaped text).
if grep -Eq '^LAYOUT segs=[1-9]' "$D0"; then
    echo "[hb-domtext] PASS page still lays out (segs > 0)"
else
    echo "[hb-domtext] FAIL: LAYOUT produced no segments"; fail=1
fi

if [ "$fail" -eq 0 ]; then echo "[hb-domtext] RESULT: PASS"; exit 0; fi
echo "[hb-domtext] RESULT: FAIL"; exit 1
