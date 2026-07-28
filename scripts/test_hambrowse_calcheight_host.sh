#!/usr/bin/env bash
# scripts/test_hambrowse_calcheight_host.sh — FAST, QEMU-free gate for a `%`
# term inside a HEIGHT value (incl. calc()) resolving against the VIEWPORT
# HEIGHT (bh) rather than the content-column WIDTH. This is the google-hero
# vertical-fidelity fix (lib/web/css/cascade.ad: _len_apply_unit honours the
# _len_vaxis flag set by _box_decl around height/min-height/max-height/top/
# bottom). Google sizes its hero spacers with `height:calc(100% - Npx)`; before
# this fix the `100%` resolved against the page WIDTH, over-sizing the spacers
# and shoving the logo + search box far down the page.
#
# Rendered at WIDTH=1200 (bw), HEIGHT=600 (bh). The host harness emits FILL
# spans in LINE_H rows (16px/row); height rows = bot - top:
#   calc(100% - 200px) -> 600-200 = 400px -> 25 rows   (.hc  #191919)
#   calc(100% - 450px) -> 600-450 = 150px ->  9 rows   (.hc2 #2a2a2a)
# The WIDTH base (~1184) would give 984px (61 rows) for .hc, so this gate proves
# the vertical axis is used.
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either backend is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_calcheight.html"
mkdir -p "$OUT"

echo "[hb-calcheight] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-calcheight] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-calcheight] PASS host harness compiled -> $BIN"

echo "[hb-calcheight] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-calcheight] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-calcheight] PASS native hambrowse still compiles"

fail=0
D="$OUT/calcheight.txt"
"$BIN" "$FIX" 1200 >"$D" 2>&1 || { echo "[hb-calcheight] FAIL: render exited non-zero"; cat "$D"; exit 1; }
grep -E "^FILL .*#191919|^FILL .*#2a2a2a" "$D" || true

# FILL lines are "FILL top bot lx rx #hex ..."; height in rows = bot - top.
fill_rows() { grep -E "FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ $1( |$)" "$D" | awk '{print $3-$2}' | head -1; }

check() {   # name hex want
    local name="$1" hex="$2" want="$3" got
    got=$(fill_rows "$hex")
    echo "[hb-calcheight] $name: fill rows=$got (expect $want)"
    if [ -n "$got" ] && [ "$got" -eq "$want" ]; then
        echo "[hb-calcheight] PASS $name"
    else
        echo "[hb-calcheight] FAIL $name (rows=$got want=$want)"; fail=1
    fi
}

# calc(100% - 200px) -> 400px -> 25 rows  (% of viewport HEIGHT 600, not width).
check "calc(100% - 200px) height -> 25 rows (400px)" '#191919' 25
# calc(100% - 450px) -> 150px -> 9 rows.
check "calc(100% - 450px) height -> 9 rows (150px)"  '#2a2a2a' 9

if [ "$fail" -ne 0 ]; then
    echo "[hb-calcheight] RESULT: FAIL"; exit 1
fi
echo "[hb-calcheight] RESULT: PASS"
