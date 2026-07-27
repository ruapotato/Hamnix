#!/usr/bin/env bash
# scripts/test_hambrowse_hitcoord_host.sh — COORDINATE-driven pointer gate.
#
# Every other browser interaction gate in this tree resolves the element it acts
# on BY ID (he_dom_click("#id") / the FIELDSEG geometry dump). That leaves the
# one thing a real user actually does completely untested: putting the pointer on
# the PIXELS of a link and pressing. A clickable rect that drifts away from the
# painted glyphs is invisible to every id-driven gate — and that is exactly the
# class of defect this gate exists to catch (a padded block/inline-block <a>
# whose live area was only its glyph run, so the pill's/card's visible padding
# was dead and the live area appeared shifted right of the box on screen).
#
# The oracle is deliberately NOT the engine's own geometry:
#   * the PAINTED pixels are read straight out of the rendered PPM — inline link
#     glyphs by their marker ink colour, box links by the unique flat background
#     colour the fixture gives each anchor — and the clicks are aimed at THOSE
#     coordinates;
#   * where chromium is installed, getBoundingClientRect + elementFromPoint on
#     the same fixture supply a REAL browser's hit geometry, so the expectation
#     is Chrome's answer and not ours.
# The clicks run the true native chain a pointer press runs in user/hambrowse.ad:
# htmlpage_hit_link -> he_link_evt_index -> he_dom_click_index (the `clickxy X Y`
# verb of user/hambrowse_host_gfx.ad).
#
# NOTE on the PPM byte order: the host driver writes its channels B,R,G (verified
# by rendering a #123456 block, which lands as 56 12 34), so the pixel readers
# below index accordingly.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/hambrowse_gfx_hc"
W=640
fail=0

echo "[hb-hc] compiling host gfx driver (x86_64-linux) ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$BIN" 2>"$OUT/hc_compile.log"; then
    echo "[hb-hc] FAIL: host gfx driver did not compile"; cat "$OUT/hc_compile.log"; exit 1
fi
echo "[hb-hc] PASS host gfx driver compiled"

CHROMIUM="$(command -v chromium || command -v chromium-browser || true)"

# hit <fixture> <x> <y>  ->  echoes the resolved engine link id (-1 = nothing)
hit() {
    "$BIN" "$1" "$OUT/hc_click.ppm" "$W" clickxy "$2" "$3" 2>/dev/null \
        | awk '/^HITLINK /{ print $2; exit }'
}

check() {  # check <label> <got> <op: eq|ne|ge> <expected>
    local label="$1" got="$2" op="$3" exp="$4" ok=1
    case "$op" in
        eq) [ "$got" = "$exp" ] || ok=0 ;;
        ne) [ "$got" != "$exp" ] || ok=0 ;;
        ge) [ "${got:-x}" -ge "$exp" ] 2>/dev/null || ok=0 ;;
    esac
    if [ "$ok" = 1 ]; then
        echo "[hb-hc] PASS $label (got $got)"
    else
        echo "[hb-hc] FAIL $label (got '$got', expected $op '$exp')"; fail=1
    fi
}

# ---------------------------------------------------------------------------
# (1) ORDINARY INLINE LINKS — click the PAINTED GLYPHS.
#     Body margin, block padding, nesting, centred text and a link several rows
#     down. The PPM scan finds each run of link ink; the clicks land on
#     its centre and on its LEFT EDGE (the first pixel a creeping left offset
#     would kill), and blank space well left of the ink must stay dead.
# ---------------------------------------------------------------------------
FIX1="tests/fixtures/hambrowse_hitcoord.html"
"$BIN" "$FIX1" "$OUT/hc1.ppm" "$W" >/dev/null 2>&1

ink_bands() {    # -> one "x0 x1 y0 y1" line per painted MAGENTA ink band
    python3 - "$1" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read()
i, toks = 0, []
while len(toks) < 4:
    m = re.match(rb'\s*(#[^\n]*\n|\S+)', d[i:]); t = m.group(1); i += m.end()
    if not t.startswith(b'#'): toks.append(t)
w, h = int(toks[1]), int(toks[2]); px = d[i:]
rows = []
for y in range(h):
    # magenta ink: B and R both strong, G clearly weaker. Subpixel AA on black
    # body text produces blue-dominant fringes but always keeps R ~= G, so the
    # R-G split is what separates real link ink from antialiased prose.
    xs = [x for x in range(w)
          if px[(y*w+x)*3] > 120 and px[(y*w+x)*3+1] > 120
          and px[(y*w+x)*3+1] - px[(y*w+x)*3+2] > 80]
    if xs: rows.append((y, min(xs), max(xs)))
bands = []
for (y, a, b) in rows:
    if bands and y - bands[-1][1] <= 2:
        bands[-1][1] = y
        bands[-1][2] = min(bands[-1][2], a); bands[-1][3] = max(bands[-1][3], b)
    else:
        bands.append([y, y, a, b])
for (y0, y1, a, b) in bands:
    print(a, b, y0, y1)
PY
}

