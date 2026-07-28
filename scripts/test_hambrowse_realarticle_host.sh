#!/usr/bin/env bash
# scripts/test_hambrowse_realarticle_host.sh — FAST, QEMU-free gate that renders
# a REALISTIC content page (a Wikipedia-article / documentation shaped fixture:
# lead paragraph + float:right shaded infobox, a nested table-of-contents list,
# h2/h3 sections, a bordered data table, a blockquote, a <figure>/<figcaption>,
# and <code>/<pre>) and pixel-asserts the fidelity wins that make it read like a
# real browser's output rather than a rough approximation:
#
#   1. FLOAT:RIGHT INFOBOX BACKGROUND — the table's `background-color` fills the
#      WHOLE infobox uniformly (not patchy per-cell shading with white gutters).
#      Sampled at three interior points, all == the declared #f0f4f8.
#   2. INFOBOX BORDER — a real 1px stroke in the DECLARED rule colour (#a2a9b1),
#      with body text wrapping to its LEFT (the infobox is pinned to the right).
#   3. DATA-TABLE GRID — internal column rules are SINGLE clean lines: each cell's
#      right edge coincides with the next cell's left edge (no 3px "doubled/gappy"
#      grid the old +2/+6 asymmetric inset produced).
#   4. LINK UNDERLINES — text-decoration:underline links draw a real rule row.
#   5. NESTED TOC LIST — every <li> across the two nesting levels draws a marker.
#   6. FIGURE — the <figcaption> text is laid out (figure block present).
#
# Built with the frozen Python seed compiler; PPM sampling is stdlib-only.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_realarticle.html"
DUMP="$OUT/realarticle_dump.txt"
PPM="$OUT/realarticle.ppm"
PNG="$OUT/realarticle.png"
mkdir -p "$OUT"
fail=0

echo "[hb-real-article] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/realarticle_compile.log"; then
    echo "[hb-real-article] FAIL: driver did not compile"; cat "$OUT/realarticle_compile.log"; exit 1
fi
echo "[hb-real-article] PASS pixel backend compiled"

echo "[hb-real-article] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/realarticle_native.log"; then
    echo "[hb-real-article] FAIL: native hambrowse did not compile"; cat "$OUT/realarticle_native.log"; exit 1
fi
echo "[hb-real-article] PASS native hambrowse still compiles"

echo "[hb-real-article] rendering $FIX ..."
if ! "$BIN" "$FIX" "$PPM" 900 >"$DUMP" 2>&1; then
    echo "[hb-real-article] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 && echo "[hb-real-article] wrote $PNG"

# --- (1)+(2)+(3): parse the BORDER dump + sample the infobox fill in one python pass
python3 - "$DUMP" "$PPM" <<'PY'
import sys
dump, ppm = sys.argv[1], sys.argv[2]

bords = []   # (idx, x0,y0,x1,y1,edge,inside)
for ln in open(dump):
    f = ln.split()
    if len(f) >= 2 and f[0] == "BORDER" and f[1] != "n":
        d = {}
        i = 2
        while i + 1 < len(f):
            d[f[i]] = f[i+1]; i += 2
        try:
            bords.append((int(f[1]), int(d["x0"]), int(d["y0"]), int(d["x1"]),
                          int(d["y1"]), d.get("edge"), d.get("inside")))
        except (KeyError, ValueError):
            pass

def load_ppm(p):
    data = open(p, "rb").read()
    assert data[:2] == b"P6", "not P6 ppm"
    idx = 2; vals = []
    while len(vals) < 3:
        while data[idx] in b" \t\n\r": idx += 1
        if data[idx:idx+1] == b"#":
            while data[idx] not in b"\n": idx += 1
            continue
        s = idx
        while data[idx] not in b" \t\n\r": idx += 1
        vals.append(int(data[s:idx]));
    idx += 1
    w, h, _ = vals
    return w, h, data[idx:]

w, h, px = load_ppm(ppm)
def pix(x, y):
    o = (y*w + x)*3
    return "#%02x%02x%02x" % (px[o], px[o+1], px[o+2])

