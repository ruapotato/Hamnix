#!/usr/bin/env bash
# scripts/test_hambrowse_height_host.sh — FAST, QEMU-free gate for ROUND-3 CSS
# vertical sizing (height / min-height / max-height) in the native browser engine
# (lib/web/layout/box.ad). These cascade winners (m_ht/m_minh/m_maxh) were parsed
# by round-2 but not consumed; box.ad now pins/floors/clamps each box's ROW span
# on close and the background FILL tracks it. 16px per row (LINE_H):
#
#   (A) height:80px    -> a one-line box grows to a 5-row (80px) background box.
#   (B) min-height:64px-> a one-line box is floored to a 4-row (64px) box.
#   (C) max-height:32px-> a five-line box is clamped to a 2-row (32px) box.
#   (D) a plain box (no height) still hugs its single content line (1 row).
#
# Builds BOTH targets so a break in either backend is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_height.html"
mkdir -p "$OUT"

echo "[hb-height] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-height] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-height] PASS host harness compiled -> $BIN"

echo "[hb-height] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-height] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-height] PASS native hambrowse still compiles"

fail=0
D="$OUT/height.txt"
"$BIN" "$FIX" 600 >"$D" 2>&1 || { echo "[hb-height] FAIL: render exited non-zero"; cat "$D"; exit 1; }
cat "$D"

# FILL lines are "FILL top bot lx rx #hex"; height in rows = bot - top.
fill_rows() { grep -E "FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ $1( |$)" "$D" | awk '{print $3-$2}' | head -1; }

check() {
    local name="$1" hex="$2" want="$3"
    local got
    got=$(fill_rows "$hex")
    echo "[hb-height] $name: fill rows=$got (expect $want)"
    if [ -n "$got" ] && [ "$got" -eq "$want" ]; then
        echo "[hb-height] PASS $name"
    else
        echo "[hb-height] FAIL $name (rows=$got want=$want)"; fail=1
    fi
}

# (A) height:80px  -> 5 rows.
check "height:80px pins a 5-row box"      '#ffcc00' 5
# (B) min-height:64px -> 4 rows (floored above its 1-row content).
check "min-height:64px floors a 4-row box" '#00ccff' 4
# (C) max-height:32px -> 2 rows (clamped below its 5-row content).
check "max-height:32px clamps a 2-row box" '#ff8800' 2
# (D) a plain box with no height stays 1 row tall (no regression).
check "plain box hugs its 1-row content"   '#cccccc' 1

if [ "$fail" -ne 0 ]; then
    echo "[hb-height] RESULT: FAIL"; exit 1
fi
echo "[hb-height] RESULT: PASS"
