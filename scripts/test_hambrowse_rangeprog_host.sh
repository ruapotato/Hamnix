#!/usr/bin/env bash
# scripts/test_hambrowse_rangeprog_host.sh — FAST, QEMU-free render-to-PNG gate
# for CSS `accent-color` on <input type=range> and <progress> (round-11 form-
# control polish). lib/web/dom/forms.ad + lib/web/layout/box.ad + lib/htmlpage.ad.
#
# THE GAP (round-10): a range rendered as a static '[--O--]' glyph run with NO
# accent tint and NO value fraction; <progress> was an unknown tag whose fallback
# text ("70%") leaked into the flow — no bar at all.
#
# THE FEATURE: a range now resolves its cascaded accent-color (shared with
# checkbox/radio) + value/min/max -> a fill percentage, committed as a seg_field
# kind-5 segment; <progress value max> resolves accent + value/max and commits a
# seg_field kind-6 segment (its fallback body is skipped). The pixel painter draws
# a rounded light track with the value fraction filled in the accent colour (a
# range also gets a round thumb), UA blue rgb(26,115,232) when accent is unset.
#
# Controls (top -> bottom band):
#   0 .redrng   range  value=100 -> RED  #dd2222 full-width fill (~90px)
#   1 .greenpr  prog   value=50  -> GREEN #22aa33 half fill (~45px)
#   2 (default) range  value=50  -> BLUE #1a73e8 half fill (~45px)
#   3 inline    prog   value=80  -> ORANGE #ee8800 ~72px fill
#
# Renders via the pixel backend (lib/htmlpaint + lib/htmlpage) — no QEMU boot.
# See docs/browser_w3c_conformance.md.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_rangeprog.html"
mkdir -p "$OUT"
fail=0

echo "[hb-rp] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/rp_gfx.log"; then
    echo "[hb-rp] FAIL: pixel backend did not compile"; cat "$OUT/rp_gfx.log"; exit 1
fi
echo "[hb-rp] PASS pixel backend compiled -> $GFX"

echo "[hb-rp] confirming native hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/rp_native.elf" 2>"$OUT/rp_native.log"; then
    echo "[hb-rp] FAIL: native hambrowse did not compile"; cat "$OUT/rp_native.log"; exit 1
fi
echo "[hb-rp] PASS native hambrowse still compiles"

pass() { echo "[hb-rp] PASS $1"; }
bad()  { echo "[hb-rp] FAIL $1"; fail=1; }

D="$OUT/rp.txt"
if ! "$GFX" "$FIX" "$OUT/rp.ppm" 880 >/dev/null 2>"$D"; then
    echo "[hb-rp] FAIL: render exited non-zero"; cat "$D"; exit 1
fi
python3 scripts/ppm_to_png.py "$OUT/rp.ppm" "$OUT/rp.png" >/dev/null 2>&1 \
    && echo "[hb-rp] wrote $OUT/rp.png"

PROBE="$OUT/rp_probe.txt"
python3 scripts/hb_rangeprog_probe.py "$OUT/rp.ppm" >"$PROBE" 2>&1
echo "--- probe ---"; cat "$PROBE"; echo "-------------"

field() {  # field <band-idx> <key>
    awk -v idx="$1" -v k="$2" '$1=="BAR"{
        for(i=1;i<=NF;i++){ split($i,a,"="); if(a[1]=="i") ci=a[2] }
        if(ci==idx){ for(i=1;i<=NF;i++){ split($i,a,"="); if(a[1]==k) print a[2] } }
    }' "$PROBE"
}

chkfill() {  # chkfill <label> <idx> <fill>
    gf="$(field "$2" fill)"
    if [ "$gf" = "$3" ]; then
        pass "$1 (band $2 fill=$gf)"
    else
        bad "$1 (band $2: got fill='$gf', want '$3')"
    fi
}

# accent-color took effect on each band (the core assertion).
chkfill "stylesheet accent-color red range"     0 "#dd2222"
chkfill "stylesheet accent-color green progress" 1 "#22aa33"
chkfill "default UA-blue range"                  2 "#1a73e8"
chkfill "inline accent-color orange progress"    3 "#ee8800"

# value fraction: the full range (100%) fills wider than the half range (50%).
w0="$(field 0 runw)"; w2="$(field 2 runw)"
if [ -n "$w0" ] && [ -n "$w2" ] && [ "$w0" -gt "$w2" ]; then
    pass "value fraction (full range runw=$w0 > half range runw=$w2)"
else
    bad "value fraction (full range runw='$w0' not > half range runw='$w2')"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-rp] RESULT: FAIL"; exit 1
fi
echo "[hb-rp] RESULT: PASS"