n1=0
while read -r x0 x1 y0 y1; do
    [ -n "${x0:-}" ] || continue
    n1=$((n1 + 1))
    cx=$(( (x0 + x1) / 2 )); cy=$(( (y0 + y1) / 2 ))
    check "inline link #$n1: click the painted glyphs at ($cx,$cy)" \
          "$(hit "$FIX1" "$cx" "$cy")" ge 0
    lx=$((x0 + 1))
    check "inline link #$n1: left glyph edge x=$lx is live" \
          "$(hit "$FIX1" "$lx" "$cy")" ge 0
    ox=$((x0 - 30))
    if [ "$ox" -ge 0 ]; then
        check "inline link #$n1: blank space 30px left (x=$ox) is NOT live" \
              "$(hit "$FIX1" "$ox" "$cy")" eq -1
    fi
    check "inline link #$n1: 30px right of the ink (x=$((x1 + 30))) is NOT live" \
          "$(hit "$FIX1" "$((x1 + 30))" "$cy")" eq -1
done < <(ink_bands "$OUT/hc1.ppm")
check "inline fixture: every <a> painted an ink run" "$n1" ge 5

# ---------------------------------------------------------------------------
# (2) BOX-SHAPED LINKS — click the PAINTED BOX, its padding included.
#     A padded `display:block` <a> card and padded inline-block nav pills (one
#     row of them CENTRED, since a centred chip's box is slid by the text-align
#     pass and its hit box has to be slid with it). Each anchor's exact painted
#     rect is recovered from its unique flat background colour, so the click
#     coordinates come off the picture, not off the engine.
# ---------------------------------------------------------------------------
box_rects() {    # box_rects <ppm> <name>=<rrggbb> ...  -> "name x0 x1 y0 y1"
    python3 - "$@" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read()
i, toks = 0, []
while len(toks) < 4:
    m = re.match(rb'\s*(#[^\n]*\n|\S+)', d[i:]); t = m.group(1); i += m.end()
    if not t.startswith(b'#'): toks.append(t)
w, h = int(toks[1]), int(toks[2]); px = d[i:]
for spec in sys.argv[2:]:
    name, hx = spec.split('=')
    r, g, b = int(hx[0:2], 16), int(hx[2:4], 16), int(hx[4:6], 16)
    c = bytes([b, r, g])                      # driver writes B,R,G
    xs, ys = [], []
    for y in range(h):
        row = px[y*w*3:(y+1)*w*3]
        st = 0
        while True:
            k = row.find(c, st)
            if k < 0: break
            if k % 3: st = k + 1; continue
            xs.append(k // 3); ys.append(y); st = k + 3
    print(name, min(xs), max(xs), min(ys), max(ys)) if xs \
        else print(name, -1, -1, -1, -1)
PY
}

# NOTE: runs in the CURRENT shell (its check() output and `fail` must survive),
# so the box count is returned through $BOXN, never through stdout.
BOXN=0
probe_boxes() {  # probe_boxes <fixture> <ppm> <name=rrggbb> ...
    local fix="$1" ppm="$2"; shift 2
    local n=0
    while read -r name bx0 bx1 by0 by1; do
        [ -n "${name:-}" ] || continue
        if [ "$bx0" -lt 0 ]; then
            echo "[hb-hc] FAIL $name: background never painted (fixture broken)"
            fail=1; continue
        fi
        n=$((n + 1))
        local cx=$(( (bx0 + bx1) / 2 )) cy=$(( (by0 + by1) / 2 ))
        # Centre, then the padding strips the glyph-run-only hit rect used to
        # leave dead: left (the ~30px the user reported), right, top, bottom.
        check "$name: centre of the painted box ($cx,$cy)" \
              "$(hit "$fix" "$cx" "$cy")" ge 0
        check "$name: left padding column x=$((bx0 + 2))" \
              "$(hit "$fix" "$((bx0 + 2))" "$cy")" ge 0
        check "$name: right padding column x=$((bx1 - 2))" \
              "$(hit "$fix" "$((bx1 - 2))" "$cy")" ge 0
        check "$name: top padding row y=$((by0 + 2))" \
              "$(hit "$fix" "$cx" "$((by0 + 2))")" ge 0
        check "$name: bottom padding row y=$((by1 - 2))" \
              "$(hit "$fix" "$cx" "$((by1 - 2))")" ge 0
        # ...and nothing beyond the painted box may become live.
        check "$name: 8px right of the box is NOT live" \
              "$(hit "$fix" "$((bx1 + 8))" "$cy")" eq -1
    done < <(box_rects "$ppm" "$@")
    BOXN="$n"
}

FIX2="tests/fixtures/hambrowse_hitbox.html"
"$BIN" "$FIX2" "$OUT/hc2.ppm" "$W" >/dev/null 2>&1
probe_boxes "$FIX2" "$OUT/hc2.ppm" c1=c8dcf0 c2=f0d2c8 c3=d2f0c8
check "block-card fixture: all three anchor boxes painted" "$BOXN" ge 3

FIX3="tests/fixtures/hambrowse_hitpill.html"
"$BIN" "$FIX3" "$OUT/hc3.ppm" "$W" >/dev/null 2>&1
probe_boxes "$FIX3" "$OUT/hc3.ppm" p1=c8dcf0 p2=f0d2c8 p3=d2f0c8
check "nav-pill fixture: all three chip boxes painted" "$BOXN" ge 3

# Distinct anchors must stay distinct: two ADJACENT pills (no gap between their
# boxes) must resolve to different link ids, so the fallback cannot collapse a
# whole nav bar onto one destination.
read -r _ q1x0 q1x1 q1y0 q1y1 < <(box_rects "$OUT/hc3.ppm" p1=c8dcf0)
read -r _ q2x0 q2x1 q2y0 q2y1 < <(box_rects "$OUT/hc3.ppm" p2=f0d2c8)
L1="$(hit "$FIX3" $(( (q1x0 + q1x1) / 2 )) $(( (q1y0 + q1y1) / 2 )))"
L2="$(hit "$FIX3" $(( (q2x0 + q2x1) / 2 )) $(( (q2y0 + q2y1) / 2 )))"
if [ "$L1" != "$L2" ] && [ "${L1:-x}" -ge 0 ] 2>/dev/null && [ "${L2:-x}" -ge 0 ] 2>/dev/null; then
    echo "[hb-hc] PASS adjacent pills resolve to DIFFERENT links ($L1 vs $L2)"
else
    echo "[hb-hc] FAIL adjacent pills must resolve to different links (got '$L1' and '$L2')"
    fail=1
fi

# The clickxy verb must really drive the whole native chain, not just the
# hit-test: a resolved link is handed to he_link_evt_index (HITEL), which routes
# to he_dom_click_index for handler targets. Assert the chain reported.
chain="$("$BIN" "$FIX3" "$OUT/hc_click.ppm" "$W" clickxy \
         $(( (q1x0 + q1x1) / 2 )) $(( (q1y0 + q1y1) / 2 )) 2>/dev/null \
         | grep -c '^HITEL ')"
check "clickxy drove hit-test -> he_link_evt_index" "$chain" ge 1

# ---------------------------------------------------------------------------
# (3) CHROMIUM CROSS-CHECK — a real browser's hit geometry for the same pages.
#     Chrome's clickable area for a padded block/inline-block <a> is its whole
#     border box: elementFromPoint a few px inside the LEFT PADDING returns the
#     anchor, and the border box is wider than the text run. Assert that SHAPE
#     (padding belongs to the link) rather than pinning exact px — font metrics
#     differ, but the shape must not. Skipped (never failed) with no chromium.
# ---------------------------------------------------------------------------
xref() {   # xref <fixture> — prints "N_ANCHORS N_BOXWIDER N_PADDINGHITS"
    local tmp; tmp="$(mktemp -d)"
    cp "$1" "$tmp/p.html"
    cat >>"$tmp/p.html" <<'EOF'
<script>
var na = 0, wider = 0, padhit = 0;
document.querySelectorAll("a").forEach(function (a) {
  na++;
  var r = a.getBoundingClientRect();
  var t = document.createRange(); t.selectNodeContents(a);
  var tr = t.getBoundingClientRect();
  if (r.width > tr.width + 1) wider++;
  var e = document.elementFromPoint(r.left + 4, r.top + r.height / 2);
  while (e && e !== document.body) { if (e === a) { padhit++; break; } e = e.parentNode; }
});
document.title = "R:" + na + " " + wider + " " + padhit;
</script>
EOF
    "$CHROMIUM" --headless --no-sandbox --disable-gpu --window-size=640,900 \
        --dump-dom "file://$tmp/p.html" 2>/dev/null \
        | grep -o '<title>[^<]*</title>' | head -1 | sed 's/<[^>]*>//g;s/^R://'
    rm -rf "$tmp"
}

if [ -n "$CHROMIUM" ]; then
    for f in "$FIX2" "$FIX3"; do
        read -r na wider padhit < <(xref "$f")
        if [ -z "${na:-}" ]; then
            echo "[hb-hc] SKIP chromium xref $f (no geometry returned)"
            continue
        fi
        check "chromium xref $(basename "$f"): anchors seen" "$na" ge 3
        check "chromium xref $(basename "$f"): border box WIDER than text run" \
              "$wider" eq "$na"
        check "chromium xref $(basename "$f"): elementFromPoint in the LEFT PADDING is the <a>" \
              "$padhit" eq "$na"
    done
else
    echo "[hb-hc] SKIP chromium xref (no chromium installed)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-hc] RESULT: FAIL"; exit 1
fi
echo "[hb-hc] RESULT: PASS"
