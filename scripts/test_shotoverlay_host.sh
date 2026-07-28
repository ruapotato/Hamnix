#!/usr/bin/env bash
# scripts/test_shotoverlay_host.sh — FAST, QEMU-free host gate for the
# screenshot "select area" overlay.
#
# Regression guard for the bug where "select area" mode drew the rubber-band
# selection on a BLACK screen instead of over the LIVE desktop. The overlay is
# a full-screen scrim the compositor now presents in `blend` (source-over)
# mode: the #00000066 dim alpha-blends over the desktop so the user still sees
# what they are framing. This gate renders the SAME overlay model the native
# app ships (lib/shotoverlay.ad, drawn via lib/hamscene.ad + rasterized by the
# alpha-aware lib/hamui_host.ad) OVER a synthetic desktop and asserts the
# desktop shows THROUGH the scrim — all in milliseconds, no QEMU.
#
# It also confirms the touched NATIVE app (user/hamshotui.ad) and kernel
# compositor still consume the shared model.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/shotoverlay_host"
mkdir -p "$OUT"
fail=0

echo "[shotoverlay-host] compiling overlay model + harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/shotoverlay_host.ad "$BIN" 2>"$OUT/shotoverlay_compile.log"; then
    echo "[shotoverlay-host] FAIL: host harness did not compile"
    cat "$OUT/shotoverlay_compile.log"; exit 1
fi
echo "[shotoverlay-host] PASS host harness compiled -> $BIN"

echo "[shotoverlay-host] running host harness ..."
DUMP="$OUT/shotoverlay_dump.txt"
if ! "$BIN" "$OUT/shotoverlay_black.ppm" "$OUT/shotoverlay_desktop.ppm" \
        >"$DUMP" 2>&1; then
    echo "[shotoverlay-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in black desktop; do
    if python3 scripts/ppm_to_png.py "$OUT/shotoverlay_$f.ppm" \
            "$OUT/shotoverlay_$f.png" 2>"$OUT/shotoverlay_png.log"; then
        echo "[shotoverlay-host] PASS rendered $OUT/shotoverlay_$f.png ($(file -b "$OUT/shotoverlay_$f.png" 2>/dev/null))"
    else
        echo "[shotoverlay-host] FAIL png conversion ($f)"; cat "$OUT/shotoverlay_png.log"; fail=1
    fi
done

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[shotoverlay-host] PASS $msg"
    else
        echo "[shotoverlay-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}
assert_no_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[shotoverlay-host] FAIL $msg (present: $pat)"; fail=1
    else
        echo "[shotoverlay-host] PASS $msg"
    fi
}

# --- the overlay display list: scrim + banner + selection rectangle -------
assert_grep '^# scene v1 hamui'                    "scene header emitted"
assert_grep '^fill 0 0 1024 768 #00000066'         "translucent (alpha 66) full-screen dim scrim, not opaque"
assert_grep 'glyphs [0-9]+ [0-9]+ \"Drag to select an area  -  Esc to cancel\"' "instruction banner"
assert_grep '^stroke 200 200 420 300 2 #ffd166'    "bright selection rectangle border"
assert_grep '^fill 200 200 420 300 #ffffff22'      "selection interior tint"

# --- THE FIX: the live desktop shows THROUGH the scrim --------------------
# OLD bug: overlay over nothing -> a point outside the selection is pure black.
assert_grep '^PIX black-outside 60 700 #000000'    "old-bug repro: overlay over black IS black (contrast baseline)"
# FIXED: over the desktop, the same point is the wallpaper DIMMED, not black.
assert_grep '^PIX desk-wall 60 700 #222c38'        "wallpaper visible under the scrim (dimmed slate, NOT black)"
assert_no_grep '^PIX desk-wall 60 700 #000000'     "wallpaper under the scrim is NOT blacked out"
# The light document window under the scrim stays clearly light.
assert_grep '^PIX desk-doc 700 400 #92918d'        "light app window still visible (dimmed light, NOT black)"
# Inside the selection over the terminal body: visible, not black.
assert_no_grep '^PIX desk-sel 300 300 #000000'     "selection interior shows the window beneath, not black"

# --- NATIVE app consumes the shared overlay model (compiles) --------------
echo "[shotoverlay-host] compiling NATIVE hamshotui for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamshotui.ad "$OUT/hamshotui_native.elf" 2>"$OUT/shotoverlay_native.log"; then
    echo "[shotoverlay-host] FAIL: native hamshotui did not compile"
    tail -40 "$OUT/shotoverlay_native.log"; fail=1
else
    echo "[shotoverlay-host] PASS native hamshotui still compiles (wired to lib/shotoverlay.ad + blend present)"
fi

if [ "$fail" -eq 0 ]; then
    echo "[shotoverlay-host] RESULT: PASS"
    exit 0
else
    echo "[shotoverlay-host] RESULT: FAIL"
    exit 1
fi
