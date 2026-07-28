#!/usr/bin/env bash
# scripts/test_hambrowse_linebox_host.sh — FAST, QEMU-free gate for the GLOBAL
# line-box over-height (Chrome-parity round 17).
#
# hambrowse seeded every 16px body content row from the font's GLYPH BOUNDING BOX
# (ascent+descent = 19px), but Chrome lays a `line-height:normal` 16px sans line
# out at ~1.15em = 18px (MEASURED at /usr/bin/chromium: a 20-line paragraph is
# 360px = 18px/line, not 380px). hb therefore added ~1px PER LINE, compounding
# down every multi-line block (a 10-line paragraph rendered 190px vs Chrome's
# 180). The fix (lib/htmlpage.ad: BODY_H 19->18 + a line-height:normal cap pass
# 1a2 that clamps a >=16px text row whose height came from its own glyphs to
# round(px*1.15)) brings the body row pitch to Chrome's 18px WITHOUT breaking the
# row grid — blank rows and 16px content rows stay UNIFORM at 18, so the
# position:sticky / grid-auto-rows integer-row invariants survive (proven by the
# sticky/grid/gridautorows/gridrowgap/valign/cellrowh gates, all still green).
#
# The fixture hambrowse_linebox.html is a plain 10-line 16px <p> (no CSS
# line-height). This gate renders it and, from the deterministic per-row pixel
# `top` dump, proves:
#   * the body block's row pitch is 18px (Chrome line-height:normal), NOT the old
#     19px glyph-box pitch — the base binary drew 19 and FAILS here;
#   * the 10-line block therefore spans 180px, not the base's 190 (10px shorter,
#     matching Chrome);
#   * every content row height is 18 (uniform grid preserved).
# Also builds native hambrowse so a break there is caught. PNG-free.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_linebox.html"
mkdir -p "$OUT"

echo "[hb-linebox] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/linebox_gfx.log"; then
    echo "[hb-linebox] FAIL: pixel backend did not compile"; cat "$OUT/linebox_gfx.log"; exit 1
fi
echo "[hb-linebox] PASS pixel backend compiled"

echo "[hb-linebox] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/linebox_native.log"; then
    echo "[hb-linebox] FAIL: native hambrowse did not compile"; cat "$OUT/linebox_native.log"; exit 1
fi
echo "[hb-linebox] PASS native hambrowse still compiles"

if ! "$GFX" "$FIX" "$OUT/linebox.ppm" 640 >"$OUT/linebox.txt" 2>&1; then
    echo "[hb-linebox] FAIL: render exited non-zero"; cat "$OUT/linebox.txt"; exit 1
fi
grep -E '^ROW ' "$OUT/linebox.txt" | head -12

python3 - "$OUT/linebox.txt" <<'PY'
import sys
rows = []   # (top, h)
for line in open(sys.argv[1]):
    p = line.split()
    # ROW <idx> top <t> h <h> base <b>
    if len(p) >= 6 and p[0] == "ROW" and p[2] == "top" and p[4] == "h":
        rows.append((int(p[3]), int(p[5])))
if len(rows) < 10:
    print("[hb-linebox] FAIL: expected >=10 body rows, got %d" % len(rows)); sys.exit(1)

NORMAL = 18   # Chrome line-height:normal for a 16px sans line (measured)
OLD    = 19   # hb's former glyph-bounding-box pitch

# consecutive body-row pitches over the first 10 content rows
pitches = [rows[i+1][0] - rows[i][0] for i in range(9)]
heights = [h for (_t, h) in rows[:10]]

if any(p == OLD for p in pitches):
    print("[hb-linebox] FAIL: a body row still advances at the old %dpx glyph-box "
          "pitch (base behaviour); pitches=%r" % (OLD, pitches)); sys.exit(1)
if not all(p == NORMAL for p in pitches):
    print("[hb-linebox] FAIL: body row pitch is not the uniform Chrome %dpx "
          "line-height:normal; pitches=%r" % (NORMAL, pitches)); sys.exit(1)
if not all(h == NORMAL for h in heights):
    print("[hb-linebox] FAIL: body row heights not uniform at %dpx; got %r"
          % (NORMAL, heights)); sys.exit(1)

# 10-line block height (top of row0 -> bottom of row9)
block_h = rows[9][0] + rows[9][1] - rows[0][0]
if block_h != 10 * NORMAL:
    print("[hb-linebox] FAIL: 10-line block is %dpx, expected %d (Chrome); base "
          "renders %d" % (block_h, 10 * NORMAL, 10 * OLD)); sys.exit(1)

print("[hb-linebox] PASS 10-line body block = %dpx @ %dpx/line uniform "
      "(Chrome line-height:normal; base was %d @ %dpx/line — 10px taller)"
      % (block_h, NORMAL, 10 * OLD, OLD))
PY
rc=$?
[ $rc -eq 0 ] && echo "[hb-linebox] ALL CHECKS PASS"
exit $rc
