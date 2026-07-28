#!/usr/bin/env bash
# scripts/test_hambrowse_elembg_host.sh — FAST, QEMU-free gate for two
# high-leverage web-standards rungs in the native browser engine
# (lib/htmlengine.ad):
#
#   (A) ELEMENT-BOX BACKGROUNDS. A block-level element with `background-color`
#       (or `background`) paints its WHOLE box rectangle — coloured headers,
#       footers, nav strips, section/card panels — not just the strip behind
#       each text run. The engine emits a FILL record per box; the pixel
#       renderer (lib/htmlpage) and the host dump both paint it under the text.
#
#   (B) CENTRED BLOCKS. `width`/`max-width` + auto side margins
#       (`margin: 0 auto`) centre the box in its parent's content column — the
#       canonical modern article/container layout. The centred box's content
#       shifts right relative to a full-width sibling.
#
# Both are standards features shared by a huge class of real pages, so a
# regression in either must fail here without a QEMU boot. Builds BOTH targets
# (host harness x86_64-linux + native hambrowse x86_64-adder-user) so a break in
# either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_elembg.html"
mkdir -p "$OUT"

echo "[hb-elembg] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-elembg] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-elembg] PASS host harness compiled -> $BIN"

echo "[hb-elembg] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-elembg] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-elembg] PASS native hambrowse still compiles"

fail=0
assert_grep() {   # pattern file message
    if grep -Eq -- "$1" "$2"; then
        echo "[hb-elembg] PASS $3"
    else
        echo "[hb-elembg] FAIL $3 (missing: $1)"; fail=1
    fi
}

D0="$OUT/elembg.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-elembg] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E 'FILL|SEG [0-9]+ [0-9]+ .*(Header|body paragraph|Centered)' "$D0" || true

# (A) Element-box backgrounds: one FILL per background-bearing block, correct
# colour, from BOTH a class rule and an inline style="" declaration.
assert_grep 'FILL .* #223344'  "$D0" "header element paints its full box (class bg)"
assert_grep 'FILL .* #ffcc00'  "$D0" "div.panel paints its full box (class bg)"
assert_grep 'FILL .* #cc0000'  "$D0" "inline style=background-color paints its full box"
assert_grep 'FILL .* #eeeeee'  "$D0" "footer element paints its full box (class bg)"

# The plain <p> (no background) must NOT get a fill, and a stale stylesheet bg
# must NOT leak onto every box: exactly the four coloured boxes above.
nf=$(grep -c '^FILL ' "$D0")
if [ "$nf" -eq 4 ]; then
    echo "[hb-elembg] PASS exactly 4 background boxes (no leak onto plain content)"
else
    echo "[hb-elembg] FAIL expected 4 FILL records, got $nf (bg leaked or missed)"; fail=1
fi

# (B) Centred block: the `.wrap { max-width:400px; margin:0 auto }` column's
# content shifts RIGHT of a full-width plain paragraph in the same body.
bx=$(grep -E 'SEG [0-9]+ [0-9]+ .*\|Plain body paragraph' "$D0" | awk '{print $3}' | head -1)
cx=$(grep -E 'SEG [0-9]+ [0-9]+ .*\|Centered wrap column'  "$D0" | awk '{print $3}' | head -1)
echo "[hb-elembg] plain-body x=$bx  centred-wrap x=$cx"
if [ -n "$bx" ] && [ -n "$cx" ] && [ "$cx" -gt "$((bx + 40))" ]; then
    echo "[hb-elembg] PASS max-width + margin:auto centres the column (x $bx -> $cx)"
else
    echo "[hb-elembg] FAIL centred column not shifted right (plain=$bx wrap=$cx)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-elembg] RESULT: FAIL"; exit 1
fi
echo "[hb-elembg] RESULT: PASS"
