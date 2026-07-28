#!/usr/bin/env bash
# scripts/test_hambrowse_gridrowgap_host.sh — FAST, QEMU-free gate for the CSS
# GRID INTER-ROW GAP over-height (Chrome-parity round 10).
#
# A `display:grid` with `gap:16px` and PADDED, BORDERED cards must place its
# second row of cards ONE authored gap (~16px) below the first — the same as
# Chrome. hambrowse used to strand a PHANTOM ~LINE_H blank row between the rows:
# a bordered/padded grid item's real border-box bottom is the padding edge, but
# _flex_item_close sized the grid ROW bottom from `cur_row`, which OVERSHOOTS
# that edge by the trailing `_bump_row` _block_box_close emits past the box. The
# overshoot then COMPOUNDED with the container row-gap, so a 16px gap rendered as
# ~2 rows (~37px) and every second-row card sat far below Chrome (grid page SSIM
# vs chromium 0.745). The fix measures the row bottom from the item's own outer
# box (border bbox / background fill), mirroring the existing cross-axis fixup.
#
# The gate renders a 3x2 card grid and measures the VERTICAL GAP between the two
# card-fill row bands (fill colour #cfe0ff). Chrome renders that gap ~16px; the
# fix renders ~18px; the base stranded ~37px. Assert gap <= 24px so the base
# FAILS and the fix PASSES. Also builds native hambrowse so a break there is
# caught.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_gridrowgap.html"
mkdir -p "$OUT"

echo "[hb-gridrowgap] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/gridrowgap_gfx.log"; then
    echo "[hb-gridrowgap] FAIL: pixel backend did not compile"
    cat "$OUT/gridrowgap_gfx.log"; exit 1
fi
echo "[hb-gridrowgap] PASS pixel backend compiled"

echo "[hb-gridrowgap] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/gridrowgap_native.log"; then
    echo "[hb-gridrowgap] FAIL: native hambrowse did not compile"
    cat "$OUT/gridrowgap_native.log"; exit 1
fi
echo "[hb-gridrowgap] PASS native hambrowse still compiles"

if ! "$GFX" "$FIX" "$OUT/gridrowgap.ppm" 640 >"$OUT/gridrowgap.txt" 2>&1; then
    echo "[hb-gridrowgap] FAIL: render exited non-zero"; cat "$OUT/gridrowgap.txt"; exit 1
fi

python3 - "$OUT/gridrowgap.ppm" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
assert d[:2] == b'P6', "not a P6 ppm"
idx = 2; vals = []
while len(vals) < 3:
    while d[idx] in b' \t\n\r': idx += 1
    if d[idx:idx+1] == b'#':
        while d[idx] not in b'\n': idx += 1
        continue
    s = idx
    while d[idx] not in b' \t\n\r': idx += 1
    vals.append(int(d[s:idx]))
w, h, _mx = vals
idx += 1
pix = d[idx:]
def px(x, y):
    o = (y * w + x) * 3
    return pix[o], pix[o+1], pix[o+2]
# Card fill is #cfe0ff (207,224,255). A card-fill ROW has many such pixels.
def is_fill(c):
    return abs(c[0]-207) < 18 and abs(c[1]-224) < 18 and c[2] > 240
rows_fill = []
for y in range(h):
    cnt = sum(1 for x in range(0, w, 2) if is_fill(px(x, y)))
    rows_fill.append(cnt > 60)          # 3 cards across -> a wide fill run
# Group consecutive fill rows into bands.
bands = []
y = 0
while y < h:
    if rows_fill[y]:
        y0 = y
        while y < h and rows_fill[y]: y += 1
        bands.append((y0, y - 1))
    else:
        y += 1
print(f"[hb-gridrowgap] card-fill bands: {bands}")
if len(bands) < 2:
    print("[hb-gridrowgap] FAIL: expected 2 card rows, found "
          f"{len(bands)} fill band(s) (grid did not lay out?)")
    sys.exit(1)
gap = bands[1][0] - bands[0][1] - 1
print(f"[hb-gridrowgap] inter-row gap = {gap}px "
      f"(Chrome ~16px; fix ~18px; base stranded ~37px)")
if gap > 24:
    print(f"[hb-gridrowgap] FAIL: grid stranded a phantom row — {gap}px gap "
          "between card rows (should be ~1 authored gap, <= 24px)")
    sys.exit(1)
print("[hb-gridrowgap] PASS: second card row sits one authored gap below the first")
PY
rc=$?
if [ $rc -ne 0 ]; then echo "[hb-gridrowgap] RESULT: FAIL"; exit 1; fi
echo "[hb-gridrowgap] RESULT: PASS"
