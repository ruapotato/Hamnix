#!/usr/bin/env bash
# scripts/test_hamlog_host.sh — FAST, QEMU-free host gate for the Log Viewer
# scene app (lib/hamlogcore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). Compiles the core for the host target, seeds a
# deterministic block of kernel-log lines, renders the top page + a tailed page
# to PNGs a human/agent can LOOK at, drives scripted page-down / wheel / tail
# scroll input, asserts the ring counters + scroll math, AND confirms the
# NATIVE Hamnix build still compiles from the same core — all in ms, no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamlog_host"
mkdir -p "$OUT"
fail=0

echo "[log-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamlogscene_host.ad "$BIN" 2>"$OUT/log_compile.log"; then
    echo "[log-host] FAIL: host harness did not compile"; cat "$OUT/log_compile.log"; exit 1
fi
echo "[log-host] PASS host harness compiled -> $BIN"

echo "[log-host] compiling NATIVE hamlogscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamlogscene.ad "$OUT/hamlog_native.elf" 2>"$OUT/log_native.log"; then
    echo "[log-host] FAIL: native hamlogscene did not compile"; cat "$OUT/log_native.log"; exit 1
fi
echo "[log-host] PASS native hamlogscene still compiles"

DUMP="$OUT/log_dump.txt"
if ! "$BIN" "$OUT/log_top.ppm" "$OUT/log_tail.ppm" >"$DUMP" 2>&1; then
    echo "[log-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in top tail; do
    if python3 scripts/ppm_to_png.py "$OUT/log_$f.ppm" "$OUT/log_$f.png" 2>"$OUT/log_png.log"; then
        echo "[log-host] PASS rendered $OUT/log_$f.png"
    else
        echo "[log-host] FAIL png conversion ($f)"; cat "$OUT/log_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[log-host] PASS $2";
    else echo "[log-host] FAIL $2 (missing: $1)"; fail=1; fi
}

assert_grep '^# scene v1 hamui'                     "scene header emitted"
assert_grep '^fill 0 0 568 360 #eceef2'             "log window background"
assert_grep '^fill 8 34 524 296 #10161c'            "dark console text area"
assert_grep '^glyphs 10 8 \"Kernel Log  \(60 lines\)\"' "header shows the line count"
# top page: first seeded line visible, last (line #59) NOT yet visible.
assert_grep 'glyphs 12 38 .*subsystem init line #0'  "oldest line at top of first page"
assert_grep '^COUNT 60'                             "60 lines ingested into the ring"
assert_grep '^SCROLL0 0'                            "first page starts at top"
assert_grep '^PAGEDOWN 2'                           "page-down button returns ACT_LOG_DOWN(2)"
assert_grep '^SCROLL1 17'                           "page-down advanced one page (17 lines)"
assert_grep '^SCROLL2 15'                           "wheel up two notches scrolled back to 15"
assert_grep '^TAIL 3'                               "tail button returns ACT_LOG_TAIL(3)"
# 60 lines, 18 visible rows -> last page top index = 60-18 = 42.
assert_grep '^SCROLL3 42'                           "tail snapped to the newest page (42)"
# tailed page: the newest line (#59) is now on screen.
assert_grep 'glyphs .*subsystem init line #59'      "newest line visible after tail"
# Modern cohesive headerbar: a cool-blue vertical gradient (was a flat
# #3584e4). Scanline 4 of the azure gradient rasterizes to #618ac5.
assert_grep '^PIX 4 4 #618ac5'                      "raster headerbar pixel = cool-blue gradient"

if [ "$fail" -ne 0 ]; then echo "[log-host] OVERALL FAIL"; exit 1; fi
echo "[log-host] OVERALL PASS"
