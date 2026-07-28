#!/usr/bin/env bash
# scripts/test_hamctl_wallpaper_host.sh — FAST, QEMU-free host gate for the
# Control Center's IMAGE wallpapers. The pure procedural pixel law
# (lib/hamctlcore.ad hamctl_image_rgb) is emitted as a full-screen 24x18 fill
# mosaic — the EXACT backdrop shape user/hamdesktop.ad::emit_wallpaper paints
# on-device from the applied PPM — and rasterized by lib/hamui_host.ad. It
# renders each image to a PNG a human/agent can LOOK at and asserts the
# background is NON-UNIFORM (a real image, not a flat fill), with a solid-fill
# control that must stay uniform. Then confirms the NATIVE driver (user/hamctl)
# still compiles for x86_64-adder-user. All in milliseconds, no QEMU.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamctl_wall_host"
mkdir -p "$OUT"

echo "[hamctl-wall] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamctl_wall_host.ad "$BIN" 2>"$OUT/hamctl_wall_compile.log"; then
    echo "[hamctl-wall] FAIL: host harness did not compile"
    cat "$OUT/hamctl_wall_compile.log"; exit 1
fi
echo "[hamctl-wall] PASS host harness compiled -> $BIN"

echo "[hamctl-wall] compiling NATIVE hamctl for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamctl.ad "$OUT/hamctl_native.elf" 2>"$OUT/hamctl_native.log"; then
    echo "[hamctl-wall] FAIL: native hamctl did not compile"
    cat "$OUT/hamctl_native.log"; exit 1
fi
echo "[hamctl-wall] PASS native hamctl still compiles"

SUN="$OUT/wall_sunset.ppm"
OCE="$OUT/wall_ocean.ppm"
TIL="$OUT/wall_tiles.ppm"
DUMP="$OUT/hamctl_wall_dump.txt"
echo "[hamctl-wall] running host harness ..."
if ! "$BIN" "$SUN" "$OCE" "$TIL" >"$DUMP" 2>&1; then
    echo "[hamctl-wall] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

# Render each PPM to a PNG for eyeballing (stdlib-only converter).
for f in "$SUN" "$OCE" "$TIL"; do
    png="${f%.ppm}.png"
    if python3 scripts/ppm_to_png.py "$f" "$png" 2>>"$OUT/hamctl_wall_png.log"; then
        echo "[hamctl-wall] wrote $png ($(file -b "$png" 2>/dev/null))"
    fi
done

fail=0
require() {
    if ! grep -q "$1" "$DUMP"; then
        echo "[hamctl-wall] FAIL: missing marker: $1"; fail=1
    fi
}
# Images 1,2,3 = Sunset, Ocean, Tiles (image 0 is the Default gradient; the
# harness renders each into the file it is named after).
require "IMG 1 NONUNIFORM PASS"
require "IMG 2 NONUNIFORM PASS"
require "IMG 3 NONUNIFORM PASS"
require "SOLID UNIFORM PASS"
require "WALLPAPER_GATE PASS"

if [ "$fail" -ne 0 ]; then
    echo "[hamctl-wall] FAIL"; exit 1
fi
echo "[hamctl-wall] PASS — image wallpapers render a non-uniform backdrop"
