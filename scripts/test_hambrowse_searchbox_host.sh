#!/usr/bin/env bash
# scripts/test_hambrowse_searchbox_host.sh — FAST, QEMU-free gate for the two
# real-user browser improvements added on top of the W3C engine:
#
#   (1) a Firefox/Chrome-style SEARCH BOX beside the URL bar (default engine =
#       Google). The chrome compositor (lib/browserwin.ad) draws a second field
#       to the right of the address bar; on Enter the native front end
#       (user/hambrowse.ad) URL-encodes the query and navigates to
#       https://www.google.com/search?q=<query>.
#
#   (2) text-like <input> (text/search/email/url/tel/password/number) renders as
#       a REAL bordered, filled field box (light fill + 1px border + value/caret)
#       instead of the '[value___]' underscore ASCII. The text-dump keeps the
#       bracket tokens (its gates assert on them); the PIXEL renderer skips them
#       and draws the box — mirrored by the seg_field flag in the layout engine.
#
# The gate builds the host chrome compositor (x86_64-linux) AND the native
# browser (x86_64-adder-user) with the frozen seed compiler, renders a page of
# text inputs into the full window chrome, and asserts:
#   * the search-box field surface is drawn (a WHITE pixel in its right edge),
#   * the input-box FLOW tokens still render (regression guard for #2's text
#     representation), and
#   * both targets compile (so the search-navigation code stays wired).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
FIX="tests/fixtures/hambrowse_search_input.html"
fail=0

echo "[hb-sb] compiling host chrome compositor (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_gfx_window.ad "$OUT/hb_gfxwin" 2>"$OUT/sb_gfx.log"; then
    echo "[hb-sb] FAIL: gfx-window harness did not compile"; cat "$OUT/sb_gfx.log"; exit 1
fi
echo "[hb-sb] PASS chrome compositor compiled"

echo "[hb-sb] compiling host text harness (x86_64-linux) ..."
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$OUT/hb_host" 2>"$OUT/sb_host.log"; then
    echo "[hb-sb] FAIL: text harness did not compile"; cat "$OUT/sb_host.log"; exit 1
fi
echo "[hb-sb] PASS text harness compiled"

echo "[hb-sb] compiling native hambrowse (x86_64-adder-user) ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hb_native.elf" 2>"$OUT/sb_native.log"; then
    echo "[hb-sb] FAIL: native browser (search-box code) did not compile"
    cat "$OUT/sb_native.log"; exit 1
fi
echo "[hb-sb] PASS native browser compiles (search box wired)"

# (1) Render the full window chrome; the harness prints a PIX probe near the
# right edge of the search field — it must be the white field surface.
D1="$OUT/sb_gfx.txt"
"$OUT/hb_gfxwin" "$FIX" "$OUT/sb_chrome.ppm" 900 640 >"$D1" 2>&1 \
    || { echo "[hb-sb] FAIL: chrome render exited non-zero"; cat "$D1"; exit 1; }
# 3rd PIX line is the search-box probe (see hambrowse_gfx_window.ad).
SBPIX=$(grep -E '^PIX' "$D1" | sed -n '3p')
echo "[hb-sb] search-box probe: ${SBPIX:-<none>}"
if printf '%s' "$SBPIX" | grep -Eq '255 255 255$'; then
    echo "[hb-sb] PASS search box drawn (white field surface at its right edge)"
else
    echo "[hb-sb] FAIL search box field surface not white (got: ${SBPIX:-none})"; fail=1
fi

# (2) The text inputs still emit their FLOW tokens (the pixel box is a render
# overlay; the text representation is unchanged, so #2 did not regress the dump).
D2="$OUT/sb_flow.txt"
"$OUT/hb_host" "$FIX" 900 >"$D2" 2>&1 \
    || { echo "[hb-sb] FAIL: text render exited non-zero"; cat "$D2"; exit 1; }
FLOW=$(grep -E '^FLOW' "$D2" | grep -F '[' | head -1)
echo "[hb-sb] FLOW: $FLOW"
# The value tokens are now padded to the 20-col UA default field width (size=20,
# Chrome/Firefox parity) so a short value still renders a WIDE, clickable box:
# 'hello world' -> [hello world_________], 'me@example.com' -> [me@example.com______].
# The trailing '_' run is part of the reserved field width; match the value then
# its underscore padding.
for tok in '\[hello world_+\]' '\[me@example\.com_+\]' '\[\*\*\*\*\*\*_+\]' ; do
    if printf '%s' "$FLOW" | grep -Eq -- "$tok"; then
        echo "[hb-sb] PASS input token present: $tok"
    else
        echo "[hb-sb] FAIL input token missing: $tok"; fail=1
    fi
done
if printf '%s' "$D2" | grep -Fq 'secret'; then
    echo "[hb-sb] FAIL password plaintext leaked"; fail=1
else
    echo "[hb-sb] PASS password value stays masked"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-sb] RESULT: FAIL"; exit 1
fi
echo "[hb-sb] RESULT: PASS"
