#!/usr/bin/env bash
# scripts/test_de_desktop_wallpaper.sh — structural guard that the scene-file
# desktop (user/hamdesktop.ad) CONSUMES the kernel wallpaper status file and
# renders an image backdrop with a solid-colour fallback.
#
# The Settings app sets a wallpaper by writing `wallpaper <path>` to
# /dev/wsys/ctl; the kernel records it and exposes /dev/wsys/wallpaper as
# "<gen> <path>\n". hamdesktop must poll that file, parse the P6 PPM, render
# it as the backdrop, and fall back to the solid teal fill when no wallpaper
# is set or the file is unreadable/not a valid P6.
#
# Grep-only (no QEMU boot). Companion to scripts/test_de_wallpaper.sh (which
# guards the retired hamUId compositor's copy of the same primitives) and the
# live visual gate scripts/test_de_wallpaper_backdrop.sh.
#
# Pass marker:  PASS: hamdesktop wallpaper backdrop primitives intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

DESK_SRC="user/hamdesktop.ad"
fail=0
fail_link() { echo "FAIL: $1" >&2; fail=1; }

if [ ! -f "$DESK_SRC" ]; then
    echo "FAIL: source file missing: $DESK_SRC" >&2
    exit 1
fi

# --- Polls the kernel wallpaper status file ------------------------------
if ! grep -q '"/dev/wsys/wallpaper"' "$DESK_SRC"; then
    fail_link "hamdesktop no longer opens /dev/wsys/wallpaper"
fi
if ! grep -Eq "^def[[:space:]]+_wp_poll_kernel" "$DESK_SRC"; then
    fail_link "hamdesktop _wp_poll_kernel() definition gone"
fi
# The poll must be CALLED from the main loop (not just defined).
if ! grep -q "_wp_poll_kernel()" "$DESK_SRC"; then
    fail_link "hamdesktop _wp_poll_kernel() is never called (main loop missed)"
fi
# Gen-change tracking (only reload on a bump).
if ! grep -q "wp_gen_seen" "$DESK_SRC"; then
    fail_link "hamdesktop wp_gen_seen gen-tracking gone"
fi

# --- P6 PPM parser + image render ----------------------------------------
if ! grep -Eq "^def[[:space:]]+_wp_ppm_parse_p6" "$DESK_SRC"; then
    fail_link "hamdesktop _wp_ppm_parse_p6() (P6 parser) gone"
fi
if ! grep -Eq "^def[[:space:]]+_wp_load_path" "$DESK_SRC"; then
    fail_link "hamdesktop _wp_load_path() (PPM file loader) gone"
fi
if ! grep -Eq "^def[[:space:]]+emit_wallpaper" "$DESK_SRC"; then
    fail_link "hamdesktop emit_wallpaper() (mosaic backdrop) gone"
fi
if ! grep -Eq "^wp_rgb:[[:space:]]*Array" "$DESK_SRC"; then
    fail_link "hamdesktop wp_rgb[] decoded-image buffer gone"
fi

# --- Backdrop wiring: image path THEN solid fallback ---------------------
# emit_scene must try the image first and fall back to the solid teal fill.
if ! grep -q "emit_wallpaper() == 0" "$DESK_SRC"; then
    fail_link "hamdesktop emit_scene no longer prefers emit_wallpaper() over the solid fill"
fi
# The no-wallpaper FALLBACK backdrop. This used to be a flat teal #205060
# fill; the desktop now paints emit_gradient_bg() (the banded out-of-box
# gradient the "Default" wallpaper mirrors). Assert the fallback CALL, not the
# retired colour literal — the literal-only check had been failing red on main
# since the gradient landed.
if ! grep -Eq "^def[[:space:]]+emit_gradient_bg" "$DESK_SRC" \
        || ! grep -q "        emit_gradient_bg()" "$DESK_SRC"; then
    fail_link "hamdesktop no-wallpaper gradient backdrop FALLBACK gone"
fi

# --- Full-coverage backdrop (user bug: black band at the bottom) ----------
# The image backdrop must cover the WHOLE framebuffer. Two mechanisms:
#   1. the compositor named-image blit (one `image 0 0 scr_w scr_h` op), and
#   2. the fallback fill mosaic, which must COARSEN to fit its byte budget
#      rather than stop partway down the screen.
if ! grep -Eq "^def[[:space:]]+_wp_upload_image" "$DESK_SRC"; then
    fail_link "hamdesktop _wp_upload_image() (named-image wallpaper blit) gone"
fi
if ! grep -q "hamscene_image(0, 0, cast\[int32\](scr_w), cast\[int32\](scr_h)" "$DESK_SRC"; then
    fail_link "hamdesktop wallpaper blit no longer covers the full screen rect"
fi
if ! grep -Eq "^def[[:space:]]+_wp_mosaic_fills" "$DESK_SRC"; then
    fail_link "hamdesktop mosaic fill-COUNTING (budget fit) gone — the mosaic can truncate again"
fi
if grep -q "if hamscene_length() >= WP_SCENE_BUDGET:" "$DESK_SRC"; then
    fail_link "hamdesktop mosaic still BREAKS out mid-image on the byte budget (black band at the bottom)"
fi

# --- PPM byte-string parse smoke (the layout we hard-code must parse) -----
TMP_PPM="$(mktemp -t hamnix.deskwp.XXXXXX.ppm)"
trap 'rm -f "$TMP_PPM"' EXIT
{
    printf 'P6\n2 2\n255\n'
    printf '\xff\x00\x00\x00\xff\x00\x00\x00\xff\xff\xff\xff'
} > "$TMP_PPM"
[ "$(head -c 2 "$TMP_PPM")" = "P6" ] || fail_link "ppm: fixture not 'P6'"
[ "$(wc -c < "$TMP_PPM")" -eq 23 ] || fail_link "ppm: fixture size != 23"

if [ "$fail" -ne 0 ]; then
    echo "FAIL: hamdesktop wallpaper backdrop primitives BROKEN (see link(s) above)" >&2
    exit 1
fi
echo "PASS: hamdesktop wallpaper backdrop primitives intact"
exit 0
