#!/usr/bin/env bash
# scripts/test_hambrowse_inlbgap_host.sh — the inter-chip gutter is SOURCE
# WHITESPACE, not a constant.
#
# WHAT IT CATCHES
# ===============
# An inline-block is an INLINE-LEVEL box: the only thing between two of them is
# whatever the source puts there — nothing at all, or collapsed whitespace worth
# exactly one space. The engine added a constant INLB_GAP (6px) at every chip
# close instead, so source-adjacent chips were shoved 6px apart where chrome's
# boxes TOUCH, and whitespace-separated chips got 6px where chrome gives one
# space advance (~4px at 16px). It was 32px before an earlier fix; 6 was still
# a constant.
#
# MEASURED (chromium --headless, the fixture's own rows):
#     rowA  a:0-32.02  b:32.02-64.03  c:68.03-102.70  d:106.70-141.38
#           -> a|b gap 0.00 (source-adjacent), b|c 4.45, c|d 4.45 (whitespace)
#     rowB  two source-adjacent chips with margin:0 5px -> gap 10.00 (5 + 5)
#
# The gaps asserted here are read off the RASTERIZER's own fill rectangles, and
# every chip's flat colour is separately confirmed to have reached the rendered
# PPM — so a rect that is reported but never painted cannot pass. The chromium
# numbers are re-measured live when chromium is installed (SKIPped, never
# failed, when it is not).
#
# NOTE ON WIDTHS: chip WIDTHS are deliberately NOT asserted. Our default face is
# wider than chromium's, so the boxes are wider (AAA is 44px here against
# chromium's 32) — a font-metrics difference, and a separate question from
# whether the GUTTER between them is right. The gutter is what this gate is for.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/hambrowse_gfx_ibgap"
FIX="tests/fixtures/hambrowse_inlbgap.html"
W=640
fail=0

echo "[hb-ibgap] compiling host gfx driver (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/ibgap_compile.log"; then
    echo "[hb-ibgap] FAIL: host gfx driver did not compile"; cat "$OUT/ibgap_compile.log"; exit 1
fi
echo "[hb-ibgap] PASS host gfx driver compiled"

"$BIN" "$FIX" "$OUT/ibgap.ppm" "$W" >/dev/null 2>&1
[ -s "$OUT/ibgap.ppm" ] || { echo "[hb-ibgap] FAIL: fixture did not render"; exit 1; }

# Each chip's PAINTED rect. Two independent readings, both required:
#   * the rasterizer's own fill rectangle (the POSFILL line: x0 inclusive, x1
#     exclusive) — exact, so the gutters can be asserted to the pixel;
#   * the chip's flat colour actually appearing in the rendered PPM — proof the
#     rect was really painted and not merely reported. (The PPM extents run ±1
#     against the rect at the antialiased edges, which is why the arithmetic
#     uses the rect and the PPM is the presence check.)
declare -A X0 X1
while read -r idx a b; do
    [ -n "${idx:-}" ] || continue
    case "$idx" in
        0) nm=a ;; 1) nm=b ;; 2) nm=c ;; 3) nm=d ;; 4) nm=m1 ;; 5) nm=m2 ;;
        *) continue ;;
    esac
    X0[$nm]="$a"; X1[$nm]="$b"
done < <("$BIN" "$FIX" "$OUT/ibgap.ppm" "$W" 2>/dev/null \
         | awk '/^POSFILL /{ for (i=1;i<=NF;i++){ if($i=="x0") x0=$(i+1); if($i=="x1") x1=$(i+1) } print $2, x0, x1 }')

painted() {   # painted <rrggbb> -> 1 if that exact colour appears in the PPM
    python3 - "$OUT/ibgap.ppm" "$1" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read()
i, toks = 0, []
while len(toks) < 4:
    m = re.match(rb'\s*(#[^\n]*\n|\S+)', d[i:]); t = m.group(1); i += m.end()
    if not t.startswith(b'#'): toks.append(t)
hx = sys.argv[2]
r, g, b = int(hx[0:2], 16), int(hx[2:4], 16), int(hx[4:6], 16)
print(1 if bytes([b, r, g]) in d[i:] else 0)     # the host driver writes B,R,G
PY
}

for spec in a=c8dcf0 b=f0d2c8 c=d2f0c8 d=f0e6c8 m1=c8c8f0 m2=f0c8f0; do
    nm="${spec%%=*}"; hx="${spec##*=}"
    if [ -z "${X0[$nm]:-}" ]; then
        echo "[hb-ibgap] FAIL chip $nm has no fill rectangle (fixture broken)"; fail=1
    elif [ "$(painted "$hx")" != "1" ]; then
        echo "[hb-ibgap] FAIL chip $nm colour #$hx never reached the pixels"; fail=1
    fi
