#!/usr/bin/env bash
# scripts/test_hambrowse_ceilings_host.sh — FAST, QEMU-free gate that the
# engine's per-page CEILINGS REPORT THEMSELVES.
#
# WHY THIS IS A GATE AND NOT A COMMENT: every one of these limits used to be
# crossed in complete silence. Past DOM_MAX, _dom_register_el handed script a
# bare `undefined`, so `document.getElementsByTagName("*")` reported the right
# length while entries past the cap were undefined and the PAGE's own
# `a[i].getAttribute(...)` loop threw — a bug that looked like it lived in the
# website. Past EVL_MAX, addEventListener returned normally and the handler
# simply never fired. A silent ceiling cannot be sized against evidence, and a
# raised-but-still-silent ceiling only moves the cliff; this gate is what keeps
# them loud when someone changes the numbers.
#
# The fixture deliberately overflows both: 9000 <i> elements (> DOM_MAX) and
# 1200 addEventListener calls on one element (> EVL_MAX).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_ceilings.html"
mkdir -p "$OUT"

echo "[hb-ceil] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/ceil_compile.log"; then
    echo "[hb-ceil] FAIL: host harness did not compile"; cat "$OUT/ceil_compile.log"; exit 1
fi
echo "[hb-ceil] PASS host harness compiled -> $BIN"

D0="$OUT/ceil_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-ceil] FAIL: render exited non-zero"; exit 1; }
grep -E 'CEILING|^JSLOG (count|undef|done)' "$D0" || true

fail=0
assert_grep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-ceil] PASS $2"
    else echo "[hb-ceil] FAIL $2 (missing: $1)"; fail=1; fi
}

assert_grep '^JSLOG \[engine\] CEILING DOM_MAX reached.*DOM_MAX=[0-9]+$' \
            "DOM_MAX overflow names itself AND prints its size"
assert_grep '^JSLOG \[engine\] CEILING EVL_MAX reached.*EVL_MAX=[0-9]+$' \
            "EVL_MAX overflow names itself AND prints its size"
assert_grep '^JSLOG undef>0 true$' \
            "past DOM_MAX elements really are undefined (the condition being reported is real)"
assert_grep '^JSLOG done$' \
            "the page keeps running past both ceilings (report, do not abort)"

# Latched: ONE line per ceiling per page, not one per overflowing element.
nd="$(grep -c 'CEILING DOM_MAX' "$D0")"
ne="$(grep -c 'CEILING EVL_MAX' "$D0")"
if [ "$nd" = 1 ] && [ "$ne" = 1 ]; then
    echo "[hb-ceil] PASS each ceiling reports exactly once (latched)"
else
    echo "[hb-ceil] FAIL expected 1 line each, got DOM_MAX=$nd EVL_MAX=$ne"; fail=1
fi

if [ "$fail" -eq 0 ]; then echo "[hb-ceil] RESULT: PASS"; exit 0; fi
echo "[hb-ceil] RESULT: FAIL"; exit 1
