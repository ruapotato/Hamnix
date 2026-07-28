#!/usr/bin/env bash
# scripts/test_hambrowse_gridjustify_host.sh — FAST, QEMU-free gate for CSS GRID
# `justify-content` (inline-axis alignment of the grid TRACKS) in the native
# browser engine (lib/web/layout/box.ad _grid_resolve_tracks).
#
# Four grids share IDENTICAL fixed tracks (3 x 64px + 8px gaps => 208px) that
# UNDERFLOW the body content width, so justify-content decides where the leftover
# inline-axis space lands:
#   flex-start   -> tracks packed left  (first item at the container origin)
#   center       -> whole track group centred (first item shifted right)
#   flex-end     -> tracks packed right  (first item shifted further right)
#   space-between-> first item stays left, last item pushed to the right edge
#
# Asserts on ACTUAL engine layout coordinates (item column x-positions) — not
# echo. Builds BOTH targets so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_gridjustify.html"
mkdir -p "$OUT"

echo "[hb-gj] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/gj_compile.log"; then
    echo "[hb-gj] FAIL: host harness did not compile"; cat "$OUT/gj_compile.log"; exit 1
fi
echo "[hb-gj] PASS host harness compiled -> $BIN"

echo "[hb-gj] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/gj_native.log"; then
    echo "[hb-gj] FAIL: native hambrowse did not compile"; cat "$OUT/gj_native.log"; exit 1
fi
echo "[hb-gj] PASS native hambrowse still compiles"

fail=0
D="$OUT/gridjustify.txt"
"$BIN" "$FIX" 640 >"$D" 2>&1 || { echo "[hb-gj] FAIL: render exited non-zero"; cat "$D"; exit 1; }

seg_x() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $3}' | head -1; }

Sa=$(seg_x Sa); Sc=$(seg_x Sc)
Ca=$(seg_x Ca); Cc=$(seg_x Cc)
Ea=$(seg_x Ea)
Ba=$(seg_x Ba); Bc=$(seg_x Bc)
echo "[hb-gj] first-item x: start=$Sa center=$Ca end=$Ea between=$Ba"
echo "[hb-gj] last-item  x: start=$Sc center=$Cc between=$Bc"

need() { [ -n "$1" ] || { echo "[hb-gj] FAIL: missing item ($2)"; fail=1; return 1; }; return 0; }
for v in "$Sa:Sa" "$Sc:Sc" "$Ca:Ca" "$Cc:Cc" "$Ea:Ea" "$Ba:Ba" "$Bc:Bc"; do
    need "${v%%:*}" "${v##*:}" || true
done

# (1) flex-start leaves the first track at the container origin (leftmost).
if [ "$fail" -eq 0 ] && [ "$Ca" -gt "$Sa" ]; then
    echo "[hb-gj] PASS center shifts the track group right of flex-start ($Sa -> $Ca)"
else
    echo "[hb-gj] FAIL center did not shift right of start (start=$Sa center=$Ca)"; fail=1
fi

# (2) flex-end packs further right than center.
if [ "$fail" -eq 0 ] && [ "$Ea" -gt "$Ca" ]; then
    echo "[hb-gj] PASS flex-end packs further right than center ($Ca -> $Ea)"
else
    echo "[hb-gj] FAIL flex-end not right of center (center=$Ca end=$Ea)"; fail=1
fi

# (3) center is (roughly) symmetric: the right gap after the last track equals the
#     left lead. The first item's lead == (Ea - Sa)/2 within a small tolerance.
if [ "$fail" -eq 0 ]; then
    half=$(( (Ea - Sa) / 2 ))
    lead=$(( Ca - Sa ))
    d=$(( lead - half )); [ "$d" -lt 0 ] && d=$(( -d ))
    if [ "$d" -le 4 ]; then
        echo "[hb-gj] PASS center lead ~= half of the flex-end travel (lead=$lead half=$half)"
    else
        echo "[hb-gj] FAIL center not midway (lead=$lead half=$half)"; fail=1
    fi
fi

# (4) space-between keeps the FIRST item at the flex-start origin ...
if [ "$fail" -eq 0 ] && [ "$Ba" -eq "$Sa" ]; then
    echo "[hb-gj] PASS space-between anchors the first item at the origin ($Ba == $Sa)"
else
    echo "[hb-gj] FAIL space-between first item moved (start=$Sa between=$Ba)"; fail=1
fi

# (5) ... and pushes the LAST item to the right edge (far past its start position,
#     and reaching where flex-end would place the last track).
if [ "$fail" -eq 0 ] && [ "$Bc" -gt "$Sc" ] && [ "$Bc" -gt "$Cc" ]; then
    echo "[hb-gj] PASS space-between pushes the last item to the right edge (start=$Sc between=$Bc)"
else
    echo "[hb-gj] FAIL space-between did not spread the last item (start=$Sc center=$Cc between=$Bc)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-gj] RESULT: FAIL"; exit 1
fi
echo "[hb-gj] RESULT: PASS"
