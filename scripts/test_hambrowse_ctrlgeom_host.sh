#!/usr/bin/env bash
# scripts/test_hambrowse_ctrlgeom_host.sh — FAST, QEMU-free render-to-PNG gate
# for form-control CSS GEOMETRY: cascaded `height` -> row span, and
# `appearance:none` -> suppressed default chrome. Browser W3C campaign round 10,
# remaining-map item #3 (the geometry half of the form-control work; the `width`
# -> cells half shipped in round 9's ctrlwidth gate).
#
# The pixel backend dumps one "SEGCTRL <field-kind> <appear> <rows>" line per
# form-control run (field-kind 1 = text field, 2 = push-button), giving the
# ENGINE-resolved geometry a deterministic oracle:
#   * appearance:none (stylesheet AND inline, plain + -webkit-/-moz- spellings)
#     sets appear=1 so the painter drops the default field surface + border /
#     button-grey face — author CSS styles the control;
#   * `height:48px` resolves to rows=3 (48 / 16px line), `height:32px` -> rows=2,
#     the painter draws the box that many rows tall (layout reserves the rows).
# A control with NO such declaration is byte-identical (appear=0, rows=0).
#
# PLUS a pixel invariant: the tall (height:48px) field paints a grey field
# surface spanning MORE than one text row (a >=40px-tall grey band), proving the
# height actually extends the drawn box — not just the resolved metric.
#
# Builds the pixel backend (x86_64-linux) AND the native browser
# (x86_64-adder-user) so a regression in either target fails here. NO QEMU.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_ctrlgeom.html"
PPM="$OUT/ctrlgeom.ppm"
PNG="$OUT/ctrlgeom.png"
mkdir -p "$OUT"
fail=0

echo "[hb-ctrlgeom] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/ctrlgeom_compile.log"; then
    echo "[hb-ctrlgeom] FAIL: driver did not compile"; cat "$OUT/ctrlgeom_compile.log"; exit 1
fi
echo "[hb-ctrlgeom] PASS pixel backend compiled"

echo "[hb-ctrlgeom] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/ctrlgeom_native.elf" 2>"$OUT/ctrlgeom_native.log"; then
    echo "[hb-ctrlgeom] FAIL: native hambrowse did not compile"; cat "$OUT/ctrlgeom_native.log"; exit 1
fi
echo "[hb-ctrlgeom] PASS native hambrowse still compiles"

D="$OUT/ctrlgeom_dump.txt"
if ! "$BIN" "$FIX" "$PPM" 400 >"$D" 2>&1; then
    echo "[hb-ctrlgeom] FAIL: render exited non-zero"; cat "$D"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 && echo "[hb-ctrlgeom] wrote $PNG"

# The Nth (1-based) SEGCTRL line, normalised to "<kind> <appear> <rows>".
ctrl() { grep -E "^SEGCTRL " "$D" | sed -n "${1}p" | awk '{print $2" "$3" "$4}'; }

check() { # label nth expect
    got=$(ctrl "$2")
    if [ "$got" = "$3" ]; then echo "[hb-ctrlgeom] PASS $1 (kind appear rows = $got)";
    else echo "[hb-ctrlgeom] FAIL $1 — SEGCTRL#$2 got '${got:-MISSING}' want '$3'"; fail=1; fi
}

# Fixture order: plain field, class-bare field, class-tall field, inline-bare
# field, inline-tall field, bare button, face button.
check "plain field: default chrome"            1 "1 0 0"
check "class appearance:none suppresses chrome" 2 "1 1 0"
check "class height:48px -> 3 rows"            3 "1 0 3"
check "inline appearance:none suppresses chrome" 4 "1 1 0"
check "inline height:32px -> 2 rows"           5 "1 0 2"
check "button appearance:none suppresses face"  6 "2 1 0"
check "plain button keeps default face"        7 "2 0 0"

# Pixel invariant: the tall field paints a grey (0xf1f3f4) field surface spanning
# a band taller than a single text row (>= 40px), proving the box was extended.
band=$(python3 - "$PPM" <<'PY'
import sys
f=open(sys.argv[1],'rb'); f.readline(); w,h=map(int,f.readline().split()); f.readline(); d=f.read()
grey=bytes((241,243,244))
def rowhas(y): return sum(1 for x in range(0,min(w,220)) if d[(y*w+x)*3:(y*w+x)*3+3]==grey)>=20
run=mx=0
for y in range(h):
    if rowhas(y): run+=1; mx=max(mx,run)
    else: run=0
print(mx)
PY
)
echo "[hb-ctrlgeom] tallest grey field band = ${band}px"
if [ "${band:-0}" -ge 40 ]; then
    echo "[hb-ctrlgeom] PASS tall field paints a multi-row (>=40px) box"
else
    echo "[hb-ctrlgeom] FAIL tall field band only ${band}px (expected >=40)"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-ctrlgeom] RESULT: FAIL"; exit 1; fi
echo "[hb-ctrlgeom] RESULT: PASS — control height + appearance:none geometry verified"
