#!/usr/bin/env bash
# scripts/test_hambrowse_limarginpx_host.sh — FAST, QEMU-free gate for the
# SUB-ROW list-item margin PIXEL height (Chrome-parity round 8).
#
# The danluu-blog index pattern `li{display:flex;margin:0 0 .9em}` (a 14px
# bottom margin on one-line link/date items). The authored .9em gap quantises
# to exactly ONE blank grid row. hambrowse used to draw that lone gap row at the
# full BODY_H (~19px) body line pitch — inflating every item ~5px over Chrome
# down a long list (measured danluu index: item pitch 38px vs Chrome 32px, a
# ~6px/row error over ~200 rows). Chrome sizes the .9em margin at its real 14px.
#
# The fix (lib/web/dom/forms.ad <li> inter-item-margin path) tags the lone
# emitted gap row with its REAL px via row_mgap — the SAME mechanism the heading
# margin-bottom already uses — so the pixel pass (lib/htmlpage.ad) draws it at
# 14px, not a full BODY_H row. Measured effect: danluu item pitch 38 -> 33px
# (Chrome 32); zero change to any committed fixture at the 640px gate width (the
# path fires only for a sub-BODY_H li margin that rounds to one row).
#
# The fixture hambrowse_limargin_px.html has TWO one-line-item lists:
#   * .spaced  li{display:flex;margin:0 0 .9em}  -> 5 items, 4 inter-item gap
#     rows, EACH drawn at 14px (the .9em margin), interleaved with 19px content.
#   * .tight   li{display:flex;margin:0}         -> control, NO gap rows (all
#     content rows at BODY_H=19).
# Assert, from the driver's per-row geometry dump:
#   * at least one gap row is drawn SHORTER than BODY_H (the fix; a regression to
#     the old quantisation would make every row a flat 19px)
#   * exactly 4 gap rows sit at the .9em pixel height (14px) — the spaced list's
#     inter-item gaps, none from the tight control
#   * BODY_H content rows still exist unchanged
# Also builds native hambrowse so a break there is caught. PNG-free.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_limargin_px.html"
mkdir -p "$OUT"

echo "[hb-limpx] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/limpx_gfx.log"; then
    echo "[hb-limpx] FAIL: pixel backend did not compile"; cat "$OUT/limpx_gfx.log"; exit 1
fi
echo "[hb-limpx] PASS pixel backend compiled"

echo "[hb-limpx] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/limpx_native.log"; then
    echo "[hb-limpx] FAIL: native hambrowse did not compile"; cat "$OUT/limpx_native.log"; exit 1
fi
echo "[hb-limpx] PASS native hambrowse still compiles"

if ! "$GFX" "$FIX" "$OUT/limpx.ppm" 800 >"$OUT/limpx.txt" 2>&1; then
    echo "[hb-limpx] FAIL: render exited non-zero"; cat "$OUT/limpx.txt"; exit 1
fi

python3 - "$OUT/limpx.txt" <<'PY'
import sys
heights = []
for line in open(sys.argv[1]):
    p = line.split()
    # ROW <idx> top <t> h <h> base <b>
    if len(p) >= 6 and p[0] == "ROW" and p[4] == "h":
        heights.append(int(p[5]))
if not heights:
    print("[hb-limpx] FAIL: no ROW geometry dumped"); sys.exit(1)

BODY_H = 18   # round 17: 16px body content row = Chrome line-height:normal 18px
GAP_PX = 14                       # .9em of a 16px font = 14.4 -> 14
body_rows = [h for h in heights if h == BODY_H]
gap_rows  = [h for h in heights if h == GAP_PX]
short     = [h for h in heights if h < BODY_H]

if not body_rows:
    print("[hb-limpx] FAIL: no BODY_H(%d) content row; got %r" % (BODY_H, heights)); sys.exit(1)
if not short:
    print("[hb-limpx] FAIL: NO li gap row was drawn below BODY_H — the sub-row "
          "margin is quantised back to a full ~19px body row; got %r" % heights); sys.exit(1)
if len(gap_rows) != 4:
    print("[hb-limpx] FAIL: expected 4 inter-item gap rows at %dpx (.9em) from the "
          "5-item spaced list, got %d (%r)" % (GAP_PX, len(gap_rows), heights)); sys.exit(1)

print("[hb-limpx] PASS BODY_H=%d gap-rows=%d @ %dpx (.9em spaced list); tight "
      "control adds no short row" % (BODY_H, len(gap_rows), GAP_PX))
PY
rc=$?
[ $rc -eq 0 ] && echo "[hb-limpx] ALL CHECKS PASS"
exit $rc
