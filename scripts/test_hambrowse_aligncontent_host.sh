#!/usr/bin/env bash
# scripts/test_hambrowse_aligncontent_host.sh — FAST, QEMU-free gate for the
# CSS Flexbox `align-content` rung in the native browser engine (lib/web/):
#
#   When a `flex-wrap:wrap` flex container WRAPS onto multiple lines AND has an
#   explicit cross-size (height) taller than its packed lines, `align-content`
#   distributes the extra cross-axis space among the flex LINES:
#     flex-start (default) pack at the top; center centres the block; flex-end
#     packs at the bottom; space-between pins the first line to the top and the
#     last line to the bottom. Single-line containers ignore it (per spec).
#
# The fixture renders four IDENTICAL 2-line wrap containers (height:200px) that
# differ only in align-content; we assert the line cross-offsets match the spec
# distribution. Builds BOTH targets so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_aligncontent.html"
mkdir -p "$OUT"

echo "[hb-aligncontent] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-aligncontent] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-aligncontent] PASS host harness compiled -> $BIN"

echo "[hb-aligncontent] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-aligncontent] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-aligncontent] PASS native hambrowse still compiles"

fail=0
D="$OUT/aligncontent.txt"
"$BIN" "$FIX" 420 >"$D" 2>&1 || { echo "[hb-aligncontent] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# First-match row (line 0) and last-match row (line 1) of a container's cards.
# Cards on the same line share a row; the two lines have distinct rows.
line0() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1" "$D" | awk '{print $2}' | sort -n | head -1; }
line1() { grep -E "SEG [0-9]+ [0-9]+ .*\|$1" "$D" | awk '{print $2}' | sort -n | tail -1; }
hrow()  { grep -E "SEG [0-9]+ [0-9]+ .*\|$1\|" "$D" | awk '{print $2}' | head -1; }

h_fs=$(hrow FS); h_ce=$(hrow CE); h_fe=$(hrow FE); h_sb=$(hrow SB)

fs0=$(line0 fsone); fs1=$(line1 fsfour)
ce0=$(line0 ceone); ce1=$(line1 cefour)
fe0=$(line0 feone); fe1=$(line1 fefour)
sb0=$(line0 sbone); sb1=$(line1 sbfour)

echo "[hb-aligncontent] headings: FS=$h_fs CE=$h_ce FE=$h_fe SB=$h_sb"
echo "[hb-aligncontent] flex-start:    line0=$fs0 line1=$fs1"
echo "[hb-aligncontent] center:        line0=$ce0 line1=$ce1"
echo "[hb-aligncontent] flex-end:      line0=$fe0 line1=$fe1"
echo "[hb-aligncontent] space-between: line0=$sb0 line1=$sb1"

for v in h_fs h_ce h_fe h_sb fs0 fs1 ce0 ce1 fe0 fe1 sb0 sb1; do
    if [ -z "${!v}" ]; then echo "[hb-aligncontent] FAIL: missing measurement $v"; exit 1; fi
done

# Leading offset = first line's row measured from its own heading (so each
# container is compared on an equal footing regardless of absolute page y).
lead_fs=$((fs0 - h_fs)); lead_ce=$((ce0 - h_ce))
lead_fe=$((fe0 - h_fe)); lead_sb=$((sb0 - h_sb))
# Internal line spacing (line1 - line0). Packing keywords preserve it; space-*
# keywords grow it.
gap_fs=$((fs1 - fs0)); gap_ce=$((ce1 - ce0))
gap_fe=$((fe1 - fe0)); gap_sb=$((sb1 - sb0))
echo "[hb-aligncontent] leads: fs=$lead_fs ce=$lead_ce fe=$lead_fe sb=$lead_sb"
echo "[hb-aligncontent] gaps:  fs=$gap_fs ce=$gap_ce fe=$gap_fe sb=$gap_sb"

# space-between places ALL the free cross-space BETWEEN the two lines: its first
# line stays at the flex-start lead, so the extra internal spacing == total free.
free=$((gap_sb - gap_fs))
echo "[hb-aligncontent] derived cross free-space = $free rows"
if [ "$free" -le 0 ]; then
    echo "[hb-aligncontent] FAIL: no cross free-space distributed (container height ignored?)"; fail=1
fi

# (1) space-between: first line pinned to the top (same lead as flex-start),
#     last line pushed to the bottom (internal gap grew by the full free space).
if [ "$lead_sb" -eq "$lead_fs" ] && [ "$gap_sb" -gt "$gap_fs" ]; then
    echo "[hb-aligncontent] PASS space-between pins first line to top, last to bottom"
else
    echo "[hb-aligncontent] FAIL space-between (lead $lead_sb vs $lead_fs, gap $gap_sb vs $gap_fs)"; fail=1
fi

# (2) flex-end: BOTH lines shift down by the full free space, internal spacing
#     unchanged (lines stay packed, just moved to the container bottom).
if [ "$((lead_fe - lead_fs))" -eq "$free" ] && [ "$gap_fe" -eq "$gap_fs" ]; then
    echo "[hb-aligncontent] PASS flex-end packs both lines at the container bottom"
else
    echo "[hb-aligncontent] FAIL flex-end (offset $((lead_fe-lead_fs)) want $free, gap $gap_fe vs $gap_fs)"; fail=1
fi

# (3) center: the packed block shifts down by HALF the free space (integer
#     division, matching the engine), internal spacing unchanged.
if [ "$((lead_ce - lead_fs))" -eq "$((free / 2))" ] && [ "$gap_ce" -eq "$gap_fs" ]; then
    echo "[hb-aligncontent] PASS center offsets the line block by free/2"
else
    echo "[hb-aligncontent] FAIL center (offset $((lead_ce-lead_fs)) want $((free/2)), gap $gap_ce vs $gap_fs)"; fail=1
fi

# (4) ordering sanity: flex-start highest, center in the middle, flex-end lowest.
if [ "$lead_fs" -lt "$lead_ce" ] && [ "$lead_ce" -lt "$lead_fe" ]; then
    echo "[hb-aligncontent] PASS lead ordering flex-start < center < flex-end"
else
    echo "[hb-aligncontent] FAIL lead ordering ($lead_fs $lead_ce $lead_fe)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-aligncontent] RESULT: FAIL"; exit 1
fi
echo "[hb-aligncontent] RESULT: PASS"
