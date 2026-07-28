#!/usr/bin/env bash
# scripts/test_hambrowse_dispblockinline_host.sh — FAST, QEMU-free gate that
# pins the W3C block/inline formatting rule for an INLINE-DEFAULT element given
# an explicit block display:
#
#   `<a>` is inline by DEFAULT, but `.side a { display:block }` must lay each
#   link out as its OWN full-width block box — the links STACK vertically (each
#   on a fresh, increasing row), NOT run together on one inline line. The
#   computed `display` value OVERRIDES the tag's inline default (CSS 2.1
#   §9.2.1). Regression guard for the "docs sidebar links run together" bug: the
#   layout engine used to key block-vs-inline off the element TAG (<a> forced
#   inline) instead of its computed display.
#
#   A blockified <a> must ALSO keep its href/link id (the generic-block path
#   re-adds the link scope), and a plain inline <a> (no display override) must
#   STILL flow inline on one row (behaviour-preserving control).
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse) so a break
# in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_dispblockinline.html"
mkdir -p "$OUT"

echo "[hb-dbi] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/dbi_compile.log"; then
    echo "[hb-dbi] FAIL: host harness did not compile"; cat "$OUT/dbi_compile.log"; exit 1
fi
echo "[hb-dbi] PASS host harness compiled -> $BIN"

echo "[hb-dbi] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/dbi_native.log"; then
    echo "[hb-dbi] FAIL: native hambrowse did not compile"; cat "$OUT/dbi_native.log"; exit 1
fi
echo "[hb-dbi] PASS native hambrowse still compiles"

fail=0
D="$OUT/dispblockinline.txt"
"$BIN" "$FIX" 800 >"$D" 2>&1 || { echo "[hb-dbi] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# segments may carry a leading space inside the |..| text (inline word gap), so
# tolerate optional spaces around the matched label.
seg_row()  { grep -E "SEG [0-9]+ [0-9]+ .*\| *$1\|" "$D" | awk '{print $2}' | head -1; }
seg_x()    { grep -E "SEG [0-9]+ [0-9]+ .*\| *$1\|" "$D" | awk '{print $3}' | head -1; }
seg_link() { grep -E "SEG [0-9]+ [0-9]+ .*\| *$1\|" "$D" | grep -oE 'l-?[0-9]+' | head -1; }

# ---- (1) display:block <a> links STACK vertically ---------------------------
ir=$(seg_row "Introduction")
nr=$(seg_row "Namespaces")
pr=$(seg_row "Packaging")
echo "[hb-dbi] block links rows: Introduction=$ir Namespaces=$nr Packaging=$pr"
if [ -n "$ir" ] && [ -n "$nr" ] && [ -n "$pr" ] && \
   [ "$nr" -gt "$ir" ] && [ "$pr" -gt "$nr" ]; then
    echo "[hb-dbi] PASS display:block anchors stack on their own rows (not inline)"
else
    echo "[hb-dbi] FAIL display:block anchors did not stack (rows I=$ir N=$nr P=$pr)"; fail=1
fi

# ---- (2) a blockified <a> keeps its href/link id ----------------------------
il=$(seg_link "Introduction")
if [ -n "$il" ] && [ "$il" != "l-1" ]; then
    echo "[hb-dbi] PASS blockified <a> keeps its link id ($il)"
else
    echo "[hb-dbi] FAIL blockified <a> lost its link (got '$il')"; fail=1
fi

# ---- (3) CONTROL: plain inline <a> still flows inline on one row -------------
fr=$(seg_row "First"); fx=$(seg_x "First")
sr=$(seg_row "Second"); sx=$(seg_x "Second")
echo "[hb-dbi] inline control: First(row=$fr x=$fx) Second(row=$sr x=$sx)"
if [ -n "$fr" ] && [ -n "$sr" ] && [ "$fr" = "$sr" ] && \
   [ -n "$sx" ] && [ -n "$fx" ] && [ "$sx" -gt "$fx" ]; then
    echo "[hb-dbi] PASS plain inline <a> still flows inline on one row (no over-blockify)"
else
    echo "[hb-dbi] FAIL inline control regressed (First r=$fr x=$fx Second r=$sr x=$sx)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-dbi] RESULT: FAIL"; exit 1
fi
echo "[hb-dbi] RESULT: PASS"
