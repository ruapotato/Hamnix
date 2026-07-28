#!/usr/bin/env bash
# scripts/test_hambrowse_viewport_host.sh — FAST, QEMU-free gate for CSS
# VIEWPORT LENGTH UNITS (vw / vh / vmin / vmax) in the native browser engine
# (lib/web/css/cascade.ad `_len_apply_unit`). These resolve against the render
# viewport dimensions (bw x bh); the implementation existed but was ungated —
# this pins each unit to concrete resolved pixels so an axis/scale regression
# fails here without a QEMU boot.
#
# Rendered at WIDTH=800 (bw), default HEIGHT=600 (bh). Plain prose now spans the
# FULL viewport like Chrome (no readable gutter), so boxes start at x0=0. The
# viewport-unit WIDTHS are unchanged (they resolve against bw/bh, not the content
# column) — only the left origin moved 100 -> 0:
#   50vw   -> 400px  (1% of width)     -> FILL x 0..416
#   25vw   -> 200px                    -> FILL x 0..216
#   50vh   -> 300px  (1% of HEIGHT)    -> FILL x 0..316   (!= 50vw: axis proof)
#   50vmin -> 300px  (min axis=height) -> FILL x 0..316
#   50vmax -> 400px  (max axis=width)  -> FILL x 0..416   (!= vmin: axis proof)
# (x1 = width + 16 chrome, matching the cssvalues gate's box model.)
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either backend is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_viewport.html"
mkdir -p "$OUT"

echo "[hb-viewport] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-viewport] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-viewport] PASS host harness compiled -> $BIN"

echo "[hb-viewport] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-viewport] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-viewport] PASS native hambrowse still compiles"

fail=0
assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-viewport] PASS $2"
    else
        echo "[hb-viewport] FAIL $2 (missing: $1)"; fail=1
    fi
}

D0="$OUT/viewport.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-viewport] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E 'FILL' "$D0" | grep -Ei '#111111|#222222|#333333|#555555|#666666' || true

# vw resolves against viewport WIDTH (800).
assert_grep 'FILL 0 1 8 416 #111111'  "50vw -> 400px (1% of width 800)"
assert_grep 'FILL 1 2 8 216 #222222'  "25vw -> 200px"
# vh resolves against viewport HEIGHT (600) -> distinct from 50vw.
assert_grep 'FILL 2 3 8 316 #333333'  "50vh -> 300px (1% of HEIGHT 600, not width)"
# vmin = smaller axis (height 600) ; vmax = larger axis (width 800) -> distinct.
assert_grep 'FILL 3 4 8 316 #555555'  "50vmin -> 300px (min axis = height)"
assert_grep 'FILL 4 5 8 416 #666666'  "50vmax -> 400px (max axis = width)"

if [ "$fail" -ne 0 ]; then
    echo "[hb-viewport] RESULT: FAIL"; exit 1
fi
echo "[hb-viewport] RESULT: PASS"