done
[ "$fail" = 0 ] || { echo "[hb-ibgap] RESULT: FAIL (fixture did not paint)"; exit 1; }

# gap = next chip's left edge minus this one's right edge (x1 is exclusive).
gap() { echo $(( ${X0[$2]} - ${X1[$1]} )); }

check_gap() {  # check_gap <from> <to> <expected> <label>
    local g; g="$(gap "$1" "$2")"
    if [ "$g" = "$3" ]; then
        echo "[hb-ibgap] PASS $4 (gap $g px)"
    else
        echo "[hb-ibgap] FAIL $4 (gap $g px, expected $3)"; fail=1
    fi
}

check_gap a b 0 "source-ADJACENT chips touch, exactly as chrome boxes do"
check_gap b c 4 "a chip separated by a SPACE is one space advance away"
check_gap c d 4 "a chip separated by a NEWLINE gets the same collapsed space"
check_gap m1 m2 10 "two adjacent chips with margin:0 5px are 5+5 apart and nothing more"

# ---------------------------------------------------------------------------
# CHROMIUM CROSS-CHECK — re-measure the same gaps in a real browser.
# ---------------------------------------------------------------------------
CHROMIUM="$(command -v chromium || command -v chromium-browser || true)"
if [ -n "$CHROMIUM" ]; then
    XG="$("$CHROMIUM" --headless --no-sandbox --disable-gpu \
            --window-size=640,600 --hide-scrollbars --force-device-scale-factor=1 \
            --enable-logging=stderr --dump-dom "file://$(readlink -f "$FIX")" \
            --virtual-time-budget=4000 2>&1 >/dev/null \
          | sed -n 's/^.*IBGAP \([^"]*\).*$/\1/p' | head -1)"
    if [ -z "$XG" ]; then
        # The fixture carries no script; inject the probe into a copy.
        T="$(mktemp -d)"; cp "$FIX" "$T/p.html"
        cat >> "$T/p.html" <<'EOF'
<script>
function g(p, q) {
  var A = document.getElementById(p).getBoundingClientRect();
  var B = document.getElementById(q).getBoundingClientRect();
  return Math.round((B.left - A.right) * 100) / 100;
}
console.log('IBGAP ab=' + g('a','b') + ' bc=' + g('b','c') + ' cd=' + g('c','d') + ' m=' + g('m1','m2'));
</script>
EOF
        XG="$("$CHROMIUM" --headless --no-sandbox --disable-gpu \
                --window-size=640,600 --hide-scrollbars --force-device-scale-factor=1 \
                --enable-logging=stderr --dump-dom "file://$T/p.html" 2>&1 >/dev/null \
              | sed -n 's/^.*IBGAP \(.*\)$/\1/p' | sed 's/", source:.*$//' | head -1)"
        rm -rf "$T"
    fi
    if [ -z "$XG" ]; then
        echo "[hb-ibgap] SKIP chromium cross-check (chromium logged nothing)"
    else
        echo "[hb-ibgap] chromium says: $XG"
        # Compare chromium's own numbers, ROUNDED to whole pixels, against the
        # four gaps asserted above: a sub-pixel space advance (4.45 as measured)
        # is the same 4px gutter once rasterised, while a CONSTANT gutter would
        # show up as the SAME number in all three of ab/bc/cd — which is the
        # failure this is guarding against.
        rnd() { printf '%s\n' "$XG" | sed -n "s/^.*$1=\([0-9.]*\).*$/\1/p" | awk '{printf "%d", ($1 + 0.5)}'; }
        for pair in ab:0 bc:4 cd:4 m:10; do
            k="${pair%%:*}"; v="${pair##*:}"; got="$(rnd "$k")"
            if [ "$got" = "$v" ]; then
                echo "[hb-ibgap] PASS chromium $k gutter rounds to $v too"
            else
                echo "[hb-ibgap] FAIL chromium $k gutter rounds to $got, this gate asserts $v — the EXPECTATION is what to re-check, not the engine"
                fail=1
            fi
        done
    fi
else
    echo "[hb-ibgap] SKIP chromium cross-check (no chromium installed)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-ibgap] RESULT: FAIL"; exit 1
fi
echo "[hb-ibgap] RESULT: PASS"
