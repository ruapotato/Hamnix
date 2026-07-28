#!/usr/bin/env bash
# scripts/test_hambrowse_animfill_host.sh — FAST, QEMU-free render-to-PNG gate
# for animation-fill-mode + the WIDENED keyframe end-state overlay (round-7).
# lib/web/css/cascade.ad.
#
# THE GAP (round-6): the @keyframes overlay ALWAYS painted the settled END frame
# (equivalent to animation-fill-mode:forwards) and overlaid only background /
# colour / transform / border-colour. It ignored animation-fill-mode and never
# widened to geometry (width/height/margins).
#
# THE FEATURE: _parse_keyframes_body now captures BOTH the settled END frame
# (100%/to, else last) and the FROM frame (0%/from, else first) as pseudo-rules
# tagged r_kf_from. _cascade_match_current picks WHICH frame to overlay per the
# resolved animation-fill-mode: forwards/both (and the unspecified LEGACY default)
# paint the END frame; an explicit none/backwards paint the FROM (0%) frame. The
# overlay also widens to width/height/margins (opacity rides the packed bg alpha).
#
# Boxes (document order -> POSFILL index):
#   0 .fwd  forwards       -> #00aa00  (end frame)
#   1 .both both           -> #00aa00  (end frame)
#   2 .bwd  backwards      -> #cc0000  (FROM 0% frame)
#   3 .non  none(explicit) -> #cc0000  (FROM 0% frame)
#   4 .leg  unspecified    -> #00aa00  (legacy end frame)
#   5 .wide width 80->300  -> painted width ~300px (widened geometry overlay)
#
# Renders via the pixel backend (lib/htmlpaint + lib/htmlpage) — no QEMU boot.
# See docs/browser_w3c_conformance.md.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_animfill.html"
mkdir -p "$OUT"
fail=0

echo "[hb-af] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/af_gfx.log"; then
    echo "[hb-af] FAIL: pixel backend did not compile"; cat "$OUT/af_gfx.log"; exit 1
fi
echo "[hb-af] PASS pixel backend compiled -> $GFX"

echo "[hb-af] confirming native hambrowse still compiles ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/af_native.elf" 2>"$OUT/af_native.log"; then
    echo "[hb-af] FAIL: native hambrowse did not compile"; cat "$OUT/af_native.log"; exit 1
fi
echo "[hb-af] PASS native hambrowse still compiles"

pass() { echo "[hb-af] PASS $1"; }
bad()  { echo "[hb-af] FAIL $1"; fail=1; }

col_of() {  # sampled paint colour of POSFILL rect index $2 in dump $1
    awk -v idx="$2" '$1=="POSFILL" && $2==idx {
        for(i=1;i<=NF;i++) if($i=="pix") print $(i+1)}' "$1"
}
w_of() {    # painted width (x1-x0) of POSFILL rect index $2 in dump $1
    awk -v idx="$2" '$1=="POSFILL" && $2==idx {
        x0=-1; x1=-1;
        for(i=1;i<=NF;i++){ if($i=="x0") x0=$(i+1); if($i=="x1") x1=$(i+1) }
        print x1-x0 }' "$1"
}

D="$OUT/af.txt"
if ! "$GFX" "$FIX" "$OUT/af.ppm" 880 >"$D" 2>&1; then
    echo "[hb-af] FAIL: render exited non-zero"; cat "$D"; exit 1
fi
python3 scripts/ppm_to_png.py "$OUT/af.ppm" "$OUT/af.png" >/dev/null 2>&1 \
    && echo "[hb-af] wrote $OUT/af.png"

grep -E '^POSFILL' "$D" || true

expect() {  # expect <label> <idx> <want-color>
    got="$(col_of "$D" "$2")"
    if [ "$got" = "$3" ]; then pass "$1 (idx $2 = $got)"
    else bad "$1 (idx $2: got '${got:-none}', want $3)"; fi
}

expect "forwards -> end frame green (#00aa00)"        0 "#00aa00"
expect "both -> end frame green (#00aa00)"            1 "#00aa00"
expect "backwards -> FROM 0% red (#cc0000)"           2 "#cc0000"
expect "none(explicit) -> FROM 0% red (#cc0000)"      3 "#cc0000"
expect "unspecified -> legacy end frame green (#00aa00)" 4 "#00aa00"

# widened geometry: .wide keyframe grows 80px -> 300px; forwards settles 300px.
wgot="$(w_of "$D" 5)"
if [ -n "$wgot" ] && [ "$wgot" -ge 280 ] && [ "$wgot" -le 320 ]; then
    pass "wide keyframe width overlay (idx 5 painted width=${wgot}px ~300)"
else
    bad "wide keyframe width overlay (idx 5 painted width='${wgot:-none}', want ~300)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-af] RESULT: FAIL"; exit 1
fi
echo "[hb-af] RESULT: PASS"
