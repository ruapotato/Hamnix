#!/usr/bin/env bash
# scripts/test_hambrowse_chipcoord_host.sh — COORDINATE gate for inline-block
# chip GEOMETRY (the nav-pill / tag / badge idiom).
#
# test_hambrowse_hitcoord_host.sh proves a chip's padding is LIVE. This gate
# proves the chip is in the RIGHT PLACE. Both facts are invisible to an
# id-driven gate, and the second one is what broke: the CSS box model folds
# margin-left AND padding-left of a side into ONE inset column (_box_add_l),
# and the inline-block path — which already models its padding separately —
# read that column as the margin, so it applied padding-left a SECOND time.
# Everything the chip owns moved with it: its background fill, its border, and
# the link box a pointer hit-test resolves against. A padded pill under
# body{margin-left:40px} painted at x=67 where Chrome puts it at 40.
#
# Three shape invariants are asserted, each read off the PAINTED PIXELS and each
# cross-checked against `chromium --headless` getBoundingClientRect on the SAME
# fixture (so the expectation is a real browser's answer, not ours):
#
#   1. the first chip's box starts at the body's left inset — NOT at inset plus
#      padding-left;
#   2. source-ADJACENT chips are not separated by a gutter the author never
#      wrote (padding-right used to leak into it);
#   3. every chip's LABEL INK lands inside THAT chip's own box, offset from its
#      left edge by its own padding-left. The pixel renderer flows same-row
#      prose from its own pen and only honours a segment's start-x when the
#      segment carries indjump, so an un-resynced chip painted its label inside
#      its NEIGHBOUR's box — and an asymmetrically padded chip inset its pen by
#      half the padding SUM instead of the real left side.
#
# Finally the painted coordinates are clicked through the true native chain
# (htmlpage_hit_link -> he_link_evt_index) so a mispositioned box would also
# show up as a dead or wrong-target click.
#
# NOTE on the PPM byte order: the host driver writes its channels B,R,G
# (verified by rendering a #123456 block, which lands as 56 12 34).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/hambrowse_gfx_cc"
FIX="tests/fixtures/hambrowse_chipcoord.html"
W=640
fail=0

echo "[hb-cc] compiling host gfx driver (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/cc_compile.log"; then
    echo "[hb-cc] FAIL: host gfx driver did not compile"; cat "$OUT/cc_compile.log"; exit 1
fi
echo "[hb-cc] PASS host gfx driver compiled"

check() {  # check <label> <got> <op: eq|le|ge|between> <a> [b]
    local label="$1" got="$2" op="$3" a="$4" b="${5:-}" ok=1
    case "$op" in
        eq)      [ "$got" = "$a" ] || ok=0 ;;
        ne)      [ "$got" != "$a" ] || ok=0 ;;
        le)      [ "${got:-x}" -le "$a" ] 2>/dev/null || ok=0 ;;
        ge)      [ "${got:-x}" -ge "$a" ] 2>/dev/null || ok=0 ;;
        between) { [ "${got:-x}" -ge "$a" ] && [ "${got:-x}" -le "$b" ]; } 2>/dev/null || ok=0 ;;
    esac
    if [ "$ok" = 1 ]; then
        echo "[hb-cc] PASS $label (got $got)"
    else
        echo "[hb-cc] FAIL $label (got '$got', expected $op $a $b)"; fail=1
    fi
}

"$BIN" "$FIX" "$OUT/cc.ppm" "$W" >/dev/null 2>&1

