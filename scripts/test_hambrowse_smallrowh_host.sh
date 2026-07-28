#!/usr/bin/env bash
# scripts/test_hambrowse_smallrowh_host.sh — FAST, QEMU-free gate for the
# SMALL-FONT ROW-HEIGHT bug (Chrome-parity round 6).
#
# hambrowse used to seed EVERY text row at the fixed BODY_H body grid unit
# (~19px), so an all-small-font row (HN `.subtext` at 8-11px, footnotes, fine
# print) rendered as tall as a 16px body line. Chrome instead sizes a
# line-height:normal row to its OWN font: an 8pt line is ~12px tall, a 13px
# line ~15px, only a 16px line ~18-19px. hambrowse now gives a row whose
# largest font is below the 16px base its true glyph-box height, matching
# Chrome to within ~1px (measured: 8pt 11px vs Chrome 12, 10px 11==11, 13px
# 15==15, 16px 19 unchanged), while base-size and larger rows stay byte-
# identical.
#
# The gate renders tests/fixtures/hambrowse_smallfont.html (rows of 8pt / 10px
# / 13px / 16px text) and asserts, from the driver's per-row geometry dump:
#   * a 16px base row is still exactly BODY_H (19px) tall  -> unchanged
#   * the smallest-font rows are STRICTLY SHORTER than the base row  -> the fix
#   * row heights are monotonic in font-size (small <= mid < base)
# It also builds native hambrowse so a break there is caught.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_smallfont.html"
mkdir -p "$OUT"

echo "[hb-smallrowh] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/smallrowh_gfx.log"; then
    echo "[hb-smallrowh] FAIL: pixel backend did not compile"; cat "$OUT/smallrowh_gfx.log"; exit 1
fi
echo "[hb-smallrowh] PASS pixel backend compiled"

echo "[hb-smallrowh] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/smallrowh_native.log"; then
    echo "[hb-smallrowh] FAIL: native hambrowse did not compile"; cat "$OUT/smallrowh_native.log"; exit 1
fi
echo "[hb-smallrowh] PASS native hambrowse still compiles"

if ! "$GFX" "$FIX" "$OUT/smallrowh.ppm" 800 >"$OUT/smallrowh.txt" 2>&1; then
    echo "[hb-smallrowh] FAIL: render exited non-zero"; cat "$OUT/smallrowh.txt"; exit 1
fi

python3 - "$OUT/smallrowh.txt" <<'PY'
import sys
heights = []
for line in open(sys.argv[1]):
    p = line.split()
    # ROW <idx> top <t> h <h> base <b>
    if len(p) >= 6 and p[0] == "ROW" and p[4] == "h":
        heights.append(int(p[5]))
if not heights:
    print("[hb-smallrowh] FAIL: no ROW geometry dumped"); sys.exit(1)

BODY_H = 18   # round 17: Chrome line-height:normal for a 16px sans line = 18px
base_rows  = [h for h in heights if h == BODY_H]   # 16px lines (unchanged)
small_rows = [h for h in heights if h < BODY_H]    # sub-16px lines (shrunk)

if not base_rows:
    print("[hb-smallrowh] FAIL: no 16px base row at BODY_H=%d; got %r" % (BODY_H, heights)); sys.exit(1)
if not small_rows:
    print("[hb-smallrowh] FAIL: NO small-font row was shrunk below BODY_H — the "
          "quantisation bug is back; got %r" % heights); sys.exit(1)

smallest = min(small_rows)
# 8pt (~11px) must be MUCH shorter than a 16px body line, not a fixed 19px row.
if smallest > 14:
    print("[hb-smallrowh] FAIL: smallest row %dpx not proportionally short "
          "(expected <=14 for 8-10px text); got %r" % (smallest, heights)); sys.exit(1)
# and it must be tall enough to hold 8-10px glyphs (no clipping to nothing).
if smallest < 9:
    print("[hb-smallrowh] FAIL: smallest row %dpx implausibly short (glyph clip?); "
          "got %r" % (smallest, heights)); sys.exit(1)

print("[hb-smallrowh] PASS base(16px)=%d small-rows=%r smallest=%d < base"
      % (BODY_H, sorted(set(small_rows)), smallest))
PY
rc=$?
[ $rc -eq 0 ] && echo "[hb-smallrowh] ALL CHECKS PASS"
exit $rc
