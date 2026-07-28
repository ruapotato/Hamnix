#!/usr/bin/env bash
# scripts/test_hambrowse_cellflow_host.sh — FAST, QEMU-free PIXEL gate for the
# TABLE-CELL inline-flow overprint bug (live Hacker News top-nav + wrapped
# sitebit).
#
# The engine wraps a table cell's text on its 8px monospace CHARACTER GRID, but
# the pixel backend flows REAL proportional (and bold, ~1.5x wider) advances.
# Every segment inside a cell was flagged seg_gridx AND caught by the pixel
# renderer's out-of-flow isolation, so each same-row cell run repainted at its
# own monospace grid column — LEFT of where the previous run's real glyphs
# ended. Wide/bold cell text therefore OVERPRINTED the next run: HN's orange
# top-nav read "Hacker Ne<new>… commer|s ask" and a wrapped title's trailing
# "(site.com)" sitebit clipped past the cell edge.
#
# The fix tags table-cell / <pre> TEXT runs seg_cellx=1 (distinct from a
# position:absolute badge, which keeps seg_cellx=0 and its exact absolute x),
# excludes them from the out-of-flow pen isolation, and adds a pen guard so the
# cell's inline pen never moves BACKWARDS under the previous same-row run's real
# proportional glyphs. Aligned/non-overflowing cells (seg_x >= pen) are honoured
# verbatim, so ordinary tables stay byte-identical.
#
# The fixture places a bold, proportional-wide word (WWWWWWWWWWWW, real width far
# exceeds its 12*8px grid span) immediately followed by a uniquely-coloured
# marker word in the SAME cell. When the cell flows correctly the ruby marker
# sits just PAST the bold word's real right edge; the bug painted it deep in the
# MIDDLE of the bold word (its monospace grid column). This gate renders the real
# pixels and asserts the marker's left edge is at/after the bold word's right
# edge, not overprinting it.
#
# Also builds native hambrowse so a break there is caught.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_cellflow.html"
PPM="$OUT/cellflow.ppm"
PNG="$OUT/cellflow.png"
mkdir -p "$OUT"
fail=0

echo "[hb-cellflow] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/cellflow_gfx.log"; then
    echo "[hb-cellflow] FAIL: pixel backend did not compile"; cat "$OUT/cellflow_gfx.log"; exit 1
fi
echo "[hb-cellflow] PASS pixel backend compiled"

echo "[hb-cellflow] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/cellflow_native.log"; then
    echo "[hb-cellflow] FAIL: native hambrowse did not compile"; cat "$OUT/cellflow_native.log"; exit 1
fi
echo "[hb-cellflow] PASS native hambrowse still compiles"

D="$OUT/cellflow_dump.txt"
if ! "$GFX" "$FIX" "$PPM" 400 >"$D" 2>&1; then
    echo "[hb-cellflow] FAIL: pixel render exited non-zero"; cat "$D"; exit 1
fi
# Both runs must have been laid out.
if grep -q 'SEGTXT WWWWWWWWWWWW' "$D" && grep -q 'SEGTXT MARKER' "$D"; then
    echo "[hb-cellflow] PASS both cell runs laid out (bold word, marker)"
else
    echo "[hb-cellflow] FAIL: cell run segments missing"; grep SEGTXT "$D"; fail=1
fi

if ! python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/cellflow_png.log"; then
    echo "[hb-cellflow] FAIL png conversion"; cat "$OUT/cellflow_png.log"; exit 1
fi

# --- PIXEL assertion: the ruby marker flows PAST the bold word, not over it ----
python3 - "$PPM" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
assert data[:2] == b'P6', "not a P6 ppm"
idx = 2; vals = []
while len(vals) < 3:
    while idx < len(data) and data[idx] in b' \t\n\r':
        idx += 1
    if data[idx:idx+1] == b'#':
        while idx < len(data) and data[idx] not in b'\n':
            idx += 1
        continue
    s = idx
    while idx < len(data) and data[idx] not in b' \t\n\r':
        idx += 1
    vals.append(int(data[s:idx]))
w, h, mx = vals
idx += 1
px = data[idx:]
def rgb(x, y):
    o = (y*w + x)*3
    return px[o], px[o+1], px[o+2]
black_r = -1     # rightmost black (bold W) pixel
ruby_l = -1      # leftmost ruby (#e0115f marker) pixel
for x in range(w):
    for y in range(0, min(h, 40)):
        r, g, b = rgb(x, y)
        if r < 80 and g < 80 and b < 80:
            black_r = x
        if r > 150 and g < 90 and 50 < b < 150 and r > b + 40:
            if ruby_l < 0:
                ruby_l = x
print("[hb-cellflow] bold-word right edge x =", black_r, " ruby-marker left edge x =", ruby_l)
if black_r < 0 or ruby_l < 0:
    print("[hb-cellflow] FAIL: could not locate both the bold word and the marker")
    sys.exit(1)
# When the cell flows correctly the marker starts AT/AFTER the bold word's right
# edge (delta ~<=0). The overprint bug painted it deep inside the bold run at its
# 12*8px grid column, ~116px LEFT of the real right edge. Require the marker to
# begin no more than 30px before the bold right edge.
delta = black_r - ruby_l
print("[hb-cellflow] (bold_right - ruby_left) =", delta, "px  (bug ~116, fixed ~0)")
if delta > 30:
    print("[hb-cellflow] FAIL: marker overprints the middle of the bold cell word")
    sys.exit(1)
print("[hb-cellflow] PASS in-cell runs flow proportionally without overprint")
PY
if [ $? -ne 0 ]; then fail=1; fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-cellflow] RESULT: FAIL"; exit 1
fi
echo "[hb-cellflow] RESULT: PASS"
