#!/usr/bin/env bash
# scripts/test_hambrowse_cellempty_host.sh — FAST, QEMU-free gate for the
# EMPTY-BLOCK-IN-TABLE-CELL vertical row-inflation bug (Chrome-parity round 4).
#
# Table cells share the engine's global flow cursor (cur_row). An EMPTY / zero-
# content block child of a cell — Hacker News's `<td class=votelinks><center><a>
# <div class=votearrow style="width:10px;height:10px"></div></a></center></td>`
# upvote arrow — used to advance that shared cursor TWICE per story row: once from
# the block's leading _soft_newline (the reserved-but-empty cell row was treated
# as dirty) and once from its sub-line `height:10px` pin quantising up to a whole
# row. Every HN story therefore rendered ~2 rows too tall and the page came out
# ~1.39x Chrome's height (hb ~2000px vs Chrome ~1438px).
#
# The fix mirrors the list-item g_li_pending model with g_cell_pending: a freshly
# opened cell's reserved row is FRESH (a block child's leading _soft_newline does
# not bump), and an empty block in a cell with a sub-LINE_H height collapses to
# zero rows instead of inflating the shared row. Chrome sizes a table row to the
# tallest cell's CONTENT, so a zero-content box never adds height.
#
# The gate renders TWO fixtures — one whose votelinks cell holds an empty
# height:10px div nested in <center><a> (the exact HN shape), and one whose
# votelinks cell holds only &nbsp; — and asserts they produce the SAME page
# height: the empty block must add NO vertical space. It also builds native
# hambrowse so a break there is caught.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FDIV="tests/fixtures/hambrowse_cellempty_div.html"
FPLN="tests/fixtures/hambrowse_cellempty_plain.html"
mkdir -p "$OUT"

echo "[hb-cellempty] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/cellempty_gfx.log"; then
    echo "[hb-cellempty] FAIL: pixel backend did not compile"; cat "$OUT/cellempty_gfx.log"; exit 1
fi
echo "[hb-cellempty] PASS pixel backend compiled"

echo "[hb-cellempty] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/cellempty_native.log"; then
    echo "[hb-cellempty] FAIL: native hambrowse did not compile"; cat "$OUT/cellempty_native.log"; exit 1
fi
echo "[hb-cellempty] PASS native hambrowse still compiles"

if ! "$GFX" "$FDIV" "$OUT/cellempty_div.ppm" 600 >"$OUT/cellempty_div.txt" 2>&1; then
    echo "[hb-cellempty] FAIL: div render exited non-zero"; cat "$OUT/cellempty_div.txt"; exit 1
fi
if ! "$GFX" "$FPLN" "$OUT/cellempty_plain.ppm" 600 >"$OUT/cellempty_plain.txt" 2>&1; then
    echo "[hb-cellempty] FAIL: plain render exited non-zero"; cat "$OUT/cellempty_plain.txt"; exit 1
fi

# Both must have laid out the same title runs (sanity that the tables rendered).
if ! grep -q 'SEGTXT Story ONEMARK one title here' "$OUT/cellempty_div.txt"; then
    echo "[hb-cellempty] FAIL: div fixture did not lay out its title run"; exit 1
fi

python3 - "$OUT/cellempty_div.ppm" "$OUT/cellempty_plain.ppm" <<'PY'
import sys
def dims(path):
    d = open(path, 'rb').read()
    assert d[:2] == b'P6', "not a P6 ppm: " + path
    vals = []; idx = 2
    while len(vals) < 3:
        while idx < len(d) and d[idx] in b' \t\n\r':
            idx += 1
        if d[idx:idx+1] == b'#':
            while idx < len(d) and d[idx] not in b'\n':
                idx += 1
            continue
        s = idx
        while idx < len(d) and d[idx] not in b' \t\n\r':
            idx += 1
        vals.append(int(d[s:idx]))
    return vals[0], vals[1]
dw, dh = dims(sys.argv[1])
pw, ph = dims(sys.argv[2])
print(f"[hb-cellempty] empty-div-in-cell height = {dh}px  plain-cell height = {ph}px")
# The empty height:10px div nested in the votelinks cell must add NO vertical
# space vs a plain &nbsp; cell. Allow a 2px slop for AA/rounding only.
if dh > ph + 2:
    print(f"[hb-cellempty] FAIL: empty block inflated the table by {dh - ph}px "
          f"(cell-row-flow regression)")
    sys.exit(1)
print("[hb-cellempty] PASS empty block in a table cell adds no row height")
PY
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[hb-cellempty] RESULT: FAIL"; exit 1
fi
echo "[hb-cellempty] RESULT: PASS"
