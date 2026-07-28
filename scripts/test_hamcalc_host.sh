#!/usr/bin/env bash
# scripts/test_hamcalc_host.sh — FAST, QEMU-free host gate for the calculator
# scene app (lib/hamcalccore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). Mirrors scripts/test_ham2048_host.sh: compiles the core
# for the x86_64-linux host target, renders the scene to a PNG a human/agent
# can LOOK at, drives SCRIPTED keyboard + pointer input, asserts the
# arithmetic result, AND confirms the NATIVE Hamnix build still compiles from
# the same core — all in milliseconds, no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamcalc_host"
mkdir -p "$OUT"
fail=0

echo "[calc-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamcalcscene_host.ad "$BIN" 2>"$OUT/calc_compile.log"; then
    echo "[calc-host] FAIL: host harness did not compile"; cat "$OUT/calc_compile.log"; exit 1
fi
echo "[calc-host] PASS host harness compiled -> $BIN"

echo "[calc-host] compiling NATIVE hamcalcscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamcalcscene.ad "$OUT/hamcalc_native.elf" 2>"$OUT/calc_native.log"; then
    echo "[calc-host] FAIL: native hamcalcscene did not compile"; cat "$OUT/calc_native.log"; exit 1
fi
echo "[calc-host] PASS native hamcalcscene still compiles"

echo "[calc-host] running host harness (expression 7*6=) ..."
DUMP="$OUT/calc_dump.txt"
BEFORE="$OUT/calc_before.ppm"
AFTER="$OUT/calc_after.ppm"
if ! "$BIN" "$BEFORE" "$AFTER" "7*6=" >"$DUMP" 2>&1; then
    echo "[calc-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/calc_$f.ppm" "$OUT/calc_$f.png" 2>"$OUT/calc_png.log"; then
        echo "[calc-host] PASS rendered $OUT/calc_$f.png ($(file -b "$OUT/calc_$f.png" 2>/dev/null))"
    else
        echo "[calc-host] FAIL png conversion ($f)"; cat "$OUT/calc_png.log"; fail=1
    fi
done

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[calc-host] PASS $msg"
    else
        echo "[calc-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# --- Layout / build assertions (on the raw scene display list) -----------
# The keypad is a 6x4 everyday-calculator grid:
#   CE  C   <-  /
#   sqrt %  1/x *
#   7   8   9   -
#   4   5   6   +
#   1   2   3   x2
#   0   .   +/- =
assert_grep '^# scene v1 hamui'                 "scene header emitted"
assert_grep '^fill 0 0 188 300 #2b2f36'         "calculator case background"
assert_grep '^fill 8 8 172 42 #0d1410'          "sunken LCD display bar"
assert_grep '^glyphs 164 22 \"0\" #9ff09f'      "display shows 0 in LCD green, right-aligned"
assert_grep '^roundrect 8 60 40 35 5 #c2c5cd 15' "top-left key rounded frame base"
assert_grep '^roundrect 9 61 38 33 4 #e6e8ec 15' "top-left key rounded face inset"
assert_grep '^glyphs 24 147 \"7\" #202020'      "digit '7' key label in dark"
assert_grep '^glyphs 156 69 \"/\" #7a2a00'      "operator '/' key label in orange"
assert_grep '^glyphs 68 69 \"C\" #7a0000'       "clear 'C' key label in red"
assert_grep '^glyphs 156 264 \"=\" #7a2a00'     "equals '=' key label"
# --- new everyday-calculator keys are laid out + labeled -----------------
assert_grep '^glyphs 20 69 \"CE\" #7a0000'      "clear-entry 'CE' key label in red"
assert_grep '^glyphs 108 69 \"<-\" #00457a'     "backspace '<-' key label in blue"
assert_grep '^glyphs 12 108 \"sqrt\" #00457a'   "square-root 'sqrt' key label in blue"
assert_grep '^glyphs 68 108 \"%\" #00457a'      "percent '%' key label in blue"
assert_grep '^glyphs 104 108 \"1/x\" #00457a'   "reciprocal '1/x' key label in blue"
assert_grep '^glyphs 152 225 \"x2\" #00457a'    "square 'x2' key label in blue"
assert_grep '^glyphs 68 264 \"[.]\" #202020'    "decimal-point '.' key label in dark"
assert_grep '^glyphs 104 264 \"[+]/-\" #00457a' "sign-toggle '+/-' key label in blue"

# --- Rasterizer assertions (sampled framebuffer pixels) ------------------
assert_grep '^PRIMS ([1-9][0-9][0-9]?)'         "rasterizer drew the scene primitives"
assert_grep '^PIX 2 2 #2b2f36'                  "raster case pixel = dark slate"
assert_grep '^PIX 20 20 #0d1410'                "raster LCD pixel = dark green-black"
assert_grep '^PIX 12 64 #e6e8ec'                "raster key-face pixel = flat button neutral"
# --- modern ROUNDED flat button chrome on the shared panel button (@8,60 40x35, r5) ---
assert_grep '^PIX 8 60 #2b2f36'                 "rounded: hard corner cut away -> case bg shows"
assert_grep '^PIX 8 77 #c2c5cd'                 "rounded: straight left edge is the hairline frame"
assert_grep '^PIX 20 61 #f6f7f9'                "rounded: faint top-edge sheen"
assert_grep '^PIX 20 93 #d6d9df'                "rounded: faint bottom-edge shadow"
assert_grep '^PIX 10 60 #767981'                "rounded: AA corner band blends frame ink with bg"

