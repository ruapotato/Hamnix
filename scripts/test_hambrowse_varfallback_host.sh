#!/usr/bin/env bash
# scripts/test_hambrowse_varfallback_host.sh — FAST, QEMU-free coverage-lock
# gate for CSS custom-property var() FALLBACK completeness in the native
# browser cascade (lib/web/css/cascade.ad _apply_decl). Proves every fallback
# shape resolves:
#
#   var(--miss, #cc0000)                 plain colour fallback
#   var(--miss, var(--also, #00cc00))    nested var() fallback
#   var(--miss, rgb(10,20,30))           functional-colour fallback (commas)
#   var(--known, #ffffff)                fallback ignored when the prop is set
#   var(--miss, hsl(120,100%,50%))       hsl() fallback
#   var(--miss, var(--known))            a var() inside the fallback
#   var(--miss)  (no fallback)           the declaration is dropped
#
# Builds BOTH targets so a regression is caught in either backend, no QEMU.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_varfallback.html"
mkdir -p "$OUT"

echo "[hb-varfb] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/varfb_compile.log"; then
    echo "[hb-varfb] FAIL: host harness did not compile"; cat "$OUT/varfb_compile.log"; exit 1
fi
echo "[hb-varfb] PASS host harness compiled -> $BIN"

echo "[hb-varfb] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/varfb_native.log"; then
    echo "[hb-varfb] FAIL: native hambrowse did not compile"; cat "$OUT/varfb_native.log"; exit 1
fi
echo "[hb-varfb] PASS native hambrowse still compiles"

fail=0
D0="$OUT/varfb_run.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-varfb] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E '^SEG' "$D0" || true

seg_line() { grep -E "^SEG [0-9]+ [0-9]+ .*\|$1\|" "$D0" | head -1; }
assert_seg() {    # text  regex  message
    local ln; ln="$(seg_line "$1")"
    if [ -z "$ln" ]; then
        echo "[hb-varfb] FAIL $3 (no segment for |$1|)"; fail=1; return
    fi
    if echo "$ln" | grep -Eq -- "$2"; then
        echo "[hb-varfb] PASS $3"
    else
        echo "[hb-varfb] FAIL $3 (seg: $ln)"; fail=1
    fi
}

assert_seg "a" 'bg#cc0000' "plain colour fallback"
assert_seg "b" 'bg#00cc00' "nested var() fallback"
assert_seg "c" 'bg#0a141e' "rgb() functional-colour fallback (rgb 10,20,30)"
assert_seg "d" 'bg#0a0b0c' "fallback ignored when the custom property is set"
assert_seg "e" 'bg#00ff00' "hsl() fallback -> green"
assert_seg "f" 'bg#0a0b0c' "var() inside the fallback resolves"
assert_seg "g" 'bg#334455' "undefined var() with no fallback drops that declaration"

if [ "$fail" -ne 0 ]; then
    echo "[hb-varfb] RESULT: FAIL"; exit 1
fi
echo "[hb-varfb] RESULT: PASS"
