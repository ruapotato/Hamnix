#!/usr/bin/env bash
# scripts/test_hambrowse_flexwrap_qa_host.sh — FAST, QEMU-free render-to-PNG gate
# for three REAL flex/whitespace layout defects discovered by on-device QA of a
# realistic page in hambrowse (lib/web/layout/box.ad + lib/web/dom/forms.ad).
# Each defect gets a PIXEL-asserted case on a rendered PNG (not just SEG text):
#
#   (1) CARD WRAP  — inline text inside a `flex:1` card wraps to the CARD's own
#       content-box width (multi-row, contained) instead of laying one line that
#       bleeds across and past the card's right border into the inter-card gutter.
#       Root: the flex nowrap guard was armed for EVERY natural-path item; it is
#       now armed only for CONTENT-SIZED pills, so a shrunk `flex:1` card wraps.
#   (2) NAV GAP    — a `display:flex; gap:20px` nav with NO justify-content packs
#       its links at flex-start WITH the 20px gutter (was: gap ignored + items
#       spread edge-to-edge across the row). Root: default justify now takes the
#       natural flex-start packing path when a gap (or justify) is set.
#   (3) BLOCK GAP  — two margin-less <div>s separated only by a whitespace text
#       node stack directly adjacent, no phantom blank row. Root: structural
#       block closes no longer emit a fake paragraph gap (only <p>/<figure> do);
#       whitespace-only inline content between blocks generates no box.
#
# scripts/hb_flexwrap_qa_probe.py renders the shared dump to a real PNG and reads
# the pixels. Builds BOTH targets (host harness + native hambrowse) so a break in
# either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_flexwrapqa.html"
PNG="$OUT/flexwrapqa.png"
mkdir -p "$OUT"

echo "[hb-fwqa] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/fwqa_compile.log"; then
    echo "[hb-fwqa] FAIL: host harness did not compile"; cat "$OUT/fwqa_compile.log"; exit 1
fi
echo "[hb-fwqa] PASS host harness compiled -> $BIN"

echo "[hb-fwqa] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/fwqa_native.log"; then
    echo "[hb-fwqa] FAIL: native hambrowse did not compile"; cat "$OUT/fwqa_native.log"; exit 1
fi
echo "[hb-fwqa] PASS native hambrowse still compiles"

P="$OUT/flexwrapqa.probe.txt"
if ! python3 scripts/hb_flexwrap_qa_probe.py "$BIN" "$FIX" 600 "$PNG" >"$P" 2>&1; then
    echo "[hb-fwqa] FAIL: probe did not run"; cat "$P"; exit 1
fi
cat "$P"

fail=0

# ---- (1) card body text wraps INSIDE the card, no bleed past its right border --
INK_ROWS=$(awk -F'[= ]' '/^CARD1/{print $3}' "$P")
BLEED=$(awk -F'[= ]' '/^CARD1/{print $5}' "$P")
if [ "${INK_ROWS:-0}" -ge 3 ] && [ "${BLEED:-1}" -eq 0 ]; then
    echo "[hb-fwqa] PASS card text WRAPS inside the card (ink_rows=$INK_ROWS) with no bleed past the border"
else
    echo "[hb-fwqa] FAIL card text not contained (ink_rows=$INK_ROWS bleed_px=$BLEED)"; fail=1
fi

# ---- (2) nav packs 4 items at flex-start with a ~20px gap (not spread) ---------
NAV_N=$(awk -F'[= ]' '/^NAV/{print $3}' "$P")
NAV_GAPS=$(awk -F'gaps=' '/^NAV/{print $2}' "$P")
if [ "${NAV_N:-0}" -eq 4 ]; then
    echo "[hb-fwqa] PASS nav packed into 4 discrete items"
else
    echo "[hb-fwqa] FAIL nav item count = $NAV_N (expected 4)"; fail=1
fi
gap_ok=1
IFS=',' read -ra GA <<< "${NAV_GAPS:-}"
if [ "${#GA[@]}" -lt 3 ]; then gap_ok=0; fi
for g in "${GA[@]}"; do
    # a 20px gap renders as a small gutter (~14..40 px); a gap-ignored SPREAD nav
    # would show ~100+ px gutters between items.
    if [ -z "$g" ] || [ "$g" -lt 14 ] || [ "$g" -gt 40 ]; then gap_ok=0; fi
done
if [ "$gap_ok" -eq 1 ]; then
    echo "[hb-fwqa] PASS nav items packed with the ~20px gap (gaps=$NAV_GAPS), not spread"
else
    echo "[hb-fwqa] FAIL nav gap not applied / items spread (gaps=$NAV_GAPS)"; fail=1
fi

# ---- (3) two margin-less divs across a whitespace node stack ADJACENT ----------
BLK_GAP=$(awk -F'gap=' '/^BLOCKS/{print $2}' "$P")
if [ -n "${BLK_GAP:-}" ] && [ "$BLK_GAP" -ge 0 ] && [ "$BLK_GAP" -le 4 ]; then
    echo "[hb-fwqa] PASS whitespace-separated divs are adjacent (blue top follows red bottom, gap=$BLK_GAP px)"
else
    echo "[hb-fwqa] FAIL phantom blank row between blocks (gap=$BLK_GAP px)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-fwqa] RESULT: FAIL"; exit 1
fi
echo "[hb-fwqa] RESULT: PASS"
