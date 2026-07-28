#!/usr/bin/env bash
# scripts/test_hambrowse_ellipsis_host.sh — FAST, QEMU-free gate for CSS
# `text-overflow: clip | ellipsis` (W3C css-overflow) in the native browser
# engine (lib/web/css/cascade.ad + lib/web/layout/box.ad):
#
#   For the canonical single-line idiom
#       overflow:hidden; white-space:nowrap; text-overflow:ellipsis
#   whose inline content is wider than the content box, the overflow-x clip's
#   right-edge truncation renders a `…` at the cut instead of a hard cut. The
#   monospace glyph set has no U+2026, so the ellipsis is emitted as "..." (three
#   ASCII dots), pulling the visible text back by up to 3 cells so text+ellipsis
#   fits the box. text-overflow:clip (the default) hard-cuts with NO ellipsis.
#
# The fixture renders four 160px nowrap-clip boxes, each with an over-long line:
#   .ell   text-overflow:ellipsis -> the line ends in "..." and fits the box
#   .clip  text-overflow:clip     -> a HARD cut, NO "..." (the control)
#   .deflt text-overflow unset    -> defaults to clip (NO "...")
#   .fits  ellipsis + wide box     -> content does NOT overflow, so NO "..."
#
# Asserts on the machine-readable SEG display list (the ellipsis line's text
# ends in "...", the clip/default/fits lines do NOT) AND on the real pixel PPM
# (the ellipsis ink fills to near the box right edge yet never overflows it).
#
# Builds the text-dump harness (x86_64-linux), the pixel backend
# (user/hambrowse_host_gfx.ad) AND native hambrowse — a break in the cascade OR
# the paint rasteriser is caught with no QEMU boot. Multi-line clamp
# (-webkit-line-clamp) and the left/`fade` variants are a documented follow-up.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_ellipsis.html"
mkdir -p "$OUT"
fail=0

echo "[hb-ell] compiling text harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/ell_compile.log"; then
    echo "[hb-ell] FAIL: host harness did not compile"; cat "$OUT/ell_compile.log"; exit 1
fi
echo "[hb-ell] PASS text harness compiled -> $BIN"

echo "[hb-ell] compiling pixel backend for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/ell_gfx.log"; then
    echo "[hb-ell] FAIL: pixel backend did not compile"; cat "$OUT/ell_gfx.log"; exit 1
fi
echo "[hb-ell] PASS pixel backend compiled -> $GFX"

echo "[hb-ell] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/ell_native.log"; then
    echo "[hb-ell] FAIL: native hambrowse did not compile"; cat "$OUT/ell_native.log"; exit 1
fi
echo "[hb-ell] PASS native hambrowse still compiles"

D="$OUT/ell_run.txt"
"$BIN" "$FIX" 800 >"$D" 2>&1 || { echo "[hb-ell] FAIL: render exited non-zero"; cat "$D"; exit 1; }
grep -E '^SEG' "$D" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D"; then echo "[hb-ell] PASS $2"
    else echo "[hb-ell] FAIL $2 (missing: $1)"; fail=1; fi
}
refute_grep() {   # pattern message
    if grep -Eq -- "$1" "$D"; then echo "[hb-ell] FAIL $2 (present: $1)"; fail=1
    else echo "[hb-ell] PASS $2"; fi
}

# ---- (1) text-overflow:ellipsis — the truncated line ends in "..." -----------
assert_grep 'bg#ffddaa \|Truncateme this la\.\.\.\|' \
    "text-overflow:ellipsis renders the truncated nowrap line ending in ..."

# ---- (2) text-overflow:clip — a HARD cut, no ellipsis ------------------------
assert_grep 'bg#aaddff \|Truncateme this label\|' \
    "text-overflow:clip hard-cuts the line (no ellipsis)"
refute_grep 'bg#aaddff \|Truncateme this la\.\.\.\|' \
    "text-overflow:clip does NOT emit an ellipsis"

# ---- (3) unspecified text-overflow defaults to clip --------------------------
assert_grep 'bg#ddffaa \|Truncateme this label\|' \
    "unspecified text-overflow defaults to clip (hard cut, no ellipsis)"
refute_grep 'bg#ddffaa \|Truncateme this la\.\.\.\|' \
    "default (clip) does NOT emit an ellipsis"

# ---- (4) ellipsis on a box the content FITS -> no ellipsis -------------------
assert_grep 'bg#ffaadd \|Short\|' \
    "text-overflow:ellipsis on non-overflowing content leaves it untouched"
refute_grep 'bg#ffaadd \|Short\.\.\.' \
    "non-overflowing content is NOT ellipsized"

# ---- (5) pixel render: the ellipsis line fills to near the box right edge yet
# never overflows it; the fitting control stays short. ------------------------
PPM="$OUT/ell.ppm"; PNG="$OUT/ell.png"
if "$GFX" "$FIX" "$PPM" 800 >"$OUT/ell_gfx_dump.txt" 2>&1; then
    if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/ell_png.log"; then
        echo "[hb-ell] PASS pixel render -> $PNG ($(file -b "$PNG" 2>/dev/null))"
    else
        echo "[hb-ell] FAIL png conversion"; cat "$OUT/ell_png.log"; fail=1
    fi
    # ellipsis ink right edge is inside the box (no overflow) and fills to within
    # ~24px of the box right edge (it truncated to fill, not way short); the
    # non-overflowing control's ink stays far short of its wide box.
    px=$(python3 - "$PPM" <<'PYEOF'
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
def measure(r,g,bl):
    # rows carrying this bg colour; within them, the extent of dark text ink.
    xs=[]; rows=set()
    for y in range(h):
        for x in range(w):
            o=(y*w+x)*3
            if data[o]==r and data[o+1]==g and data[o+2]==bl:
                xs.append(x); rows.add(y)
    if not xs: return None
    bx0,bx1=min(xs),max(xs)
    ink=[x for y in rows for x in range(bx0,bx1+1)
         if data[(y*w+x)*3]<80 and data[(y*w+x)*3+1]<80 and data[(y*w+x)*3+2]<80]
    if not ink: return (bx0,bx1,None,None)
    return (bx0,bx1,min(ink),max(ink))
e=measure(0xff,0xdd,0xaa)   # ellipsis box
fi=measure(0xff,0xaa,0xdd)  # fitting box
good=True
if e is None or e[3] is None:
    good=False
else:
    bx0,bx1,i0,i1=e
    if i1 > bx1: good=False            # ink overflows the box right edge
    if i1 < bx1-24: good=False         # ink does not fill up to the box edge
if fi is None or fi[3] is None:
    good=False
else:
    bx0,bx1,i0,i1=fi
    if i1 > bx0+120: good=False        # short content should NOT fill the wide box
print("ell=%s fits=%s imgw=%d -> %s" % (e, fi, w, "OK" if good else "BAD"))
PYEOF
)
    echo "[hb-ell] pixel: $px"
    if [ "${px##*-> }" = "OK" ]; then
        echo "[hb-ell] PASS pixel: ellipsis line fills to the box edge without overflowing; fitting control stays short"
    else
        echo "[hb-ell] FAIL pixel geometry check ($px)"; fail=1
    fi
else
    echo "[hb-ell] FAIL: pixel render exited non-zero"; cat "$OUT/ell_gfx_dump.txt"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-ell] RESULT: FAIL"; exit 1; fi
echo "[hb-ell] RESULT: PASS"
