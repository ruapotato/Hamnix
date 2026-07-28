#!/usr/bin/env bash
# scripts/test_hammon_resize_host.sh — FAST, QEMU-free host gate proving the
# scene-DE System Monitor RELAYOUTS on window resize (lib/hammoncore.ad drawn
# through lib/hamscene.ad, rasterized by lib/hamui_host.ad).
#
# Regression guard for the same toolkit resize bug fixed in the Control Center
# (c29297f2): before the fix the monitor read /event but DISCARDED the bytes,
# so it ignored the compositor's "r <w> <h>" resize event and always rebuilt
# the scene at the fixed 360x420 default. At any larger size the window showed
# the 360x420 scene in the top-left and the rest painted as an uninitialised
# BLACK gutter. This gate renders at several sizes and probes a pixel deep in
# that gutter: it MUST be black in the pre-fix ("bug") render and the monitor
# background (#23272e) in the post-fix ("fix") render.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hammon_resize_host"
mkdir -p "$OUT"
fail=0

echo "[mon-resize] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hammon_resize_host.ad "$BIN" 2>"$OUT/mon_resize_compile.log"; then
    echo "[mon-resize] FAIL: host harness did not compile"; cat "$OUT/mon_resize_compile.log"; exit 1
fi
echo "[mon-resize] PASS host harness compiled -> $BIN"

# The NATIVE app must still compile (it now parses the 'r <w> <h>' event).
echo "[mon-resize] compiling NATIVE hammonscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hammonscene.ad "$OUT/hammonscene_native.elf" 2>"$OUT/mon_resize_native.log"; then
    echo "[mon-resize] FAIL: native hammonscene did not compile"; cat "$OUT/mon_resize_native.log"; exit 1
fi
echo "[mon-resize] PASS native hammonscene still compiles"

DUMP="$OUT/mon_resize_dump.txt"
if ! "$BIN" "$OUT" >"$DUMP" 2>&1; then
    echo "[mon-resize] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in small medium odd large; do
    for k in bug fix; do
        python3 scripts/ppm_to_png.py "$OUT/mon_resize_${f}_${k}.ppm" \
            "$OUT/mon_resize_${f}_${k}.png" 2>"$OUT/mon_resize_png.log" \
            && echo "[mon-resize] PASS rendered $OUT/mon_resize_${f}_${k}.png" \
            || { echo "[mon-resize] FAIL png conversion (${f}_${k})"; fail=1; }
    done
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[mon-resize] PASS $2";
    else echo "[mon-resize] FAIL $2 (missing: $1)"; fail=1; fi
}

# At sizes LARGER than the 360x420 default, the deep-gutter probe is BLACK
# before the fix and the monitor background (#23272e) after it. (The 'small'
# case is entirely within 360x420, so no gutter exists either way — skipped.)
for f in medium odd large; do
    assert_grep "^PROBE ${f} bug .* #000000" "gutter is BLACK before relayout (${f})"
    assert_grep "^PROBE ${f} fix .* #23272e" "gutter FILLED after relayout (${f})"
done

# The live core size tracks the resize event.
assert_grep '^SIZE medium 700 520' "monitor size updated to 700x520"
assert_grep '^SIZE odd 611 543'     "monitor size updated to 611x543"
assert_grep '^SIZE large 1024 720'  "monitor size updated to 1024x720"

if [ "$fail" -ne 0 ]; then echo "[mon-resize] OVERALL FAIL"; exit 1; fi
echo "[mon-resize] OVERALL PASS"
