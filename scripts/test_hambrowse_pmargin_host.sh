#!/usr/bin/env bash
# scripts/test_hambrowse_pmargin_host.sh — FAST, QEMU-free gate for the PROSE
# PARAGRAPH margin PIXEL rhythm (Chrome-parity round 9).
#
# A <p> (and <figure>) carries a UA-default block margin of 1em = 16px at the base
# font. hambrowse used to draw the blank inter-paragraph gap row at the full BODY_H
# (~19px) body line pitch — inflating EVERY paragraph ~3px over Chrome down every
# article/blog (a p-to-p run is the single most common vertical rhythm on the web).
# Chrome (measured @ /usr/bin/chromium) renders the gap at exactly 16px: two
# single-line paragraphs sit 34px apart (18px content + 16px margin), not hb's 38.
#
# The fix (lib/web/dom/forms.ad <p>/<figure> close latches the real margin px into
# g_para_mgap; lib/web/layout/box.ad _para_break tags the freshly-emitted gap row
# via row_mgap) makes the pixel pass (lib/htmlpage.ad) draw the gap at 16px — the
# SAME row_mgap mechanism the heading margin-bottom and <li> inter-item gap use.
# Margin COLLAPSING is preserved: where a paragraph is followed by a heading whose
# taller UA top margin (~0.8-1.3em) wins the collapse, the heading open RESTORES
# that gap row to the full body height, so a </p><h2> section boundary keeps
# Chrome's ~20px break rather than being pinched to the paragraph's 16px.
#
# The fixture hambrowse_pmargin.html is 4 single-line <p>, then an <h2>, then one
# more <p>:
#   p p p p  -> three p->p gaps, EACH 16px
#   p  h2    -> the 4th p's bottom gap COLLAPSES with the heading top margin and is
#              RESTORED to the full 19px body row (heading margin wins)
#   h2 p     -> heading UA bottom gap, a full 19px row (untagged)
#   p        -> its trailing bottom gap, 16px
# So EXACTLY four gap rows are drawn at 16px (the three consecutive p->p gaps plus
# the trailing gap); the p->h2 boundary is NOT among them (proving the collapse
# restore). Assert, from the driver's per-row geometry dump:
#   * at least one gap row is drawn SHORTER than BODY_H (the fix; the old
#     quantisation drew every gap a flat 19px)
#   * EXACTLY four gap rows sit at the 1em pixel height (16px) — a broken collapse
#     restore would leave FIVE (the p->h2 boundary pinched to 16)
#   * BODY_H content rows still exist unchanged
# Also builds native hambrowse so a break there is caught. PNG-free.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_pmargin.html"
mkdir -p "$OUT"

echo "[hb-pmargin] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/pmargin_gfx.log"; then
    echo "[hb-pmargin] FAIL: pixel backend did not compile"; cat "$OUT/pmargin_gfx.log"; exit 1
fi
echo "[hb-pmargin] PASS pixel backend compiled"

echo "[hb-pmargin] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/pmargin_native.log"; then
    echo "[hb-pmargin] FAIL: native hambrowse did not compile"; cat "$OUT/pmargin_native.log"; exit 1
fi
echo "[hb-pmargin] PASS native hambrowse still compiles"

if ! "$GFX" "$FIX" "$OUT/pmargin.ppm" 800 >"$OUT/pmargin.txt" 2>&1; then
    echo "[hb-pmargin] FAIL: render exited non-zero"; cat "$OUT/pmargin.txt"; exit 1
fi

python3 - "$OUT/pmargin.txt" <<'PY'
import sys
heights = []
for line in open(sys.argv[1]):
    p = line.split()
    # ROW <idx> top <t> h <h> base <b>
    if len(p) >= 6 and p[0] == "ROW" and p[4] == "h":
        heights.append(int(p[5]))
if not heights:
    print("[hb-pmargin] FAIL: no ROW geometry dumped"); sys.exit(1)

BODY_H = 18   # round 17: 16px body content row = Chrome line-height:normal 18px
GAP_PX = 16                       # 1em of a 16px font = the UA <p> margin
body_rows = [h for h in heights if h == BODY_H]
gap_rows  = [h for h in heights if h == GAP_PX]
short     = [h for h in heights if h < BODY_H]

if not body_rows:
    print("[hb-pmargin] FAIL: no BODY_H(%d) content row; got %r" % (BODY_H, heights)); sys.exit(1)
if not short:
    print("[hb-pmargin] FAIL: NO paragraph gap row was drawn below BODY_H — the "
          "1em margin is quantised back to a full ~19px body row; got %r" % heights); sys.exit(1)
if len(gap_rows) != 4:
    print("[hb-pmargin] FAIL: expected 4 gap rows at %dpx (three p->p gaps + the "
          "trailing gap; the p->h2 boundary must be RESTORED to BODY_H), got %d (%r)"
          % (GAP_PX, len(gap_rows), heights)); sys.exit(1)

print("[hb-pmargin] PASS BODY_H=%d gap-rows=%d @ %dpx (1em p rhythm); p->h2 "
      "boundary restored to the full body row (margin collapse)"
      % (BODY_H, len(gap_rows), GAP_PX))
PY
rc=$?
[ $rc -eq 0 ] && echo "[hb-pmargin] ALL CHECKS PASS"
exit $rc
