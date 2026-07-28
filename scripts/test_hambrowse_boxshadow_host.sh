#!/usr/bin/env bash
# scripts/test_hambrowse_boxshadow_host.sh — FAST, QEMU-free gate for the last
# big css-backgrounds-borders visual gaps in the native browser engine:
#
#   1. box-shadow — parsed in the cascade (offset/blur/spread/colour, `none`)
#      into a coarse size class, then painted as a dark, feathered, offset drop
#      shadow BEHIND the element's border-box (htmlpaint_shadow_round_rect),
#      giving cards/menus/modals real depth. v1 approximation: a default
#      dark-30% shadow whose size scales with the declared blur; single shadow;
#      no inset (see docs/browser_w3c_conformance.md).
#   2. opacity + rgba()/hsla()/#rrggbbaa alpha — the declared alpha is no longer
#      thrown away (rendered opaque). The cascade folds rgba alpha AND element
#      `opacity` into the packed fill/border colour, and the paint pass
#      composites the fill/border at that alpha over the background
#      (htmlpaint_fill_round_rect_a / stroke_round_rect_a / _blend_px).
#
# Builds BOTH the text-dump host harness AND the pixel backend for x86_64-linux
# (+ confirms native hambrowse still compiles), renders the fixture to a PPM/PNG
# and asserts the BLENDED PIXEL VALUES (opacity 50% blend, rgba pink, and a
# fading offset grey shadow) — no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
GFX="$OUT/hambrowse_gfx"
FIX="tests/fixtures/hambrowse_boxshadow.html"
mkdir -p "$OUT"
fail=0

echo "[hb-bs] compiling text harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/bs_compile.log"; then
    echo "[hb-bs] FAIL: host harness did not compile"; cat "$OUT/bs_compile.log"; exit 1
fi
echo "[hb-bs] PASS text harness compiled -> $BIN"

echo "[hb-bs] compiling pixel backend for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$GFX" 2>"$OUT/bs_gfx.log"; then
    echo "[hb-bs] FAIL: pixel backend did not compile"; cat "$OUT/bs_gfx.log"; exit 1
fi
echo "[hb-bs] PASS pixel backend compiled -> $GFX"

echo "[hb-bs] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/bs_native.log"; then
    echo "[hb-bs] FAIL: native hambrowse did not compile"; cat "$OUT/bs_native.log"; exit 1
fi
echo "[hb-bs] PASS native hambrowse still compiles"

# text-dump sanity: the three styled block fills are registered.
D0="$OUT/bs_run.txt"
"$BIN" "$FIX" 800 >"$D0" 2>&1 || { echo "[hb-bs] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
grep -E '^FILL' "$D0" || true
assert_grep() {
    if grep -Eq -- "$1" "$D0"; then echo "[hb-bs] PASS $2";
    else echo "[hb-bs] FAIL $2 (missing: $1)"; fail=1; fi
}
assert_grep 'FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #3060c0' "opacity box fill registered"
assert_grep 'FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #ff0000' "rgba box fill registered"
assert_grep 'FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #dfe6f5' "shadow card fill registered"

# pixel path: render, then assert the BLENDED pixel values.
PPM="$OUT/bs.ppm"; PNG="$OUT/bs.png"; GD="$OUT/bs_gfx_dump.txt"
if "$GFX" "$FIX" "$PPM" 800 >"$GD" 2>&1; then
    if python3 scripts/hb_boxshadow_probe.py "$GD" "$PPM"; then
        echo "[hb-bs] PASS blended-pixel assertions (opacity / rgba / shadow)"
    else
        echo "[hb-bs] FAIL blended-pixel assertions"; fail=1
    fi
    if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/bs_png.log"; then
        echo "[hb-bs] PASS pixel render -> $PNG ($(file -b "$PNG" 2>/dev/null))"
    else
        echo "[hb-bs] FAIL png conversion"; cat "$OUT/bs_png.log"; fail=1
    fi
else
    echo "[hb-bs] FAIL: pixel render exited non-zero"; cat "$GD"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-bs] RESULT: FAIL"; exit 1; fi
echo "[hb-bs] RESULT: PASS"
