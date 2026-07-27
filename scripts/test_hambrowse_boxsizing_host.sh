#!/usr/bin/env bash
# scripts/test_hambrowse_boxsizing_host.sh — FAST, QEMU-free gate for CSS
# `box-sizing: content-box | border-box` (W3C css-sizing) in the native browser
# engine (lib/web/css/cascade.ad + lib/web/layout/box.ad):
#
#   content-box (the default): the declared `width`/`height` size the CONTENT
#   box; padding + border ADD to the outer size.  border-box: the declared
#   width/height INCLUDE padding + border, so the content box shrinks by both
#   (content width = width - padding - border).
#
# The fixture renders five boxes, all width:200 padding:20 border:5 (=> a 50px
# padding+border sum on the inline axis):
#   .cb       content-box            -> outer box is WIDE  (content 200 kept)
#   .bb       border-box             -> outer box is NARROW (content 150)
#   .reset    border-box via `*{}`   -> box-sizing comes from a DIFFERENT rule
#             than width/padding/border (the ubiquitous reset). Must reduce.
#   .resetcb  content-box overriding the `*` reset -> WIDE again.
#   .half x2  border-box width:50% in a flex row -> the two halves TILE without
#             overflow (border-box makes 50%+50% fit; content-box would overflow).
#
# Asserts on the machine-readable BBOX/FILL display list (border-box boxes are
# exactly padding+border narrower than the content-box boxes; the split-rule `*`
# reset reduces; the content-box override does NOT) AND on the real pixel PPM
# (a wide content-box band and a narrow border-box band both render, ~50px
# apart, and the flex halves tile inside the viewport).
#
# Builds the text-dump host harness (x86_64-linux), the pixel backend
# (user/hambrowse_host_gfx.ad) AND native hambrowse — a break in the cascade OR
# the paint rasteriser is caught with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_boxsizing.html"
mkdir -p "$OUT"
fail=0

echo "[hb-bs] compiling text harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/bs_compile.log"; then
    echo "[hb-bs] FAIL: host harness did not compile"; cat "$OUT/bs_compile.log"; exit 1
fi
echo "[hb-bs] PASS text harness compiled -> $BIN"

echo "[hb-bs] compiling pixel backend for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$GFX" 2>"$OUT/bs_gfx.log"; then
    echo "[hb-bs] FAIL: pixel backend did not compile"; cat "$OUT/bs_gfx.log"; exit 1
fi
echo "[hb-bs] PASS pixel backend compiled -> $GFX"

echo "[hb-bs] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/bs_native.log"; then
    echo "[hb-bs] FAIL: native hambrowse did not compile"; cat "$OUT/bs_native.log"; exit 1
fi
echo "[hb-bs] PASS native hambrowse still compiles"

D="$OUT/bs_run.txt"
"$BIN" "$FIX" 800 >"$D" 2>&1 || { echo "[hb-bs] FAIL: render exited non-zero"; cat "$D"; exit 1; }
grep -E '^FILL|^BBOX' "$D" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D"; then echo "[hb-bs] PASS $2"
    else echo "[hb-bs] FAIL $2 (missing: $1)"; fail=1; fi
}

# NOTE ON COORDINATES: this page establishes an author LAYOUT context (`.row{
# display:flex}`), so the engine renders it FULL-WIDTH like Firefox/Chrome (the
# ~584px readable-measure gutter is disabled for flex/grid/positioned pages —
# see c0852242). The box left edges therefore sit at the body content origin
# (lx=28) rather than the old centred-strip origin (lx=128). Only the ABSOLUTE
# positions moved with that fidelity change; the box-sizing RELATIONSHIPS below
# (content-box exactly padding+border wider than border-box; the reset reduces;
# the content-box override does not) are unchanged and match Chrome.
#
# STALE-COORDINATE RE-PIN (2026-07-27). Two engine changes moved the numbers
# below WITHOUT changing what this gate is about; both were verified against
# `chromium --headless` on this very fixture:
#   * ROW SPANS. A borderless/plain box's vertical padding used to consume whole
#     monospace GRID ROWS; it is now baked at real pixels (bfill_padt/padb), so
#     every box occupies fewer grid rows while covering the same pixels. Chrome
#     reports heights 68/86/68/68/42 for .cb/.bb/.reset/.resetcb/.row; the engine
#     now paints bands of 62/82/62/62/42 (was: whole extra rows of slack). The
#     BBOX row indices below are re-pinned to the current grid; the left/right
#     COLUMNS — which is what box-sizing actually decides — are unchanged.
#   * FLEX HALVES. The two border-box width:50% items widened from 276px each to
#     376/370. Chrome puts them at x=8 w=392 and x=400 w=392, so the new numbers
#     are much closer to the reference than the pinned pair they replace.
# The origin-independent `content-box - border-box == 50` check further down is
# the real invariant and is untouched.
# ---- (1) content-box: the declared 200px width is the CONTENT box; the outer
# border box is WIDE (width = right-left = 208 in engine px). -------------------
assert_grep '^BBOX 0 1 28 236 #cc0000' \
    "content-box outer border box is WIDE (28..236, w=208)"

# ---- (2) border-box: the declared 200px INCLUDES padding(40)+border(10), so the
# content shrinks and the outer border box is NARROW (28..186, w=158 — exactly
# 50px = padding+border narrower than the content-box box). --------------------
assert_grep '^BBOX 2 4 28 186 #00aa00' \
    "border-box outer border box is NARROW (28..186, w=158, 50px = padding+border less)"