# rect <ppm> <rrggbb> -> "x0 x1 y0 y1" of every pixel of exactly that colour
rect() {
    python3 - "$1" "$2" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read()
i, toks = 0, []
while len(toks) < 4:
    m = re.match(rb'\s*(#[^\n]*\n|\S+)', d[i:]); t = m.group(1); i += m.end()
    if not t.startswith(b'#'): toks.append(t)
w, h = int(toks[1]), int(toks[2]); px = d[i:]
hx = sys.argv[2]
r, g, b = int(hx[0:2], 16), int(hx[2:4], 16), int(hx[4:6], 16)
c = bytes([b, r, g])                                  # driver writes B,R,G
xs, ys = [], []
for y in range(h):
    row = px[y*w*3:(y+1)*w*3]
    st = 0
    while True:
        k = row.find(c, st)
        if k < 0: break
        if k % 3: st = k + 1; continue
        xs.append(k // 3); ys.append(y); st = k + 3
print(min(xs), max(xs), min(ys), max(ys)) if xs else print(-1, -1, -1, -1)
PY
}

# The fixture's three chips: flat background, then the chip's own ink colour.
read -r b1x0 b1x1 b1y0 b1y1 < <(rect "$OUT/cc.ppm" c8dcf0)
read -r b2x0 b2x1 b2y0 b2y1 < <(rect "$OUT/cc.ppm" f0d2c8)
read -r b3x0 b3x1 b3y0 b3y1 < <(rect "$OUT/cc.ppm" d2f0c8)
read -r t1x0 t1x1 t1y0 t1y1 < <(rect "$OUT/cc.ppm" d00000)
read -r t2x0 t2x1 t2y0 t2y1 < <(rect "$OUT/cc.ppm" 00a000)
read -r t3x0 t3x1 t3y0 t3y1 < <(rect "$OUT/cc.ppm" 0000d0)

for v in "$b1x0" "$b2x0" "$b3x0" "$t1x0" "$t2x0" "$t3x0"; do
    if [ "$v" -lt 0 ]; then
        echo "[hb-cc] FAIL fixture did not paint all three chips + their labels"
        exit 1
    fi
done
echo "[hb-cc] chips: c1 $b1x0..$b1x1  c2 $b2x0..$b2x1  c3 $b3x0..$b3x1"
echo "[hb-cc] label: c1 $t1x0..$t1x1  c2 $t2x0..$t2x1  c3 $t3x0..$t3x1"

# ---------------------------------------------------------------------------
# (1) the first chip starts at the BODY's left inset (40px), not at 40+padding.
#     The old double-padding bug put it at 40+24=64. 2px of slack absorbs the
#     fill's antialiased first column.
# ---------------------------------------------------------------------------
check "chip 1 box starts at the body left inset (40)" "$b1x0" between 38 42
check "chip 3 (its own row) starts at the body left inset (40)" "$b3x0" between 38 42

# ---------------------------------------------------------------------------
# (2) source-adjacent chips: no author-written gutter, and no overlap either.
#     Chrome's boxes touch exactly; allow a couple of px more than the engine's
#     inter-inline-box gutter, but nothing like the 32px the double padding made.
# ---------------------------------------------------------------------------
gap=$(( b2x0 - b1x1 - 1 ))
check "adjacent chips do not overlap" "$gap" ge 0
check "adjacent chips have no invented gutter (chromium: 0)" "$gap" le 10

# ---------------------------------------------------------------------------
# (3) each label's ink is inside ITS OWN chip's box, inset by that chip's
#     padding-left (24 / 24 / 36 in the fixture). Before the fix chip 2's label
#     was painted inside chip 1's box entirely.
# ---------------------------------------------------------------------------
check "chip 1 label starts inside chip 1" "$t1x0" between "$b1x0" "$b1x1"
check "chip 1 label ends inside chip 1"   "$t1x1" between "$b1x0" "$b1x1"
check "chip 2 label starts inside chip 2" "$t2x0" between "$b2x0" "$b2x1"
check "chip 2 label ends inside chip 2"   "$t2x1" between "$b2x0" "$b2x1"
check "chip 3 label starts inside chip 3" "$t3x0" between "$b3x0" "$b3x1"
check "chip 3 label ends inside chip 3"   "$t3x1" between "$b3x0" "$b3x1"

# padding-left inset (glyph side bearing costs a px or two, hence the window)
p1=$(( t1x0 - b1x0 )); p3=$(( t3x0 - b3x0 ))
check "chip 1 label inset == its padding-left (24)" "$p1" between 22 27
check "chip 3 label inset == its ASYMMETRIC padding-left (36)" "$p3" between 34 39

# ---------------------------------------------------------------------------
# (4) the painted coordinates really are the live ones, through the native chain.
# ---------------------------------------------------------------------------
hit() {
    "$BIN" "$FIX" "$OUT/cc_click.ppm" "$W" clickxy "$1" "$2" 2>/dev/null \
        | awk '/^HITLINK /{ print $2; exit }'
}
c1y=$(( (b1y0 + b1y1) / 2 )); c3y=$(( (b3y0 + b3y1) / 2 ))
L1=$(hit $(( (b1x0 + b1x1) / 2 )) "$c1y")
L2=$(hit $(( (b2x0 + b2x1) / 2 )) "$c1y")
L3=$(hit $(( (b3x0 + b3x1) / 2 )) "$c3y")
check "chip 1 centre is live"                "$L1" ge 0
check "chip 2 centre is live"                "$L2" ge 0
check "chip 3 centre is live"                "$L3" ge 0
check "chips 1 and 2 are DIFFERENT links"    "$L1" ne "$L2"
# the left padding column — the strip the mispositioned box used to leave dead
check "chip 1 left padding column is live"   "$(hit $(( b1x0 + 2 )) "$c1y")" ge 0
check "chip 3 left padding column is live"   "$(hit $(( b3x0 + 2 )) "$c3y")" ge 0

# ---------------------------------------------------------------------------
# (5) CHROMIUM CROSS-CHECK — the same three facts from a real browser. Font
#     metrics differ, so the pinned numbers are only the ones CSS fixes: the
#     body inset and each chip's padding-left. Skipped where chromium is absent.
# ---------------------------------------------------------------------------
CHROMIUM="$(command -v chromium || command -v chromium-browser || true)"
if [ -n "$CHROMIUM" ]; then
    tmp="$(mktemp -d)"
    cp "$FIX" "$tmp/p.html"
    cat >>"$tmp/p.html" <<'EOF'
<script>
var o = [];
document.querySelectorAll("a").forEach(function (a) {
  var r = a.getBoundingClientRect();
  var t = document.createRange(); t.selectNodeContents(a);
  var tr = t.getBoundingClientRect();
  o.push(Math.round(r.left) + "," + Math.round(r.right) + "," + Math.round(tr.left - r.left));
});
document.title = "R:" + o.join(" ");
EOF
    echo '</script>' >>"$tmp/p.html"
    xr="$("$CHROMIUM" --headless --no-sandbox --disable-gpu --window-size=640,900 \
          --dump-dom "file://$tmp/p.html" 2>/dev/null \
          | grep -o '<title>[^<]*</title>' | head -1 | sed 's/<[^>]*>//g;s/^R://')"
    rm -rf "$tmp"
    if [ -z "$xr" ]; then
        echo "[hb-cc] SKIP chromium xref (no geometry returned)"
    else
        echo "[hb-cc] chromium: $xr"
        set -- $xr
        xc1="$1"; xc2="$2"; xc3="$3"
        IFS=, read -r x1l x1r x1p <<<"$xc1"
        IFS=, read -r x2l x2r x2p <<<"$xc2"
        IFS=, read -r x3l x3r x3p <<<"$xc3"
        check "chromium: chip 1 box starts at the body inset"  "$x1l" eq 40
        check "chromium: chip 3 box starts at the body inset"  "$x3l" eq 40
        check "chromium: adjacent chip boxes TOUCH (gutter 0)" "$(( x2l - x1r ))" eq 0
        check "chromium: chip 1 text inset == padding-left 24" "$x1p" eq 24
        check "chromium: chip 2 text inset == padding-left 24" "$x2p" eq 24
        check "chromium: chip 3 text inset == padding-left 36" "$x3p" eq 36
        # ...and the engine agrees on every one of those CSS-fixed numbers.
        check "engine matches chromium on chip 1 left"    "$b1x0" between $(( x1l - 2 )) $(( x1l + 2 ))
        check "engine matches chromium on chip 3 left"    "$b3x0" between $(( x3l - 2 )) $(( x3l + 2 ))
        check "engine matches chromium on chip 1 inset"   "$p1"   between $(( x1p - 2 )) $(( x1p + 3 ))
        check "engine matches chromium on chip 3 inset"   "$p3"   between $(( x3p - 2 )) $(( x3p + 3 ))
    fi
else
    echo "[hb-cc] SKIP chromium xref (no chromium installed)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-cc] RESULT: FAIL"; exit 1
fi
echo "[hb-cc] RESULT: PASS"
