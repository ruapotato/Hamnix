#!/usr/bin/env bash
# scripts/test_hambrowse_cssvalues_host.sh — FAST, QEMU-free gate for the CSS
# VALUES/COLOR completeness round in the native browser engine
# (lib/htmlengine.ad). Real modern pages lean on all of these, so a regression
# in any one must fail here without a QEMU boot:
#
#   (A) HSL / HSLA colours  — hsl(h,s%,l%) resolves to the right RGB (and the
#       alpha of hsla() is dropped, opaque render).
#   (B) CSS custom properties — `--x: value` on :root resolves through
#       `var(--x)` for BOTH colours and lengths, plus the `var(--x, fallback)`
#       fallback when the token is undefined.
#   (C) calc() — `calc(100px + 50px)` and `calc(100% - 200px)` evaluate to the
#       correct pixel widths (with + - operator precedence over the length grid).
#   (D) rem / #rrggbbaa (8-digit hex) / extended named colours (rebeccapurple,
#       steelblue) all parse to the right value.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either backend is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_cssvalues.html"
mkdir -p "$OUT"

echo "[hb-cssvalues] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-cssvalues] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-cssvalues] PASS host harness compiled -> $BIN"

echo "[hb-cssvalues] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-cssvalues] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-cssvalues] PASS native hambrowse still compiles"

fail=0
assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-cssvalues] PASS $2"
    else
        echo "[hb-cssvalues] FAIL $2 (missing: $1)"; fail=1
    fi
}

D0="$OUT/cssvalues.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-cssvalues] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E 'FILL|SEG ' "$D0" | grep -Ei 'hsl|brand|token|rebecca|fallback|calc|rem|hex8|steelblue|plain' || true

# (A) HSL / HSLA colours.
assert_grep 'FILL .* #00ff00'         "hsl(120,100%,50%) -> pure green fill"
assert_grep 'SEG .* #0000ff .*hsla'   "hsla(240,100%,50%,.4) text -> blue (alpha dropped)"

# (B) Custom properties: colour token, length token, colour token on text, and
# the undefined-token fallback.
assert_grep 'FILL .* #2255aa'                    "var(--brand) colour token resolves"
assert_grep 'FILL 4 5 8 168 #123456'             "var(--pad-w:160px) length token -> a 160px box (chromium x1=168)"
assert_grep 'SEG .* #663399 .*rebecca'           "var(--ink:rebeccapurple) colour token on text"
assert_grep 'FILL .* #cc0000'                    "var(--missing, #cc0000) uses the fallback"

# (C) calc(): a fixed sum (150px, centred) and a percentage difference. Plain
# prose now spans the FULL viewport like Chrome (content column = 800-2*8 =
# 784px), so 100% - 200 = 584 -> 600px painted box. The margin:auto box centres
# on the same window centre (400) as before, so its coords are unchanged.
assert_grep 'FILL 8 9 325 475 #eeeeee'  "calc(100px + 50px)=150px, margin:auto centred (chromium 325..475)"
assert_grep 'FILL 9 10 8 592 #ff9900'  "calc(100% - 200px) percentage arithmetic (chromium x1=592)"

# The centred calc box's text must shift RIGHT of a full-width plain row.
cx=$(grep -E 'SEG [0-9]+ [0-9]+ .*\|calc sum box'        "$D0" | awk '{print $3}' | head -1)
px=$(grep -E 'SEG [0-9]+ [0-9]+ .*\|plain full-width row' "$D0" | awk '{print $3}' | head -1)
echo "[hb-cssvalues] calc-centred x=$cx  plain x=$px"
if [ -n "$cx" ] && [ -n "$px" ] && [ "$cx" -gt "$((px + 40))" ]; then
    echo "[hb-cssvalues] PASS calc()-width box is centred (x $px -> $cx)"
else
    echo "[hb-cssvalues] FAIL calc()-width box not centred (plain=$px calc=$cx)"; fail=1
fi

# (D) rem, 8-digit hex, extended named colours.
assert_grep 'FILL 10 11 8 168 #445566'  "width:10rem -> 160px (chromium x1=168)"
assert_grep 'FILL .* #112233'             "#11223344 8-digit hex -> #112233 (alpha dropped)"
assert_grep 'FILL .* #4682b4'             "named colour steelblue -> #4682b4"

# (E) CSS math functions min()/max()/clamp() resolve to px widths (and nest
# inside calc()). Plain prose is now full-viewport (content column = 784px), so
# percentages resolve against 784 (edge-to-edge like Chrome). Boxes start at
# x0=0 (left content edge = CONTENT_X 8, less the 8px fill inset):
#   min(100%, 300px)           -> 300px  (box 8..308)
#   max(200px, 40%=~313)       -> 313px  (40% of 784 = 313.6; 8..321)
#   clamp(150px, 10%=~78, 400) -> 150px  (clamped up to the floor; 8..158)
#   calc(min(100px,50px)+20px) -> 70px   (nested min in calc; 8..78)
#
# UPDATED 2026-07-29 (box-model round): every SIZED box's right edge above was
# 8px too far right and this gate pinned that error -- an explicitly-sized block
# was painted at `used width + CELL_W`, a monospace right bleed that is only
# correct for a width:auto full-bleed band. All eight sized boxes now agree with
# getBoundingClientRect() from `chromium --headless --window-size=800,600` on
# this same fixture, to the pixel:
#     toklen   8..168     (chromium x1=168)        was 176
#     calcbox  325..475   (chromium 325..475)      was 325..483
#     calcpct  8..592     (chromium x1=592)        was 600
#     rembox   8..168     (chromium x1=168)        was 176
#     minbox   8..308     (chromium x1=308)        was 316
#     maxbox   8..321     (chromium x1=321.59375)  was 329
#     clampbox 8..158     (chromium x1=158)        was 166
#     calcmin  8..78      (chromium x1=78)         was 86
# The var()/calc()/min()/max()/clamp() ARITHMETIC this gate exists to pin --
# 160/150/584/160/300/313/150/70 px -- is unchanged; only the box-model error it
# was carrying is gone. The full-width (width:auto) rows are untouched.
assert_grep 'FILL 15 16 8 308 #778899'  "min(100%, 300px) -> 300px width (chromium x1=308)"
assert_grep 'FILL 16 17 8 321 #99aabb'  "max(200px, 40%) -> 313px width (chromium x1=321.59)"
assert_grep 'FILL 17 18 8 158 #bbccdd'  "clamp(150px, 10%, 400px) -> 150px floor (chromium x1=158)"
assert_grep 'FILL 18 20 8 78 #ddeeff'  "calc(min(100px,50px)+20px) -> 70px nested (chromium x1=78)"

if [ "$fail" -ne 0 ]; then
    echo "[hb-cssvalues] RESULT: FAIL"; exit 1
fi
echo "[hb-cssvalues] RESULT: PASS"
