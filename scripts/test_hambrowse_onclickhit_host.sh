#!/usr/bin/env bash
# scripts/test_hambrowse_onclickhit_host.sh — a POINTER click on an element whose
# only interactivity is an inline onclick="" must reach its handler.
#
# DOM records are minted lazily: an element gets one the first time script code
# looks it up. A page whose only interactivity is `<div onclick="...">` never
# looks anything up, so the element had NO record — _el_has_handler() could not
# see it, the rewrite never wrapped it in the synthetic "#__evt_N" link, and a
# coordinate click on its pixels resolved to nothing (HITLINK -1). An
# `<a href onclick>` failed differently and worse: the hit resolved the real
# href, so the page navigated and the handler never ran at all.
#
# The clicks are aimed at PAINTED PIXELS (each target's flat background is
# recovered from the rendered PPM) and driven through the true native chain
# htmlpage_hit_link -> he_link_evt_index -> he_dom_click_index, which is the
# same chain user/hambrowse.ad runs on a real pointer press.
#
# The last assertion is the guard rail: a plain <a href> with NO handler must
# NOT be wrapped (he_link_evt_index -1), or ordinary links would stop
# navigating.
#
# NOTE on the PPM byte order: the host driver writes its channels B,R,G.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/hambrowse_gfx_oh"
FIX="tests/fixtures/hambrowse_onclickhit.html"
W=640
fail=0

echo "[hb-oh] compiling host gfx driver (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/oh_compile.log"; then
    echo "[hb-oh] FAIL: host gfx driver did not compile"; cat "$OUT/oh_compile.log"; exit 1
fi
echo "[hb-oh] PASS host gfx driver compiled"

check() {  # check <label> <got> <op: eq|ne|ge> <expected>
    local label="$1" got="$2" op="$3" exp="$4" ok=1
    case "$op" in
        eq) [ "$got" = "$exp" ] || ok=0 ;;
        ne) [ "$got" != "$exp" ] || ok=0 ;;
        ge) [ "${got:-x}" -ge "$exp" ] 2>/dev/null || ok=0 ;;
    esac
    if [ "$ok" = 1 ]; then
        echo "[hb-oh] PASS $label (got $got)"
    else
        echo "[hb-oh] FAIL $label (got '$got', expected $op '$exp')"; fail=1
    fi
}

"$BIN" "$FIX" "$OUT/oh.ppm" "$W" >/dev/null 2>&1

rect() {   # rect <ppm> <rrggbb> -> "x0 x1 y0 y1"
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

# click <x> <y> — echoes "HITLINK HITEL RAN" for one coordinate press
click() {
    "$BIN" "$FIX" "$OUT/oh_click.ppm" "$W" clickxy "$1" "$2" 2>/dev/null \
        | awk '/^HITLINK /{ l=$2 } /^HITEL /{ e=$2 } /^CLICKED /{ r=$5 }
               END { printf "%s %s %s\n", (l==""?"?":l), (e==""?"?":e), (r==""?"0":r) }'
}

probe() {  # probe <label> <rrggbb>
    local label="$1" hx="$2"
    read -r x0 x1 y0 y1 < <(rect "$OUT/oh.ppm" "$hx")
    if [ "$x0" -lt 0 ]; then
        echo "[hb-oh] FAIL $label: background never painted (fixture broken)"
        fail=1; return
    fi
    read -r L E R < <(click $(( (x0 + x1) / 2 )) $(( (y0 + y1) / 2 )))
    echo "[hb-oh] $label painted $x0..$x1 rows $y0..$y1 -> link $L el $E ran $R"
    G_L="$L"; G_E="$E"; G_R="$R"
}

# ---- <a href onclick> : the hit must route to the ELEMENT, and the handler run
probe "anchor+onclick" c8dcf0
check "anchor+onclick: the painted box is live"          "$G_L" ge 0
check "anchor+onclick: resolves to a DOM event target"   "$G_E" ge 0
check "anchor+onclick: the handler actually RAN"         "$G_R" ge 1

# ---- <div onclick> : no <script>, no id lookup, no form — the case that was dead
probe "div+onclick" f0d2c8
check "div+onclick: the painted box is live"             "$G_L" ge 0
check "div+onclick: resolves to a DOM event target"      "$G_E" ge 0
check "div+onclick: the handler actually RAN"            "$G_R" ge 1

# ---- plain <a href> : must remain an ORDINARY navigable link (no evt wrap)
probe "plain anchor" f0f0c8
check "plain anchor: still a live link"                  "$G_L" ge 0
check "plain anchor: NOT wrapped as an event target"     "$G_E" eq -1

if [ "$fail" -ne 0 ]; then
    echo "[hb-oh] RESULT: FAIL"; exit 1
fi
echo "[hb-oh] RESULT: PASS"
