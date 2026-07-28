#!/usr/bin/env bash
# scripts/test_hambrowse_headmargin_host.sh — FAST, QEMU-free gate pinning the
# HEADING author-margin fix in the layout engine (lib/web/dom/forms.ad).
#
# CSS rule: an author `margin-top` on a heading is the SAME property as the UA
# default heading margin, so the author value REPLACES the UA default (it does
# NOT stack on top of it), then that single resolved margin collapses with the
# preceding block's bottom margin. Before the fix the heading path emitted a flat
# 1-row UA gap and DROPPED the author margin entirely, so a `<h2 margin-top:64px>`
# rendered with the same tiny gap as an unstyled heading.
#
# The fixture zeroes all <p> margins, so the only vertical gap above each heading
# is that heading's own resolved top margin. On the fixed 16px line grid:
#   * margin-top:64px  -> 4 blank rows  (64/16)   [author margin honoured]
#   * margin-top:32px  -> 2 blank rows  (32/16)   [proportional, not flat]
#   * no author margin -> 1 blank row              [UA default preserved]
# We assert each heading's row MINUS the preceding paragraph's row.
#
# Built with the frozen Python seed compiler (compiles 100% of the tree; no
# self-host bootstrap needed) so this gate is dependency-light.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_heading_margin.html"
DUMP="$OUT/headmargin_dump.txt"
mkdir -p "$OUT"

echo "[hb-hm] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/headmargin_compile.log"; then
    echo "[hb-hm] FAIL: host harness did not compile"; cat "$OUT/headmargin_compile.log"; exit 1
fi
echo "[hb-hm] PASS host harness compiled"

echo "[hb-hm] running host harness on $FIX ..."
if ! "$BIN" "$FIX" 800 >"$DUMP" 2>&1; then
    echo "[hb-hm] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

fail=0

# Row (2nd field of the SEG line) of the FIRST segment whose text contains $1.
row_of() {
    grep -E "SEG " "$DUMP" | grep -m1 -- "$1" | awk '{print $2}'
}

assert_gap() {
    local top="$1" bot="$2" want="$3" label="$4"
    local rt rb gap
    rt="$(row_of "$top")"; rb="$(row_of "$bot")"
    if [ -z "$rt" ] || [ -z "$rb" ]; then
        echo "[hb-hm] FAIL $label — missing segment(s) ('$top'=$rt '$bot'=$rb)"; fail=1; return
    fi
    # the preceding paragraph is a single line (1 row); blank rows above the
    # heading = row-delta minus that paragraph row.
    gap=$((rb - rt - 1))
    if [ "$gap" -eq "$want" ]; then
        echo "[hb-hm] PASS $label — gap ${gap} rows (row ${rt} -> ${rb})"
    else
        echo "[hb-hm] FAIL $label — gap ${gap} rows, want ${want} (row ${rt} -> ${rb})"; fail=1
    fi
}

# author margin-top:64px REPLACES the UA default -> 4 blank rows (was 1 pre-fix).
assert_gap "Alpha paragraph" "Big Margin Heading"    4 "margin-top:64px honoured"
# author margin-top:32px -> 2 blank rows (proportional, proves it isn't flat).
assert_gap "Beta paragraph"  "Medium Margin Heading" 2 "margin-top:32px proportional"
# no author margin -> the UA default single line is preserved.
assert_gap "Gamma paragraph" "Plain Heading"         1 "unstyled heading keeps UA default"

if [ "$fail" -ne 0 ]; then
    echo "[hb-hm] RESULT: FAIL"; exit 1
fi
echo "[hb-hm] RESULT: PASS"
