#!/usr/bin/env bash
# scripts/test_hammath_host.sh — FAST, QEMU-free host gate for HamMath, the
# repo-only EXPRESSION calculator scene app (lib/hammathcore.ad drawn through
# lib/hamscene.ad + rasterized by lib/hamui_host.ad). Mirrors
# scripts/test_hamcalc_host.sh: compiles the core for the x86_64-linux host
# target, renders the keypad to a PNG a human/agent can LOOK at, EVALUATES a
# battery of expressions through the pure evaluator and asserts operator
# PRECEDENCE, PARENTHESES, unary minus, decimals and divide-by-zero, drives the
# keypad (keyboard + on-screen pointer press) to build + evaluate an expression,
# AND confirms the NATIVE Hamnix build still compiles from the same core — all
# in milliseconds, no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hammath_host"
mkdir -p "$OUT"
fail=0

echo "[hammath-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hammath_host.ad "$BIN" 2>"$OUT/mm_compile.log"; then
    echo "[hammath-host] FAIL: host harness did not compile"; cat "$OUT/mm_compile.log"; exit 1
fi
echo "[hammath-host] PASS host harness compiled -> $BIN"

echo "[hammath-host] compiling NATIVE hammath for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hammath.ad "$OUT/hammath_native.elf" 2>"$OUT/mm_native.log"; then
    echo "[hammath-host] FAIL: native hammath did not compile"; cat "$OUT/mm_native.log"; exit 1
fi
echo "[hammath-host] PASS native hammath still compiles"

echo "[hammath-host] running host harness ..."
DUMP="$OUT/mm_dump.txt"
BEFORE="$OUT/mm_before.ppm"
AFTER="$OUT/mm_after.ppm"
if ! "$BIN" "$BEFORE" "$AFTER" >"$DUMP" 2>&1; then
    echo "[hammath-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/mm_$f.ppm" "$OUT/mm_$f.png" 2>"$OUT/mm_png.log"; then
        echo "[hammath-host] PASS rendered $OUT/mm_$f.png ($(file -b "$OUT/mm_$f.png" 2>/dev/null))"
    else
        echo "[hammath-host] FAIL png conversion ($f)"; cat "$OUT/mm_png.log"; fail=1
    fi
done

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hammath-host] PASS $msg"
    else
        echo "[hammath-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- Scene / layout assertions (on the raw scene display list) -----------
# The keypad is a 5x4 expression-calculator grid:
#   C  (  )  /
#   7  8  9  *
#   4  5  6  -
#   1  2  3  +
#   0  .  <  =
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 200 300 #2b2f36'         "calculator case background"
assert_grep '^fill 8 8 184 50 #0d1410'          "sunken LCD display bar"
assert_grep '^glyphs 25 79 "C" #7a0000'         "clear 'C' key label in red"
assert_grep '^glyphs 72 79 "[(]" #00457a'       "open-paren '(' key label in blue"
assert_grep '^glyphs 119 79 "[)]" #00457a'      "close-paren ')' key label in blue"
assert_grep '^glyphs 166 79 "/" #7a2a00'        "operator '/' key label in orange"
assert_grep '^glyphs 25 125 "7" #202020'        "digit '7' key label in dark"
assert_grep '^glyphs 166 263 "=" #7a2a00'       "equals '=' key label in orange"
assert_grep '^glyphs 119 263 "<" #7a0000'       "backspace '<' key label in red"

# --- Rasterizer assertions (sampled framebuffer pixels) ------------------
assert_grep '^PRIMS ([1-9][0-9][0-9]?)'         "rasterizer drew the scene primitives"
assert_grep '^PIX 2 2 #2b2f36'                  "raster case pixel = dark slate"
assert_grep '^PIX 20 20 #0d1410'                "raster LCD pixel = dark green-black"
assert_grep '^DISPLAY0 0'                        "initial display is 0"

# --- CORE EVALUATOR: precedence, parentheses, unary minus, decimals ------
assert_grep '^EVAL add 5$'                       "'2+3' -> 5"
assert_grep '^EVAL sub 5$'                       "'7-2' -> 5"
assert_grep '^EVAL mul 42$'                      "'6*7' -> 42"
assert_grep '^EVAL prec 14$'                     "PRECEDENCE: '2+3*4' -> 14 (not 20)"
assert_grep '^EVAL prec2 10$'                    "PRECEDENCE: '2*3+4' -> 10 (not 14)"
assert_grep '^EVAL paren 20$'                    "PARENTHESES: '(2+3)*4' -> 20"
assert_grep '^EVAL nestparen 21$'                "NESTED PARENS: '((1+2)*(3+4))' -> 21"
assert_grep '^EVAL unary -5$'                    "UNARY MINUS: '-(3+2)' -> -5"
assert_grep '^EVAL unary2 7$'                    "unary in operand: '10+-3' -> 7"
assert_grep '^EVAL div 2[.]5$'                   "DECIMAL: '10/4' -> 2.5"
assert_grep '^EVAL decmul 3$'                    "decimal operand: '1.5*2' -> 3"
assert_grep '^EVAL chain 10$'                    "chained add: '1+2+3+4' -> 10"
assert_grep '^EVAL ltr 5$'                       "left-to-right: '10-3-2' -> 5"

# --- Error handling (error flag latches; LCD shows ERR) ------------------
assert_grep '^EVAL divzero ERR$'                 "DIVIDE-BY-ZERO: '5/0' sets the error flag"
assert_grep '^EVAL malformed ERR$'               "malformed '2+*3' sets the error flag"
assert_grep '^EVAL unbalanced ERR$'              "unbalanced '(2+3' sets the error flag"

# --- Keypad-driven path (keyboard + pointer through the real wire) -------
assert_grep '^EXPR typed 2[+]3[*]4$'             "typing shows the running expression '2+3*4'"
assert_grep '^KEYRESULT 14$'                     "keyboard '2+3*4=' evaluates to 14"
assert_grep '^CLICKRESULT 20$'                   "pointer-click '(' then '2+3)*4=' -> 20"

# --- The two PNGs really exist + are non-blank ---------------------------
for f in before after; do
    if [ -s "$OUT/mm_$f.png" ]; then
        echo "[hammath-host] PASS $OUT/mm_$f.png on disk"
    else
        echo "[hammath-host] FAIL $OUT/mm_$f.png not written"; fail=1
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "[hammath-host] RESULT: PASS"
    exit 0
else
    echo "[hammath-host] RESULT: FAIL"
    exit 1
fi
