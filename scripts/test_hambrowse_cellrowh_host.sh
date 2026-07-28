#!/usr/bin/env bash
# scripts/test_hambrowse_cellrowh_host.sh — FAST, QEMU-free gate for the
# SINGLE-LINE-CELL ROW-HEIGHT bug (Chrome-parity round 5).
#
# A <table> is a block box with NO default margin (Chrome), so a single-line
# table cell must occupy exactly ONE text-line row — the same vertical space a
# bare single-line block occupies — with no stranded blank paragraph-gap row
# below the grid. The engine used to close every top-level table with a
# _para_break(), which emitted a spurious ~19px (one LINE_H row) gap after the
# grid: an isolated single-line-cell table rendered ~1 row too tall (a 3-row HN
# no-upvote baseline read 119px vs Chrome's ~81px). The fix ends the table with
# a plain line break (_soft_newline) instead — any separation from following
# content now comes solely from that content's own top margin, exactly as a
# margin-0 table behaves in Chrome.
#
# The gate renders TWO fixtures — a single-line-cell <table> and the SAME text
# in a bare <div> — and asserts they produce the SAME page height: the table
# must not strand an extra row. It also builds native hambrowse so a break there
# is caught.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
GFX="$OUT/hambrowse_gfx"
FTBL="tests/fixtures/hambrowse_cellrowh_table.html"
FBLK="tests/fixtures/hambrowse_cellrowh_block.html"
mkdir -p "$OUT"

echo "[hb-cellrowh] compiling pixel backend for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/cellrowh_gfx.log"; then
    echo "[hb-cellrowh] FAIL: pixel backend did not compile"; cat "$OUT/cellrowh_gfx.log"; exit 1
fi
echo "[hb-cellrowh] PASS pixel backend compiled"

echo "[hb-cellrowh] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/cellrowh_native.log"; then
    echo "[hb-cellrowh] FAIL: native hambrowse did not compile"; cat "$OUT/cellrowh_native.log"; exit 1
fi
echo "[hb-cellrowh] PASS native hambrowse still compiles"

if ! "$GFX" "$FTBL" "$OUT/cellrowh_tbl.ppm" 600 >"$OUT/cellrowh_tbl.txt" 2>&1; then
    echo "[hb-cellrowh] FAIL: table render exited non-zero"; cat "$OUT/cellrowh_tbl.txt"; exit 1
fi
if ! "$GFX" "$FBLK" "$OUT/cellrowh_blk.ppm" 600 >"$OUT/cellrowh_blk.txt" 2>&1; then
    echo "[hb-cellrowh] FAIL: block render exited non-zero"; cat "$OUT/cellrowh_blk.txt"; exit 1
fi

# Sanity: the table fixture laid out its single-line cell run.
if ! grep -q 'SEGTXT ROWMARK single line cell' "$OUT/cellrowh_tbl.txt"; then
    echo "[hb-cellrowh] FAIL: table fixture did not lay out its cell run"; exit 1
fi

python3 - "$OUT/cellrowh_tbl.ppm" "$OUT/cellrowh_blk.ppm" <<'PY'
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
tw, th = dims(sys.argv[1])
bw, bh = dims(sys.argv[2])
print(f"[hb-cellrowh] single-line-cell table height = {th}px  bare single-line block = {bh}px")
# A single-line cell must be ONE text-line row tall — the same as a bare block —
# never a row taller (the old table close stranded a whole ~19px LINE_H gap row).
# Allow 2px slop for AA/rounding only.
if th > bh + 2:
    print(f"[hb-cellrowh] FAIL: single-line table cell stranded {th - bh}px "
          f"(spurious table trailing-row regression)")
    sys.exit(1)
print("[hb-cellrowh] PASS single-line table cell is one text-line row tall")
PY
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[hb-cellrowh] RESULT: FAIL"; exit 1
fi
echo "[hb-cellrowh] RESULT: PASS"
