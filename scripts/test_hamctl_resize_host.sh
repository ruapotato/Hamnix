#!/usr/bin/env bash
# scripts/test_hamctl_resize_host.sh — FAST, QEMU-free host gate proving the
# Control Center RELAYOUTS on window resize (lib/hamctlcore.ad drawn through
# lib/hamscene.ad, rasterized by lib/hamui_host.ad).
#
# Regression guard for the toolkit resize bug: before the fix the scene app
# ignored the compositor's "r <w> <h>" resize event and always rebuilt the
# scene at the fixed 520x400 default, so at any larger size the window showed
# the 520x400 scene in the top-left and the rest painted as an uninitialised
# BLACK gutter. This gate renders at several sizes and probes a pixel deep in
# that gutter: it MUST be black in the pre-fix ("bug") render and the toolkit
# background in the post-fix ("fix") render.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamctl_resize_host"
mkdir -p "$OUT"
fail=0

echo "[ctl-resize] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamctl_resize_host.ad "$BIN" 2>"$OUT/ctl_resize_compile.log"; then
    echo "[ctl-resize] FAIL: host harness did not compile"; cat "$OUT/ctl_resize_compile.log"; exit 1
fi
echo "[ctl-resize] PASS host harness compiled -> $BIN"

# The NATIVE app must still compile (it now parses the 'r <w> <h>' event).
echo "[ctl-resize] compiling NATIVE hamctl for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamctl.ad "$OUT/hamctl_native.elf" 2>"$OUT/ctl_resize_native.log"; then
    echo "[ctl-resize] FAIL: native hamctl did not compile"; cat "$OUT/ctl_resize_native.log"; exit 1
fi
echo "[ctl-resize] PASS native hamctl still compiles"

DUMP="$OUT/ctl_resize_dump.txt"
if ! "$BIN" "$OUT" >"$DUMP" 2>&1; then
    echo "[ctl-resize] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in small medium odd large; do
    for k in bug fix; do
        python3 scripts/ppm_to_png.py "$OUT/ctl_resize_${f}_${k}.ppm" \
            "$OUT/ctl_resize_${f}_${k}.png" 2>"$OUT/ctl_resize_png.log" \
            && echo "[ctl-resize] PASS rendered $OUT/ctl_resize_${f}_${k}.png" \
            || { echo "[ctl-resize] FAIL png conversion (${f}_${k})"; fail=1; }
    done
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[ctl-resize] PASS $2";
    else echo "[ctl-resize] FAIL $2 (missing: $1)"; fail=1; fi
}

# At sizes LARGER than the 520x400 default, the deep-gutter probe is BLACK
# before the fix and the toolkit background (#eceef2) after it. (The 'small'
# case is entirely within 520x400, so no gutter exists either way — skipped.)
for f in medium odd large; do
    assert_grep "^PROBE ${f} bug .* #000000" "gutter is BLACK before relayout (${f})"
    assert_grep "^PROBE ${f} fix .* #eceef2" "gutter FILLED after relayout (${f})"
done

# The live toolkit size tracks the resize event.
assert_grep '^SIZE medium 700 520' "toolkit size updated to 700x520"
assert_grep '^SIZE odd 611 543'     "toolkit size updated to 611x543"
assert_grep '^SIZE large 1024 720'  "toolkit size updated to 1024x720"

if [ "$fail" -ne 0 ]; then echo "[ctl-resize] OVERALL FAIL"; exit 1; fi
echo "[ctl-resize] OVERALL PASS"