rc = 0

# (2) The FIRST bordered box is the float:right infobox: real stroke in the
#     declared #a2a9b1 rule colour, pinned to the RIGHT half of the 900px canvas.
info = next((b for b in bords if b[0] == 0), None)
if info is None:
    print("[hb-real-article] FAIL: no infobox border stroked"); rc = 1
else:
    _, ix0, iy0, ix1, iy1, iedge, iinside = info
    if iedge == "#a2a9b1" and ix0 > w//2:
        print(f"[hb-real-article] PASS float:right infobox strokes declared #a2a9b1 border pinned right (x0={ix0})")
    else:
        print(f"[hb-real-article] FAIL infobox border edge={iedge} x0={ix0} (want #a2a9b1, right half)"); rc = 1

    # (1) Uniform background fill: three interior points all == declared #f0f4f8.
    cx = (ix0 + ix1)//2
    pts = [(cx, iy0 + (iy1-iy0)//2), (ix0 + 12, iy0 + (iy1-iy0)*3//4),
           (ix1 - 12, iy0 + (iy1-iy0)//2)]
    cols = [pix(x, y) for (x, y) in pts]
    if all(c == "#f0f4f8" for c in cols):
        print(f"[hb-real-article] PASS infobox background fills the whole box uniformly (#f0f4f8 x3)")
    else:
        print(f"[hb-real-article] FAIL infobox bg not uniform: {cols} (want #f0f4f8 x3)"); rc = 1

# (3) The data table's per-row cell rects must form a SINGLE-line grid: within a
#     row, each cell's right edge x1 == the next cell's left edge x0 (deduped),
#     NOT 3px apart. Group the grey (#808080) cell rects by their y0 row band.
cells = [b for b in bords if b[5] == "#808080"]
rows = {}
for c in cells:
    rows.setdefault(c[2], []).append(c)
checked = 0; bad = 0
for y0, cs in rows.items():
    cs.sort(key=lambda c: c[1])
    for a, b in zip(cs, cs[1:]):
        checked += 1
        # a.x1 (right edge of left cell) should coincide with b.x0 (left edge of
        # right cell) within 1px — a shared single rule, not a doubled pair.
        if abs(a[3] - b[1]) > 1:
            bad += 1
if checked == 0:
    print("[hb-real-article] FAIL data-table produced no adjacent cell rects to check"); rc = 1
elif bad == 0:
    print(f"[hb-real-article] PASS data-table column rules are single lines ({checked} shared edges coincide)")
else:
    print(f"[hb-real-article] FAIL {bad}/{checked} data-table column rules are doubled/gappy"); rc = 1

sys.exit(rc)
PY
[ $? -ne 0 ] && fail=1

# --- (4) link underlines actually drawn
ULINE=$(awk '/^ULINE / {for(i=1;i<=NF;i++) if($i=="linkul") print $(i+1); exit}' "$DUMP")
echo "[hb-real-article] link underline rules drawn: linkul=${ULINE:-0}"
if [ "${ULINE:-0}" -ge 1 ]; then
    echo "[hb-real-article] PASS text-decoration:underline links draw a real rule row"
else
    echo "[hb-real-article] FAIL no link underline drawn"; fail=1
fi

# --- (5) nested TOC list markers (2 levels, 7 <li>)
LM=$(awk '/^LIST markers / {print $3; exit}' "$DUMP")
echo "[hb-real-article] list markers drawn: $LM"
if [ "${LM:-0}" -ge 7 ]; then
    echo "[hb-real-article] PASS nested TOC list draws a marker per item ($LM >= 7)"
else
    echo "[hb-real-article] FAIL nested TOC markers missing ($LM < 7)"; fail=1
fi

# --- (6) figure/figcaption laid out
if grep -qE '^SEGTXT .*Figure 1' "$DUMP"; then
    echo "[hb-real-article] PASS <figcaption> text laid out"
else
    echo "[hb-real-article] FAIL <figcaption> text missing"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-real-article] RESULT: PASS"
else
    echo "[hb-real-article] RESULT: FAIL"; exit 1
fi