# --- Initial state -------------------------------------------------------
assert_grep '^DISPLAY0 0'                        "initial display is 0"

# --- #329 running EXPRESSION on the LCD (show the whole formula as you type) --
assert_grep '^EXPR d1 5$'                         "typing '5' shows '5'"
assert_grep '^EXPR op 5[+]$'                       "then '+' shows the running expr '5+'"
assert_grep '^EXPR d2 5[+]5$'                      "then '5' shows '5+5' (not just '5')"
assert_grep '^EXPR eq 10$'                         "'=' collapses to the result '10'"
assert_grep '^EXPR chain 12[+]3[*]2$'              "longer running expr '12+3*2' mid-entry"

# --- Core four-function + chaining (fixed-point) -------------------------
assert_grep '^DISPLAY1 42'                       "keyboard '7*6=' computes 42"
assert_grep '^RESULT chain 9'                    "chained ops '2+3+4=' -> 9"
assert_grep '^RESULT op_after_eq 84'             "operator-after-equals '7*6=*2=' -> 84"
assert_grep '^RESULT div 3[.]5'                  "division '7/2=' -> 3.5 (fixed point)"

# --- Decimal-point entry -------------------------------------------------
assert_grep '^RESULT dec_add 4'                  "decimal add '1.5+2.5=' -> 4"
assert_grep '^RESULT dec_entry 3[.]14'           "decimal entry shows exactly '3.14'"
assert_grep '^RESULT dec_lead 0[.]5'             "bare fraction '.5' shows leading '0.5'"
assert_grep '^RESULT dec_one_dot 1[.]23'         "only one '.' honored ('1..2.3' -> 1.23)"

# --- New unary + editing operations --------------------------------------
assert_grep '^KEYAT 28 116 4'                    "pointer hit-tests the on-screen 'sqrt' key (index 4)"
assert_grep '^RESULT sqrt 3'                     "square root '9 [sqrt] =' -> 3"
assert_grep '^RESULT recip 0[.]25'               "reciprocal '4 [1/x]' -> 0.25"
assert_grep '^RESULT square 9'                   "square '3 [x2]' -> 9"
assert_grep '^RESULT sign -5'                    "sign toggle '5 [+/-]' -> -5"
assert_grep '^RESULT bksp 1'                     "backspace '12 [<-]' -> 1"
assert_grep '^RESULT ce_disp 0'                  "clear-entry blanks the entry to 0"
assert_grep '^RESULT ce_then 12'                 "clear-entry keeps acc+op ('5+3 CE 7=' -> 12)"

# --- Percent (Windows semantics) -----------------------------------------
assert_grep '^RESULT pct_add_pre 20'             "'200 + 10 %' turns the entry into 20 (10% of 200)"
assert_grep '^RESULT pct_add 220'                "'200 + 10 % =' -> 220"
assert_grep '^RESULT pct_std 0[.]5'              "standalone '50 %' -> 0.5"

# --- Error handling ------------------------------------------------------
assert_grep '^RESULT divzero ERR'                "divide-by-zero shows ERR"
assert_grep '^ERR 1'                             "divide-by-zero latches the error flag"
assert_grep '^RESULT after_div 3[.]333333'       "fixed-point '10/3=' -> 3.333333"

# --- Autostart identity: the desktop must start the GOOD scene calculator,
#     never the legacy hamui integer calc (/bin/hamcalc) whose fixed-place
#     "integer calc"/labels overlap the keypad and whose keys are dead. A
#     user reported the broken calc auto-starting on the installed image; this
#     asserts every DE launch path points at /bin/hamcalcscene.
echo "[calc-host] checking desktop autostart points at the good calc ..."
if grep -vE '^[[:space:]]*#' etc/rc.d/rc.5 | grep -Eq "/bin/hamcalc([^s]|$)|/bin/hamcalc'"; then
    echo "[calc-host] FAIL: rc.5 still autostarts the legacy /bin/hamcalc"; fail=1
else
    echo "[calc-host] PASS rc.5 autostart calc is /bin/hamcalcscene (legacy /bin/hamcalc absent)"
fi
if grep -Eq '"/bin/hamcalc"' user/hampanel.ad; then
    echo "[calc-host] FAIL: hampanel.ad launcher still returns legacy /bin/hamcalc"; fail=1
else
    echo "[calc-host] PASS hampanel.ad launcher no longer returns legacy /bin/hamcalc"
fi
if grep -q '/bin/hamcalcscene' etc/hamde/apps/calculator.desktop \
   && grep -q '/bin/hamcalcscene' etc/desktop.icons; then
    echo "[calc-host] PASS menu (.desktop) + desktop icon launch /bin/hamcalcscene"
else
    echo "[calc-host] FAIL: menu/icon do not both launch /bin/hamcalcscene"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[calc-host] RESULT: PASS"
    exit 0
else
    echo "[calc-host] RESULT: FAIL"
    exit 1
fi
