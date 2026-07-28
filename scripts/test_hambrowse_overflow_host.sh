#!/usr/bin/env bash
# scripts/test_hambrowse_overflow_host.sh — FAST, QEMU-free gate for the CSS
# box-model `overflow` property (W3C css-overflow) in the native browser engine
# (lib/web/css/cascade.ad + lib/web/layout/box.ad):
#
#   A box with overflow:hidden / scroll / auto / clip (via `overflow`,
#   `overflow-x`, `overflow-y`) establishes a CLIP RECT at its padding edge.
#   Descendant content that falls outside the box is removed from the paint:
#     * VERTICAL: a child taller than the box is clipped to the box bottom —
#       the child's background FILL is clamped to the box's row span and the
#       overflowing text rows are dropped.
#     * HORIZONTAL: a nowrap line wider than the box is TRUNCATED at the box's
#       right edge.
#   overflow:visible (the default) does NOT clip — the child's full height
#   survives (the control box).
#
# The fixture renders four boxes, each 3 rows / 200px tall-or-narrow with an
# oversized (6-line / nowrap) child:
#   .clip   overflow:hidden  -> child clamped to 3 rows (lines 4-6 removed)
#   .scroll overflow:auto    -> child clamped to 3 rows (scroll container clip)
#   .vis    overflow:visible -> child KEEPS all 6 rows (unclipped control)
#   .hclip  overflow:hidden nowrap -> the wide line is cut at the right edge
#
# Asserts on the machine-readable FILL/SEG display list AND on the real pixel
# render (a PPM the pixel backend emits): the clipped child's colour spans far
# fewer pixel rows than the unclipped control's identical-size child.
#
# Builds BOTH the text-dump harness (x86_64-linux) AND the pixel backend
# (user/hambrowse_host_gfx.ad), and confirms native hambrowse still compiles.
# Interactive scroll offset / scrollbars for auto|scroll are a documented
# follow-up; this gate covers the (highest-value) static clip.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_overflow.html"
mkdir -p "$OUT"
fail=0

echo "[hb-ovf] compiling text harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/ovf_compile.log"; then
    echo "[hb-ovf] FAIL: host harness did not compile"; cat "$OUT/ovf_compile.log"; exit 1
fi
echo "[hb-ovf] PASS text harness compiled -> $BIN"

echo "[hb-ovf] compiling pixel backend for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/ovf_gfx.log"; then
    echo "[hb-ovf] FAIL: pixel backend did not compile"; cat "$OUT/ovf_gfx.log"; exit 1
fi
echo "[hb-ovf] PASS pixel backend compiled -> $GFX"

echo "[hb-ovf] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/ovf_native.log"; then
    echo "[hb-ovf] FAIL: native hambrowse did not compile"; cat "$OUT/ovf_native.log"; exit 1
fi
echo "[hb-ovf] PASS native hambrowse still compiles"

D="$OUT/ovf_run.txt"
"$BIN" "$FIX" 800 >"$D" 2>&1 || { echo "[hb-ovf] FAIL: render exited non-zero"; cat "$D"; exit 1; }
grep -E '^FILL|CkeepA|CgoneD|VkeepF|Nowrap' "$D" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D"; then echo "[hb-ovf] PASS $2"
    else echo "[hb-ovf] FAIL $2 (missing: $1)"; fail=1; fi
}
refute_grep() {   # pattern message
    if grep -Eq -- "$1" "$D"; then echo "[hb-ovf] FAIL $2 (present: $1)"; fail=1
    else echo "[hb-ovf] PASS $2"; fi
}

# ---- (1) overflow:hidden — vertical clip -------------------------------------
# The oversized blue child FILL (#3366cc) is clamped to the box's 3-row span
# [0,3); its first 3 lines survive, lines 4-6 are removed.
assert_grep '^FILL 0 3 [0-9]+ [0-9]+ #3366cc' \
    "overflow:hidden clamps the child background to the box (rows 0-3)"
assert_grep 'CkeepA' "overflow:hidden keeps the child's first line"
refute_grep 'CgoneD' "overflow:hidden clips the child's 4th line (below the box)"
refute_grep 'CgoneF' "overflow:hidden clips the child's 6th line"

