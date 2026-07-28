#!/usr/bin/env bash
# scripts/test_hambrowse_utf16dom_host.sh — FAST, QEMU-free gate that DOM text
# reaching JavaScript obeys UTF-16 CODE-UNIT semantics, end to end.
#
# WHY: strings are STORED as UTF-8 bytes. Character entities (&nbsp; &copy;
# &eacute; &mdash; &euro; &#8212; &#x1D11E;) are exactly how real pages produce
# non-ASCII text, so `el.textContent.length`, `.indexOf`, `.charCodeAt` and
# `.slice` over that text were reading BYTES: hackernews' body textContent
# measured 3886 instead of chromium's 3839, and `.slice` returned FRAGMENTS of
# a UTF-8 sequence — invalid strings that then propagated silently. This is the
# DOM-side companion to scripts/test_jsengine_utf16_host.sh.
#
# EVERY EXPECTED LINE BELOW IS A MEASURED `chromium --headless --dump-dom`
# VALUE for this exact fixture (console lines routed into document.title).
# Note s.spread: split("") counts code UNITS (4) while Array.from counts code
# POINTS (2) — chromium disagrees with itself there on purpose, and so must we.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_utf16dom.html"
mkdir -p "$OUT"

echo "[hb-utf16dom] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/utf16dom_compile.log"; then
    echo "[hb-utf16dom] FAIL: host harness did not compile"; cat "$OUT/utf16dom_compile.log"; exit 1
fi
echo "[hb-utf16dom] PASS host harness compiled -> $BIN"

echo "[hb-utf16dom] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/utf16dom_native.log"; then
    echo "[hb-utf16dom] FAIL: native hambrowse did not compile"; cat "$OUT/utf16dom_native.log"; exit 1
fi
echo "[hb-utf16dom] PASS native hambrowse still compiles"

D0="$OUT/utf16dom_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-utf16dom] FAIL: render exited non-zero"; exit 1; }
grep -E 'JSLOG|JSERR' "$D0" || true

fail=0
assert_line() {
    if grep -Fqx -- "JSLOG $1" "$D0"; then echo "[hb-utf16dom] PASS $2"
    else echo "[hb-utf16dom] FAIL $2"; echo "    want: JSLOG $1"; fail=1; fi
}

if grep -q 'JSERR' "$D0"; then echo "[hb-utf16dom] FAIL script raised JSERR"; fail=1; fi

assert_line "d.len 16" "d.len matches chromium"
assert_line "d.iof 4" "d.iof matches chromium"
assert_line "d.cca1 160" "d.cca1 matches chromium"
assert_line "d.slice b" "d.slice matches chromium"
assert_line "d.split 16" "d.split matches chromium"
assert_line "d.last 56606" "d.last matches chromium"
assert_line "p.len 10" "p.len matches chromium"
assert_line "p.words 4,5" "p.words matches chromium"
assert_line "p.upper CAF" "p.upper matches chromium"
assert_line "p.at ée" "p.at matches chromium"
assert_line "s.len 4" "s.len matches chromium"
assert_line "s.cp 119070,55348,56606" "s.cp matches chromium"
assert_line "s.spread 4,2" "s.spread matches chromium"
assert_line "s.half 1,true" "s.half matches chromium"
assert_line "re.dot 3,é" "re.dot matches chromium"
assert_line "re.index 2" "re.index matches chromium"

if [ "$fail" -eq 0 ]; then
    echo "[hb-utf16dom] ALL PASS"
    exit 0
fi
echo "[hb-utf16dom] FAILURES present"
exit 1
