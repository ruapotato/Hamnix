#!/usr/bin/env bash
# scripts/test_hambrowse_underline.sh — FAST, QEMU-free gate for CSS
# text-decoration in the hambrowse layout engine (lib/htmlengine.ad).
#
# Before this, the engine only underlined <a> links (g_uline was hard-wired to
# g_link>=0); the `text-decoration` property was parsed by nothing and IGNORED.
# Now the CSS cascade + inline style="" thread a text-decoration scope through
# _open_style/_close_style so:
#   * text-decoration: underline   draws a real 1px rule under NON-link text;
#   * text-decoration: none        strips a link's default underline
#                                  (the ubiquitous nav-bar / button pattern).
#
# The driver (user/hambrowse_host_gfx.ad) emits a ULINE diagnostic:
#   ULINE cssn <N> linkul <N> linkplain <N> rulepix #rgb
#   cssn      = underlined NON-link segments (proves CSS underline honoured)
#   linkul    = underlined link segments
#   linkplain = link segments with the underline stripped (proves :none honoured)
#   rulepix   = framebuffer pixel just below the first CSS-underlined seg's
#               baseline — must be INKED (dark), proving the flag reached paint.
#
# The fixture has 2 CSS-underlined non-link paragraphs, 1 link with :none, and 1
# default link. Before the feature: cssn=0 (CSS underline ignored) and
# linkplain=0 (:none ignored -> BOTH links underlined, linkul=2). Those counts
# are impossible to produce without the property being honoured, so the gate is
# not tautological. Built with the frozen Python seed compiler.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx_uline"
mkdir -p "$OUT"
fail=0

echo "[hb-uline] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/uline_compile.log"; then
    echo "[hb-uline] FAIL: driver did not compile"; cat "$OUT/uline_compile.log"; exit 1
fi
echo "[hb-uline] PASS pixel backend compiled"

echo "[hb-uline] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native_uline.elf" 2>"$OUT/uline_native.log"; then
    echo "[hb-uline] FAIL: native hambrowse did not compile"; cat "$OUT/uline_native.log"; exit 1
fi
echo "[hb-uline] PASS native hambrowse still compiles"

FIX="tests/fixtures/hambrowse_underline.html"
W=640
DUMP="$OUT/uline_dump.txt"
PPM="$OUT/underline_after.ppm"
PNG="$OUT/underline_after.png"

echo "[hb-uline] rendering $FIX at width $W ..."
if ! "$BIN" "$FIX" "$PPM" "$W" >"$DUMP" 2>&1; then
    echo "[hb-uline] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^ULINE' "$DUMP"
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 \
    && echo "[hb-uline] wrote $PNG"

# Parse: "ULINE cssn <cssn> linkul <linkul> linkplain <linkplain> rulepix #rgb"
read CSSN LINKUL LINKPLAIN RULEPIX \
    < <(awk '/^ULINE / {print $3, $5, $7, $9; exit}' "$DUMP")
echo "[hb-uline] cssn=$CSSN linkul=$LINKUL linkplain=$LINKPLAIN rulepix=$RULEPIX"

# (1) Both CSS-underlined non-link paragraphs (.u span + inline style) underline.
if [ "${CSSN:-0}" -ge 2 ]; then
    echo "[hb-uline] PASS CSS text-decoration:underline honoured on non-link text (cssn=$CSSN)"
else
    echo "[hb-uline] FAIL CSS underline ignored (cssn=$CSSN, expected >=2)"; fail=1
fi

# (2) text-decoration:none stripped the nav link's default underline.
if [ "${LINKPLAIN:-0}" -ge 1 ]; then
    echo "[hb-uline] PASS text-decoration:none stripped a link underline (linkplain=$LINKPLAIN)"
else
    echo "[hb-uline] FAIL text-decoration:none ignored (linkplain=$LINKPLAIN, expected >=1)"; fail=1
fi

# (3) The default link (no override) still keeps its underline.
if [ "${LINKUL:-0}" -ge 1 ]; then
    echo "[hb-uline] PASS default link still underlined (linkul=$LINKUL)"
else
    echo "[hb-uline] FAIL default link lost its underline (linkul=$LINKUL)"; fail=1
fi

# (4) The rule is REALLY painted: the pixel below the first CSS-underlined seg's
# baseline is dark ink, not white paper. Parse #rrggbb -> require it dark.
HEX="${RULEPIX#\#}"
if [ -n "$HEX" ] && [ "$HEX" != "ffffff" ]; then
    R=$((16#${HEX:0:2})); G=$((16#${HEX:2:2})); B=$((16#${HEX:4:2}))
    if [ "$R" -lt 128 ] && [ "$G" -lt 128 ] && [ "$B" -lt 128 ]; then
        echo "[hb-uline] PASS underline rule pixel is inked (rulepix=$RULEPIX)"
    else
        echo "[hb-uline] FAIL underline rule pixel not dark (rulepix=$RULEPIX)"; fail=1
    fi
else
    echo "[hb-uline] FAIL underline rule pixel is white paper (rulepix=$RULEPIX)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-uline] PASS"
else
    echo "[hb-uline] FAIL"; exit 1
fi
