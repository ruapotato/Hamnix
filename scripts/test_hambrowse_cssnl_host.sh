#!/usr/bin/env bash
# scripts/test_hambrowse_cssnl_host.sh — FAST, QEMU-free gate for bug #250:
# the CSS property matcher (_prop_is / _prop_prefix) and the value-start skip
# (_val_start / _val_starts) trimmed spaces + tabs but NOT newlines, so a rule
# formatted across lines — the overwhelmingly common authoring style —
#   .multi {
#     color: #00ff00;        <- property name preceded by '\n    '
#     font-weight: bold;     <- second decl after ';\n'
#   }
#   .valwrap { color:
#     #ff8800; }             <- value continues on the next line
# failed to apply, because the trimmed name/value region still led with a '\n'.
# The whitespace class now includes '\n'/'\r' everywhere the matcher trims.
# This gate asserts a multi-line-formatted rule applies (colour + weight) and
# a value-on-next-line applies, via SEG colour/bold readback (stable chrome,
# NOT a glyph-ink pixel).
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_cssnl.html"
mkdir -p "$OUT"

echo "[hb-cssnl] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/cssnl_compile.log"; then
    echo "[hb-cssnl] FAIL: host harness did not compile"; cat "$OUT/cssnl_compile.log"; exit 1
fi
echo "[hb-cssnl] PASS host harness compiled -> $BIN"

echo "[hb-cssnl] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/cssnl_native.log"; then
    echo "[hb-cssnl] FAIL: native hambrowse did not compile"; cat "$OUT/cssnl_native.log"; exit 1
fi
echo "[hb-cssnl] PASS native hambrowse still compiles"

fail=0
D0="$OUT/cssnl_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-cssnl] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-cssnl] PASS $2"
    else
        echo "[hb-cssnl] FAIL $2 (missing: $1)"; fail=1
    fi
}

grep -E 'SEG' "$D0" || true

# .multi: first decl (color, preceded by a newline) AND second decl (font-weight
# after ';\n') both apply -> green text (#00ff00) and bold (b1).
assert_grep '^SEG .*#00ff00 b1 .*\|multi line rule green bold\|' \
    "multi-line rule: color (#00ff00) + font-weight:bold both match across newlines"

# .valwrap: the value on the next line applies -> orange (#ff8800).
assert_grep '^SEG .*#ff8800 .*\|value continues on next line\|' \
    "value continued on the next line applies (#ff8800)"

# control paragraph keeps the default near-black text colour (no bleed).
assert_grep '^SEG .*#101010 b0 .*\|plain control paragraph\|' \
    "plain paragraph unaffected (default colour, not bold)"

if [ "$fail" -ne 0 ]; then
    echo "[hb-cssnl] RESULT: FAIL"; exit 1
fi
echo "[hb-cssnl] RESULT: PASS"
