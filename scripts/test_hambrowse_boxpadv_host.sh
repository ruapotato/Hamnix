#!/usr/bin/env bash
# scripts/test_hambrowse_boxpadv_host.sh — FAST, QEMU-free gate for the
# BORDERLESS-BOX VERTICAL PADDING bug (Chrome-parity ROUND-11).
#
# A plain borderless box with a background and real vertical padding
# (`div{background:#…;padding:16px}`) must render its background over the
# PADDING box — a single 16px text line inset 16px top + 16px bottom is ~50px
# tall in Chrome. hambrowse used to quantise the folded padding into whole
# ~19px LINE_H blank rows in the flow (inflating the box ~10-15%) while painting
# the background over the content row ONLY (~19px) — so the box was both too
# tall in flow AND under-painted. ROUND-11 bakes the padding at REAL px into the
# box's first/last content row (a no-stroke kind-3 padding bbox, the same
# mechanism a bordered card / table cell uses), so the background fill spans the
# padded box at Chrome's height and the flow no longer over-inflates.
#
# The fixture stacks a padded box (#aa2244, padding:16px) above an UN-padded
# control (#2244aa, padding:0). The gate reads each box's painted background
# height from the POSFILL dump and asserts the padded box is TALLER than the
# control by roughly its 32px vertical padding — but NOT double it (guarding the
# flex-item double-count exclusion). On base both boxes paint one ~19px content
# row (padding dropped from the fill) so the difference is ~0 -> FAIL.
#
# Builds BOTH targets so a break in either the host harness or native hambrowse
# is caught.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_boxpadv.html"
mkdir -p "$OUT"

echo "[hb-boxpadv] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/boxpadv_gfx.log"; then
    echo "[hb-boxpadv] FAIL: pixel backend did not compile"; cat "$OUT/boxpadv_gfx.log"; exit 1
fi
echo "[hb-boxpadv] PASS pixel backend compiled"

echo "[hb-boxpadv] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/boxpadv_native.log"; then
    echo "[hb-boxpadv] FAIL: native hambrowse did not compile"; cat "$OUT/boxpadv_native.log"; exit 1
fi
echo "[hb-boxpadv] PASS native hambrowse still compiles"

D="$OUT/boxpadv.txt"
if ! "$GFX" "$FIX" "$OUT/boxpadv.ppm" 640 >"$D" 2>&1; then
    echo "[hb-boxpadv] FAIL: render exited non-zero"; cat "$D"; exit 1
fi

python3 - "$D" <<'PY'
import sys, re
lines = open(sys.argv[1]).read().splitlines()
def box_h(col):
    for ln in lines:
        if ln.startswith("POSFILL ") and (" col #%s " % col) in ln:
            m = re.search(r" y0 (\d+) x1 \d+ y1 (\d+) ", ln)
            if m:
                return int(m.group(2)) - int(m.group(1))
    return None
pad = box_h("aa2244")   # background box WITH padding:16px
flat = box_h("2244aa")  # control, padding:0
print("[hb-boxpadv] padded-box fill height = %s  flat control = %s" % (pad, flat))
if pad is None or flat is None:
    print("[hb-boxpadv] FAIL: could not find both background fills in the POSFILL dump")
    sys.exit(1)
# The padded box must be taller than the un-padded control by ~its 32px vertical
# padding (Chrome ~50 vs ~18). Require >= 24px extra so the ~19px-quantised base
# (difference ~0) FAILs. Cap the extra at 42px so a DOUBLE-counted padding
# (a flex-item regression, ~64px) also FAILs.
extra = pad - flat
if extra < 24:
    print("[hb-boxpadv] FAIL: borderless box padding not painted at real px "
          "(padded %d vs flat %d, extra %d < 24)" % (pad, flat, extra))
    sys.exit(1)
if extra > 42:
    print("[hb-boxpadv] FAIL: borderless box padding DOUBLE-counted "
          "(padded %d vs flat %d, extra %d > 42)" % (pad, flat, extra))
    sys.exit(1)
print("[hb-boxpadv] PASS borderless box paints its ~32px vertical padding "
      "(extra %d px)" % extra)
PY
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[hb-boxpadv] RESULT: FAIL"; exit 1
fi
echo "[hb-boxpadv] RESULT: PASS"
