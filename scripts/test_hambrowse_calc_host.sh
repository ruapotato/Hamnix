#!/usr/bin/env bash
# scripts/test_hambrowse_calc_host.sh — FAST, QEMU-free gate for CSS calc()
# expression evaluation in the native browser engine
# (lib/web/css/cascade.ad: _calc_expr / _calc_term / _calc_factor / _calc_var,
# reached from _style_len). calc() resolves each operand through the existing
# unit machinery (_len_apply_unit), applies correct operator precedence
# (* / before + -), honours parentheses, and — this gate's new coverage —
# substitutes var() INSIDE calc(). Each case is pinned to a concrete resolved
# pixel span so an arithmetic/precedence/unit/var regression fails HERE without
# a QEMU boot.
#
# Rendered at WIDTH=800 (bw), HEIGHT=600 (bh). Plain prose now spans the FULL
# viewport like Chrome, so the content column = 800-2*8 = 784px, x0=0, and
# x1 = resolved-width + 16 chrome. Percentages resolve against 784 (not the old
# 584 readable cap):
#   calc(100px + 50px)     -> 150px -> x1 166  (fixed sum)
#   calc(100% - 40px)      -> 744px -> x1 760  (percentage arithmetic; 784-40)
#   calc(10px * 3)         -> 30px  -> x1 46   (multiply by unitless)
#   calc(2rem + 10px)      -> 42px  -> x1 58   (rem=16 -> 32 + 10)
#   calc(10px + 2px * 5)   -> 20px  -> x1 36   (precedence: * before +)
#   calc((10px + 2px) * 2) -> 24px  -> x1 40   (parens override precedence)
#   calc(50vw - 100px)     -> 300px -> x1 316  (viewport unit; 50vw of 800 = 400)
#   calc(100% - var(--g))  -> 776px -> x1 792  (var(--g:8px) inside calc; 784-8)
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either backend is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_calc.html"
mkdir -p "$OUT"

echo "[hb-calc] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-calc] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-calc] PASS host harness compiled -> $BIN"

echo "[hb-calc] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-calc] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-calc] PASS native hambrowse still compiles"

fail=0
D0="$OUT/calc.txt"
# STALE-ORIGIN RE-PIN (2026-07-27): the box LEFT column below moved from 0 to 8.
# Plain prose used to render inside a centred "readable measure" strip and the
# UA 8px body margin was not honoured, so every block fill started at x=0. The
# engine now lays the page out full-width from the real body margin, which is
# what Chrome does: `chromium --headless` reports getBoundingClientRect().x == 8
# for every block in this fixture. Only the LEFT column moved — every right edge
# below is unchanged, so each assertion still pins exactly the same computed
# width it always did.
assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-calc] PASS $2"
    else
        echo "[hb-calc] FAIL $2 (missing: $1)"; fail=1
    fi
}

"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-calc] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E 'FILL' "$D0" | grep -Ei '#111111|#222222|#333333|#444444|#555555|#666666|#777777|#888888' || true

assert_grep 'FILL [0-9]+ [0-9]+ 8 166 #111111'  "calc(100px + 50px) -> 150px"
assert_grep 'FILL [0-9]+ [0-9]+ 8 760 #222222'  "calc(100% - 40px) -> 744px (percentage)"
assert_grep 'FILL [0-9]+ [0-9]+ 8 46 #333333'  "calc(10px * 3) -> 30px (multiply)"
assert_grep 'FILL [0-9]+ [0-9]+ 8 58 #444444'  "calc(2rem + 10px) -> 42px (rem operand)"
assert_grep 'FILL [0-9]+ [0-9]+ 8 36 #555555'  "calc(10px + 2px * 5) -> 20px (precedence)"
assert_grep 'FILL [0-9]+ [0-9]+ 8 40 #666666'  "calc((10px + 2px) * 2) -> 24px (nested parens)"
assert_grep 'FILL [0-9]+ [0-9]+ 8 316 #777777'  "calc(50vw - 100px) -> 300px (viewport unit)"
assert_grep 'FILL [0-9]+ [0-9]+ 8 792 #888888'  "calc(100% - var(--g)) -> 776px (var() inside calc)"

if [ "$fail" -ne 0 ]; then
    echo "[hb-calc] RESULT: FAIL"; exit 1
fi
echo "[hb-calc] RESULT: PASS"
