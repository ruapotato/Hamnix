#!/usr/bin/env bash
# scripts/test_hambrowse_pcthide_host.sh — FAST, QEMU-free gate for two real-
# page (google.com) layout-fidelity fixes that live entirely in lib/web/:
#
#  (1) A BARE percentage height (`height:100%`) resolves to AUTO (content-sized)
#      for the document flow chain, whose containing block is INDEFINITE — NOT a
#      viewport-height pin that pads a screenful of blank rows above the content.
#      Google's flex-column hero shell carries `height:100%`; the pre-fix engine
#      pinned it to bh=600 and shoved the logo/search hero ~37 rows down the
#      page (a huge white band above the Google logo). `.shell` here wraps one
#      32px (2-row) box, so its background fill must be 2 rows tall (auto), not
#      37 (600/16), and the following `.marker` box must sit at row 2, not ~37.
#      (lib/web/css/cascade.ad: _val_is_bare_pct — height branch skips the pin.)
#
#  (2) A display:none SUBTREE whose descendants include MORE SAME-TAG elements is
#      skipped IN FULL. The skip counts nesting depth; without it a hidden <div>
#      containing nested <div>s ended the skip at the first inner </div>, leaking
#      the rest of the subtree onto the page (google's `display:none` tools popup
#      painting "Create images"/"Canvas" chips over the search box). None of
#      HIDEONE/HIDETWO/HIDETAIL may render. (lib/web/layout/flow.ad skip loop +
#      skip_depth; lib/web/html/tags.ad _enter_skip.)
#
# Rendered at WIDTH=1200 (bw), default HEIGHT=600 (bh). Builds BOTH the host
# harness (x86_64-linux) AND native hambrowse (x86_64-adder-user) so a break in
# either backend is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_pcthide.html"
mkdir -p "$OUT"

echo "[hb-pcthide] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-pcthide] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-pcthide] PASS host harness compiled -> $BIN"

echo "[hb-pcthide] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-pcthide] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-pcthide] PASS native hambrowse still compiles"

fail=0
D="$OUT/pcthide.txt"
"$BIN" "$FIX" 1200 >"$D" 2>&1 || { echo "[hb-pcthide] FAIL: render exited non-zero"; cat "$D"; exit 1; }
grep -E "^SEG |^FILL " "$D" || true

# --- (1) bare height:100% shell is AUTO (2 rows), not a bh pin (~37 rows) ------
# FILL lines are "FILL top bot lx rx #hex ..."; height rows = bot - top.
shell_rows=$(grep -E "FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #191919( |$)" "$D" | awk '{print $3-$2}' | head -1)
echo "[hb-pcthide] shell(height:100%) fill rows=$shell_rows (expect 2 = auto/content)"
if [ "$shell_rows" = "2" ]; then
    echo "[hb-pcthide] PASS bare height:100% resolved to auto (no viewport pin)"
else
    echo "[hb-pcthide] FAIL bare height:100% not auto (rows=$shell_rows, pre-fix bh-pin gives ~37)"; fail=1
fi

# The .marker box that FOLLOWS the shell must sit right after its content (row 2),
# proving the shell did not pad blank rows below itself.
marker_row=$(grep -E "SEG [0-9]+ .*\|marker box\|" "$D" | awk '{print $2}' | head -1)
echo "[hb-pcthide] marker box row=$marker_row (expect 2)"
if [ "$marker_row" = "2" ]; then
    echo "[hb-pcthide] PASS marker not shoved down by a spurious height pin"
else
    echo "[hb-pcthide] FAIL marker row=$marker_row (want 2)"; fail=1
fi

# --- (2) display:none subtree with nested same-tag children fully hidden -------
for tok in HIDEONE HIDETWO HIDETAIL; do
    if grep -q "|.*$tok.*|" "$D"; then
        echo "[hb-pcthide] FAIL '$tok' leaked from a display:none subtree"; fail=1
    else
        echo "[hb-pcthide] PASS '$tok' correctly hidden"
    fi
done
if grep -q "|VISIBLEROW|" "$D"; then
    echo "[hb-pcthide] PASS content AFTER the hidden subtree still renders"
else
    echo "[hb-pcthide] FAIL 'VISIBLEROW' missing — skip over-ran the hidden subtree"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-pcthide] RESULT: FAIL"; exit 1
fi
echo "[hb-pcthide] RESULT: PASS"
