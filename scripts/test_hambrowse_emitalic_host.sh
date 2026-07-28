#!/usr/bin/env bash
# scripts/test_hambrowse_emitalic_host.sh — FAST, QEMU-free render-to-PNG gate
# for the <em>/<i> + CSS font-style:italic FAUX-OBLIQUE fix (lib/web/dom/canvas.ad
# seg accessor, lib/web/layout/box.ad seg_italic channel, lib/web/css/cascade.ad
# font-style, lib/htmlpaint.ad glyph shear, lib/htmlpage.ad wiring). Drives the
# REAL pixel backend (user/hambrowse_host_gfx.ad) and PIXEL-asserts the SLANT:
#
#   * an <em>/<i>/font-style:italic run is rendered as a faux-oblique — a
#     horizontal SHEAR of the single bitmap face — so the top of each glyph is
#     pushed RIGHT of its bottom (measured slant clearly POSITIVE), while the
#     SAME letters in normal body text stay upright (slant ~0);
#   * the italic run is still legible (it still inks a comparable column span).
#
# This is a synthesised oblique of the ONE shipped face, NOT a true italic
# typeface (documented as such). Deterministic bundled fixture, no network,
# stdlib-only PPM handling. Builds the native browser too. NO QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_emitalic.html"
PPM="$OUT/emitalic.ppm"
PNG="$OUT/emitalic.png"
mkdir -p "$OUT"
fail=0

echo "[hb-emit] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/emit_compile.log"; then
    echo "[hb-emit] FAIL: driver did not compile"; cat "$OUT/emit_compile.log"; exit 1
fi
echo "[hb-emit] PASS pixel backend compiled"

echo "[hb-emit] confirming NATIVE hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/emit_native.elf" 2>"$OUT/emit_native.log"; then
    echo "[hb-emit] FAIL: native hambrowse did not compile"; cat "$OUT/emit_native.log"; exit 1
fi
echo "[hb-emit] PASS native hambrowse still compiles"

echo "[hb-emit] rendering $FIX at width 400 ..."
if ! "$BIN" "$FIX" "$PPM" 400 >"$OUT/emit_dump.txt" 2>&1; then
    echo "[hb-emit] FAIL: render exited non-zero"; cat "$OUT/emit_dump.txt"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 && echo "[hb-emit] wrote $PNG"

# The four "llllllll" lines are the first four inked text bands, left-aligned in
# the content column (x ~ 8..140). Line 1 is upright; lines 2-4 are em/i/italic.
PROBE=$(python3 scripts/hb_emitalic_probe.py "$PPM" 6 150)
echo "$PROBE"

pass() { echo "[hb-emit] PASS $1"; }
bad()  { echo "[hb-emit] FAIL $1"; fail=1; }

# slant of the Nth detected LINE (1-based)
slant() { echo "$PROBE" | awk 'NR=='"$1"' { for(i=1;i<=NF;i++) if($i ~ /^slant=/){sub("slant=","",$i);print $i}}'; }
absge() {  # value threshold -> returns success if |value| >= threshold
    python3 -c "import sys;v=float('${1:-0}');print('Y' if abs(v)>=float('$2') else 'N')"
}

S1=$(slant 1); S2=$(slant 2); S3=$(slant 3); S4=$(slant 4)
echo "[hb-emit] slants: upright=$S1 em=$S2 i=$S3 css=$S4"

# (1) the upright control line does NOT slant.
if [ -n "$S1" ] && [ "$(absge "$S1" 1.0)" = "N" ]; then
    pass "normal text is upright (slant=$S1 ~ 0)"
else
    bad "normal text unexpectedly slanted (slant=${S1:-NA})"
fi

# (2) each italic line slants to the RIGHT at the top (slant clearly positive).
check_it() {  # name value
    if [ -n "$2" ] && [ "$(absge "$2" 1.0)" = "Y" ] \
       && python3 -c "import sys;sys.exit(0 if float('$2')>0 else 1)"; then
        pass "$1 renders faux-oblique (top sheared right, slant=$2)"
    else
        bad "$1 not slanted (slant=${2:-NA})"
    fi
}
check_it "<em>" "$S2"
check_it "<i>" "$S3"
check_it "font-style:italic" "$S4"

if [ "$fail" -ne 0 ]; then
    echo "[hb-emit] RESULT: FAIL"; exit 1
fi
echo "[hb-emit] RESULT: PASS"