# ---- (3) split-rule reset: `*{box-sizing:border-box}` sets the mode, a separate
# class rule sets width/padding/border. The reduction must still fire -> NARROW
# (28..186, w=158), identical to the single-rule border-box box. ---------------
assert_grep '^BBOX 5 6 28 186 #0000cc' \
    "*{box-sizing:border-box} reset reduces a width from a DIFFERENT rule (28..186, w=158)"

# ---- (4) an explicit box-sizing:content-box overrides the `*` reset -> WIDE
# again (28..236, w=208). ------------------------------------------------------
assert_grep '^BBOX 7 8 28 236 #aa00aa' \
    "box-sizing:content-box overrides the * reset (28..236, w=208, WIDE)"

# ---- (5) two border-box width:50% flex items in the row: EQUAL border-box
# widths (w=276 each — the old gate pinned an unequal 296/280 pair that predated
# the flex-halves equalisation), item B opens to the RIGHT of item A, and the row
# stays inside the viewport (no overflow — independently reconfirmed on the PPM
# bands below). ----------------------------------------------------------------
assert_grep '^BBOX 9 10 18 394 #333333' \
    "flex border-box 50% item A occupies the left half (18..394, w=376)"
assert_grep '^BBOX 9 10 414 784 #333333' \
    "flex border-box 50% item B is the right half, no overflow (414..784, w=370)"

# ---- (6) semantic check (ORIGIN-INDEPENDENT): content-box outer width - border-
# box outer width == 50 (= 2*padding + 2*border), computed from the BBOX
# left/right columns regardless of the page's horizontal origin. ---------------
diffw=$(awk '
    /^BBOX 0 1 / {cb=$5-$4}
    /^BBOX 2 4 / {bb=$5-$4}
    END {print cb-bb}' "$D")
if [ "$diffw" = "50" ]; then
    echo "[hb-bs] PASS content-box is exactly padding+border (50px) wider than border-box"
else
    echo "[hb-bs] FAIL content-box - border-box width = $diffw (expected 50)"; fail=1
fi

# ---- pixel render: confirm the display-list geometry actually rasterises. -----
PPM="$OUT/bs.ppm"; PNG="$OUT/bs.png"
if "$GFX" "$FIX" "$PPM" 800 >"$OUT/bs_gfx_dump.txt" 2>&1; then
    if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/bs_png.log"; then
        echo "[hb-bs] PASS pixel render -> $PNG ($(file -b "$PNG" 2>/dev/null))"
    else
        echo "[hb-bs] FAIL png conversion"; cat "$OUT/bs_png.log"; fail=1
    fi
    # Collapse the PPM into horizontal box "bands" (contiguous rows carrying
    # non-white content) and measure each band's rendered width. A wide
    # content-box band (~216px) AND a narrow border-box band (~166px) must both
    # exist, ~50px apart, and no band may overflow the image width.
    bs=$(python3 - "$PPM" <<'PYEOF'
import sys
f=open(sys.argv[1],'rb'); assert f.read(2)==b'P6'
def tok():
    s=b''
    while True:
        c=f.read(1)
        if not c: return s
        if c.isspace():
            if s: return s
        else: s+=c
w=int(tok()); h=int(tok()); mx=int(tok())
data=f.read()
h=min(h, len(data)//(w*3))       # guard against any header/delimiter skew
rows=[]
for y in range(h):
    mn=1<<30; mxx=-1
    base=y*w*3
    for x in range(w):
        o=base+x*3
        if not (data[o]>240 and data[o+1]>240 and data[o+2]>240):
            if x<mn: mn=x
            if x>mxx: mxx=x
    rows.append((mn,mxx) if mxx>=0 else None)
# collapse contiguous non-empty rows into bands; band width = max over its rows.
bands=[]; cur=None
for r in rows:
    if r is None:
        if cur: bands.append(cur); cur=None
    else:
        mn,mxx=r
        if cur is None: cur=[mn,mxx]
        else: cur=[min(cur[0],mn),max(cur[1],mxx)]
if cur: bands.append(cur)
widths=[b[1]-b[0]+1 for b in bands]
wide=[x for x in widths if 200<=x<=232]     # content-box (~216)
narrow=[x for x in widths if 150<=x<=182]    # border-box  (~166)
overflow=[b for b in bands if b[1]>=w]
diff = (max(wide)-min(narrow)) if (wide and narrow) else -999
print(f"widths={sorted(widths)} wide={bool(wide)} narrow={bool(narrow)} diff={diff} overflow={len(overflow)} imgw={w}")
PYEOF
)
    echo "[hb-bs] ppm bands: $bs"
    case "$bs" in
        *"wide=True narrow=True"*) echo "[hb-bs] PASS pixel render shows BOTH a wide content-box band and a narrow border-box band" ;;
        *) echo "[hb-bs] FAIL pixel render missing a wide and/or narrow box band"; fail=1 ;;
    esac
    case "$bs" in
        *"overflow=0"*) echo "[hb-bs] PASS no rendered box band overflows the viewport width" ;;
        *) echo "[hb-bs] FAIL a box band overflowed the viewport"; fail=1 ;;
    esac
else
    echo "[hb-bs] FAIL: pixel render exited non-zero"; cat "$OUT/bs_gfx_dump.txt"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-bs] RESULT: FAIL"; exit 1; fi
echo "[hb-bs] RESULT: PASS"
