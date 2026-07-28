#!/usr/bin/env bash
# scripts/test_hambrowse_ctrlwidth_host.sh — FAST, QEMU-free gate for FORM-CONTROL
# CSS geometry (`width`) in the native browser engine (lib/web/dom/forms.ad
# _control_width_cells). A text/password <input> sizes its field box to the
# cascaded CSS `width` (class OR inline style="") instead of the fixed >=8-cell UA
# default: the underscore padding run is grown so the bracketed [value___] field
# spans `width` px at CELL_W=8 (target inner cells = width/8 - 2 bracket cells).
#
# The fixture (tests/fixtures/hambrowse_ctrlwidth.html) has four inputs:
#   1. value="ab", no CSS width           -> [ab_________________]  (20 inner: UA
#                                             size=20 default, Chrome/Firefox parity)
#   2. value="ab", class .wide{width:240} -> 240/8-2 = 28 inner cells (cascade)
#   3. value="cd", style="width:120px"    -> 120/8-2 = 13 inner cells (inline)
#   4. type=password value="pw" width:160 -> 160/8-2 = 18 inner cells (masked '*')
# The gate counts the field-run character span from the engine's SEG text, so it
# asserts on ACTUAL laid-out field width, NOT on echo.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_ctrlwidth.html"
mkdir -p "$OUT"

echo "[hb-ctrlwidth] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-ctrlwidth] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-ctrlwidth] PASS host harness compiled -> $BIN"

echo "[hb-ctrlwidth] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-ctrlwidth] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-ctrlwidth] PASS native hambrowse still compiles"

fail=0
D="$OUT/ctrlwidth.txt"
"$BIN" "$FIX" 900 >"$D" 2>&1 || { echo "[hb-ctrlwidth] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# Inner cell count of a field seg = chars between the '[' and ']' of its label.
# Nth (1-based) field seg on the page.
inner() { # nth
    local seg
    seg=$(grep -E "SEG .*\|[^|]*\[[^]]*\]" "$D" | sed -n "${1}p")
    # extract the [....] payload, strip brackets, count chars
    printf '%s' "$seg" | grep -oE '\[[^]]*\]' | head -1 | sed 's/^\[//;s/\]$//' | tr -d '\n' | wc -c
}

n1=$(inner 1); n2=$(inner 2); n3=$(inner 3); n4=$(inner 4)
echo "[hb-ctrlwidth] inner cells: default=$n1 wide=$n2 inline=$n3 pw=$n4"

check() { # desc actual expected
    if [ "$2" -ne "$3" ]; then echo "[hb-ctrlwidth] FAIL: $1 — got $2 want $3"; fail=1;
    else echo "[hb-ctrlwidth] PASS: $1 ($2)"; fi
}
check "default UA field = 20 cells (size=20)"  "$n1" 20
check "class width:240px -> 28 cells"         "$n2" 28
check "inline width:120px -> 13 cells"        "$n3" 13
check "password width:160px -> 18 cells"      "$n4" 18

# password must be masked (no plaintext 'pw' leaked)
if grep -qE "\[pw" "$D"; then echo "[hb-ctrlwidth] FAIL: password value not masked"; fail=1;
else echo "[hb-ctrlwidth] PASS: password value masked"; fi

if [ "$fail" -ne 0 ]; then echo "[hb-ctrlwidth] RESULT: FAIL"; exit 1; fi
echo "[hb-ctrlwidth] RESULT: PASS — form-control CSS width geometry verified"
