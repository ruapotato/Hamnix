#!/usr/bin/env bash
# scripts/test_hambrowse_navgap_host.sh — FAST, QEMU-free PIXEL gate for the
# top-nav "AboutStore" run-together bug (live google top bar).
#
# Two ADJACENT `display:inline-block` links that carry a horizontal margin
# (margin:0 5px) must render SEPARATED in the PIXEL backend, not glued. The
# monospace text-dump already spaced them (pen_x advances by the margin), but the
# PIXEL renderer flows prose contiguously and only honours an inter-run gap via
# seg_lmarg — which the inline-block chip open/close did NOT set, so adjacent
# nav links glued into "AboutStore" while the (invisible) chip fill boxes were
# correctly spaced. The fix threads the chip's margin-left/right into
# g_pending_lmarg (mirroring the inline <span> path). This gate renders the real
# pixels and asserts the two blue link words form TWO separate horizontal
# clusters with a whitespace gap between them.
#
# Also builds native hambrowse so a break there is caught.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_navgap.html"
PPM="$OUT/navgap.ppm"
PNG="$OUT/navgap.png"
mkdir -p "$OUT"
fail=0

echo "[hb-navgap] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/navgap_gfx.log"; then
    echo "[hb-navgap] FAIL: pixel backend did not compile"; cat "$OUT/navgap_gfx.log"; exit 1
fi
echo "[hb-navgap] PASS pixel backend compiled"

echo "[hb-navgap] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/navgap_native.log"; then
    echo "[hb-navgap] FAIL: native hambrowse did not compile"; cat "$OUT/navgap_native.log"; exit 1
fi
echo "[hb-navgap] PASS native hambrowse still compiles"

D="$OUT/navgap_dump.txt"
if ! "$GFX" "$FIX" "$PPM" 400 >"$D" 2>&1; then
    echo "[hb-navgap] FAIL: pixel render exited non-zero"; cat "$D"; exit 1
fi
# Both link words must have been laid out.
if grep -q 'SEGTXT About' "$D" && grep -q 'SEGTXT Store' "$D"; then
    echo "[hb-navgap] PASS both nav links laid out (About, Store)"
else
    echo "[hb-navgap] FAIL: nav link segments missing"; grep SEGTXT "$D"; fail=1
fi

if ! python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/navgap_png.log"; then
    echo "[hb-navgap] FAIL png conversion"; cat "$OUT/navgap_png.log"; exit 1
fi

# --- PIXEL assertion: the two blue link words are two separate clusters ------
python3 - "$PPM" <<'PY'
import sys
# Read the PPM (P6) directly — no PIL dependency.
data = open(sys.argv[1], 'rb').read()
assert data[:2] == b'P6', "not a P6 ppm"
# parse header: P6 <w> <h> <maxval>\n<pixels>
idx = 2
vals = []
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
idx += 1  # single whitespace after maxval
px = data[idx:]
def blue(x, y):
    o = (y*w + x)*3
    r, g, b = px[o], px[o+1], px[o+2]
    return b > 90 and b > r + 30 and b > g + 30   # strongly blue (link text)
# Columns that contain any blue pixel anywhere vertically.
cols = [any(blue(x, y) for y in range(0, min(h, 60))) for x in range(w)]
# Collapse into runs of blue columns.
runs = []
x = 0
while x < w:
    if cols[x]:
        s = x
        while x < w and cols[x]:
            x += 1
        runs.append((s, x-1))
    else:
        x += 1
print("[hb-navgap] blue text clusters (x0,x1):", runs)
if len(runs) < 2:
    print("[hb-navgap] FAIL: links glued into a single cluster (AboutStore)")
    sys.exit(1)
# Require a real whitespace gap (>=4 px) between the first two clusters.
gap = runs[1][0] - runs[0][1] - 1
print("[hb-navgap] gap between 'About' and 'Store' =", gap, "px")
if gap < 4:
    print("[hb-navgap] FAIL: gap too small")
    sys.exit(1)
print("[hb-navgap] PASS adjacent inline-block nav links keep a pixel gap")
PY
if [ $? -ne 0 ]; then fail=1; fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-navgap] RESULT: FAIL"; exit 1
fi
echo "[hb-navgap] RESULT: PASS"