# ---- (2) overflow:auto — scroll container, same static clip -------------------
assert_grep '^FILL 3 6 [0-9]+ [0-9]+ #cc4433' \
    "overflow:auto clamps the child background to the box (rows 3-6)"
assert_grep 'SkeepC' "overflow:auto keeps the visible lines"
refute_grep 'SgoneD' "overflow:auto clips content past the box bottom"

# ---- (3) overflow:visible — the UNCLIPPED control ----------------------------
# Same oversized child, overflow visible: its FILL is NOT clamped to 3 rows and
# ALL six lines survive.
assert_grep 'VkeepF' "overflow:visible does NOT clip — the 6th line survives"
refute_grep '^FILL 6 9 [0-9]+ [0-9]+ #33aa66' \
    "overflow:visible child fill is NOT clamped to the 3-row box"
assert_grep '^FILL 6 12 [0-9]+ [0-9]+ #33aa66' \
    "overflow:visible child fill keeps its full 6-row height"

# ---- (4) overflow-x hidden — horizontal truncation ---------------------------
# The nowrap line is cut at the box's right edge: "Nowrapfront" survives, the
# trailing "Nowraptail ... right edge here." is truncated away.
assert_grep 'SEG 9 [0-9]+ .*bg#ffddaa \|Nowrapfront' \
    "overflow-x:hidden keeps the head of the nowrap line"
refute_grep 'Nowraptail' \
    "overflow-x:hidden truncates the nowrap line at the box right edge"

# ---- (5) pixel render: the clipped child spans far fewer rows than the control
PPM="$OUT/ovf.ppm"; PNG="$OUT/ovf.png"
if "$GFX" "$FIX" "$PPM" 800 >"$OUT/ovf_gfx_dump.txt" 2>&1; then
    if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/ovf_png.log"; then
        echo "[hb-ovf] PASS pixel render -> $PNG ($(file -b "$PNG" 2>/dev/null))"
    else
        echo "[hb-ovf] FAIL png conversion"; cat "$OUT/ovf_png.log"; fail=1
    fi
    # Scan the PPM: vertical pixel EXTENT of the clipped blue child (#3366cc) must
    # be clearly SHORTER than the identical-size unclipped green control child
    # (#33aa66). This proves the clip happened in the real rasteriser, not just
    # the text dump.
    py=$(python3 - "$PPM" <<'PYEOF'
import sys
f=open(sys.argv[1],'rb'); assert f.read(2)==b'P6'
def tok():
    b=b''
    while True:
        c=f.read(1)
        if c.isspace():
            if b: return b
        else: b+=c
w=int(tok()); h=int(tok()); mx=int(tok())
data=f.read(w*h*3)
def extent(r,g,b):
    ys=[y for y in range(h) for x in range(w)
        if data[(y*w+x)*3]==r and data[(y*w+x)*3+1]==g and data[(y*w+x)*3+2]==b]
    return (min(ys),max(ys)) if ys else (None,None)
cb=extent(0x33,0x66,0xcc)   # clipped (hidden) child
vg=extent(0x33,0xaa,0x66)   # visible (unclipped) control child
def span(e): return (e[1]-e[0]) if e[0] is not None else -1
print("%d %d" % (span(cb), span(vg)))
PYEOF
) || { echo "[hb-ovf] FAIL ppm scan"; fail=1; py="-1 -1"; }
    clip_span=$(echo "$py" | awk '{print $1}')
    vis_span=$(echo "$py" | awk '{print $2}')
    echo "[hb-ovf] pixel extent: clipped-child=$clip_span rows, visible-child=$vis_span rows"
    if [ "$clip_span" -gt 0 ] && [ "$vis_span" -gt 0 ] && \
       [ "$vis_span" -gt "$((clip_span + clip_span / 2))" ]; then
        echo "[hb-ovf] PASS pixel: clipped child is much shorter than the visible control"
    else
        echo "[hb-ovf] FAIL pixel: clip=$clip_span not clearly < visible=$vis_span"; fail=1
    fi
else
    echo "[hb-ovf] FAIL: pixel render exited non-zero"; cat "$OUT/ovf_gfx_dump.txt"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-ovf] RESULT: FAIL"; exit 1
fi
echo "[hb-ovf] RESULT: PASS"
