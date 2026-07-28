#!/usr/bin/env bash
# scripts/test_hambrowse_pseudocss_host.sh — FAST, QEMU-free gate for CSS
# PSEUDO-CLASSES / PSEUDO-ELEMENTS in the native browser cascade
# (lib/web/css/cascade.ad). Before this round _parse_compound skipped ':' bytes
# entirely, so any ':pseudo' compound became an empty (match-everything) rule.
# This proves the pseudo family now parses AND evaluates in the stylesheet
# cascade:
#
#   :root          — matches <html> only (used as descendant ancestor);
#                    div:root matches nothing
#   :checked / :disabled / :required — boolean-attribute presence at an
#                    attribute-name boundary (data-checked / title="checked"
#                    must NOT match)
#   fieldset:disabled / fieldset:enabled — real-control enabled/disabled split
#   :nth-child(even|odd)             — zebra striping over <li>
#   :first-child                     — first list item only
#   :hover / :target                 — dynamic states are INERT in a static
#                                      render (never match)
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either backend is caught with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_pseudocss.html"
mkdir -p "$OUT"

echo "[hb-pseudocss] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/pseudocss_compile.log"; then
    echo "[hb-pseudocss] FAIL: host harness did not compile"; cat "$OUT/pseudocss_compile.log"; exit 1
fi
echo "[hb-pseudocss] PASS host harness compiled -> $BIN"

echo "[hb-pseudocss] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/pseudocss_native.log"; then
    echo "[hb-pseudocss] FAIL: native hambrowse did not compile"; cat "$OUT/pseudocss_native.log"; exit 1
fi
echo "[hb-pseudocss] PASS native hambrowse still compiles"

fail=0
D0="$OUT/pseudocss_run.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-pseudocss] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E '^FILL|^SEG' "$D0" || true

seg_line() { grep -E "^SEG [0-9]+ [0-9]+ .*\|$1\|" "$D0" | head -1; }

assert_seg() {    # text  regex  message
    local ln; ln="$(seg_line "$1")"
    if [ -z "$ln" ]; then
        echo "[hb-pseudocss] FAIL $3 (no segment for |$1|)"; fail=1; return
    fi
    if echo "$ln" | grep -Eq -- "$2"; then
        echo "[hb-pseudocss] PASS $3"
    else
        echo "[hb-pseudocss] FAIL $3 (seg: $ln)"; fail=1
    fi
}

assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-pseudocss] FAIL $2 (unexpected: $1)"; fail=1
    else
        echo "[hb-pseudocss] PASS $2"
    fi
}

# :root as ancestor matches <html>; div:root (red) matches nothing.
assert_seg "under root box" 'bg#a0b0c0' ":root ancestor matches <html>"
assert_nogrep '#ff0000'                 "div:root matches no element"

# boolean-state pseudo-classes match on attribute presence...
assert_seg "chk div" 'bg#11aa22'        ":checked matches the checked attribute"
assert_seg "dis div" 'bg#334455'        ":disabled matches the disabled attribute"
assert_seg "req div" 'bg#cc7700'        ":required matches the required attribute"
# ...and only at an attribute-name boundary (negatives).
assert_seg "plain div"          'bg- '  "plain element is not matched by any state pseudo"
assert_seg "datacheck div"      'bg- '  ":checked does NOT match data-checked"
assert_seg "quoted checked div" 'bg- '  ":checked does NOT match title=\"checked ...\""

# real form control: fieldset:disabled vs fieldset:enabled.
assert_seg "fs disabled child" 'bg#225566' "fieldset:disabled matches a disabled fieldset"
assert_seg "fs enabled child"  'bg#44aa88' "fieldset:enabled matches a non-disabled fieldset"

# :nth-child(even|odd) zebra striping over four <li>.
assert_seg "z1" 'bg#eeeeee' ":nth-child(odd) matches the 1st li"
assert_seg "z2" 'bg#222222' ":nth-child(even) matches the 2nd li"
assert_seg "z3" 'bg#eeeeee' ":nth-child(odd) matches the 3rd li"
assert_seg "z4" 'bg#222222' ":nth-child(even) matches the 4th li"

# :first-child — only the first list item.
assert_seg "f1" 'bg#f0f0f0' ":first-child matches the 1st li"
assert_seg "f2" 'bg- '      ":first-child does NOT match the 2nd li"
assert_seg "f3" 'bg- '      ":first-child does NOT match the 3rd li"

# dynamic states are inert in a static render.
assert_seg "hover link"  'bg- ' ":hover is inert (no match) in a static render"
assert_seg "target para" 'bg- ' ":target is inert (no match) in a static render"

if [ "$fail" -ne 0 ]; then
    echo "[hb-pseudocss] RESULT: FAIL"; exit 1
fi
echo "[hb-pseudocss] RESULT: PASS"
