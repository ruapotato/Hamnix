#!/usr/bin/env bash
# scripts/test_de_appmenu_v2.sh — DE pivot wave 2 structural guard:
# the classic Applications cascading menu is no longer drawn by the
# daemon_pixel monolith. It now lives in /bin/hamappmenu, a separate-
# process v2 client that reads its catalogue from /dev/wsys/appmenu
# and writes the chosen prog path to /dev/wsys/appmenu/launch. The
# compositor (user/hamUId.ad) publishes the catalogue and drains the
# launch slot per frame.
#
# 2026-07-31 -- WHAT CHANGED UNDER LINK 2. hamappmenu was a hamui **v2-blit**
# client: hamui_set_protocol_v2 + hamui_v2_commit_rect, painting pixels into a
# kernel backbuffer. It has since been ported to the SCENE-FILE DE
# (docs/de_scene_file_arch.md) and now imports only `hamui_init,
# hamscene_begin, hamscene_commit` from lib/hamui.ad, committing a display list
# to /dev/wsys/<wid>/scene instead of pixels to /dev/fb. Link 2's two v2
# assertions were demanding a protocol the pivot deliberately replaced. GATE
# ROT, not a DE regression -- the menu is not broken, it is a scene client now.
# Everything else in link 2 (the build registration, the /dev/wsys/appmenu
# catalogue read, the /dev/wsys/appmenu/launch write) still passed and is
# unchanged: the catalogue/launch file protocol survived the pivot, only the
# PAINT path moved.
#
# Pass marker:  PASS: appmenu v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
APPMENU_SRC="user/hamappmenu.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$APPMENU_SRC" "$BUILD_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: menu-pixel paths are GONE from daemon_pixel -------------
# daemon_pixel was the procedural cascade that rendered the Applications
# drop-down + cascading category flyout pixel by pixel. The extraction
# means the menu_label / appcat_item_label calls vanish from inside
# daemon_pixel; if any of them still fires per-pixel, the renderer
# regressed back to the monolith.
daemon_pixel_body=$(awk '
    /^def[[:space:]]+daemon_pixel[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if [ -z "$daemon_pixel_body" ]; then
    fail_link "link 1 (hamUId.ad): daemon_pixel() not found - is it renamed?"
fi
for sym in "menu_search_nth" "appcat_item_label" "menubar_item_label" "submenu_item_at" "search_result_at" "menu_search_count"; do
    if grep -q "$sym" <<< "$daemon_pixel_body"; then
        fail_link "link 1 (hamUId.ad): daemon_pixel still references '$sym' - menu rendering did not extract cleanly"
    fi
done
# A breadcrumb comment marking the extraction must remain so a future
# refactor doesn't silently re-inline.
if ! grep -q "Applications menu rendering EXTRACTED" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): the 'Applications menu rendering EXTRACTED' breadcrumb is gone - regression marker missing"
fi

# --- Link 2: hamappmenu binary is registered + sources --------------
if ! grep -q "build_adder_user hamappmenu" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamappmenu is not built - the binary won't ship in the initramfs"
fi
# hamappmenu must read the catalogue snapshot + write the launch verb.
if ! grep -q '"/dev/wsys/appmenu"' "$APPMENU_SRC"; then
    fail_link "link 2 (hamappmenu.ad): does NOT read /dev/wsys/appmenu snapshot - the catalogue source is missing"
fi
if ! grep -q '"/dev/wsys/appmenu/launch"' "$APPMENU_SRC"; then
    fail_link "link 2 (hamappmenu.ad): does NOT write /dev/wsys/appmenu/launch - the click → spawn link is broken"
fi
# It must build a display list and commit it to its scene file.
if ! grep -qE "hamscene_begin[[:space:]]*\(" "$APPMENU_SRC"; then
    fail_link "link 2 (hamappmenu.ad): does NOT call hamscene_begin - it isn't building a display list"
fi
if ! grep -qE "hamscene_commit[[:space:]]*\(" "$APPMENU_SRC"; then
    fail_link "link 2 (hamappmenu.ad): does NOT call hamscene_commit - the display list never reaches /dev/wsys/<wid>/scene"
fi
# The v2 blit protocol must be GONE: a scene client that still painted pixels
# would be fighting the kernel scene compositor for /dev/fb.
for legacy in hamui_set_protocol_v2 hamui_v2_commit_rect; do
    if grep -q "$legacy" "$APPMENU_SRC"; then
        fail_link "link 2 (hamappmenu.ad): $legacy is BACK - a scene client must not paint through the v2 blit path"
    fi
done

# --- Link 3: kernel exposes /dev/wsys/appmenu + launch leaf ---------
for sym in "DEV_WSYS_APPMENU\b" "DEV_WSYS_APPMENU_LAUNCH"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_appmenu_read devwsys_appmenu_launch_read devwsys_appmenu_launch_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"appmenu/launch"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): appmenu/launch path is not resolved"
fi
if ! grep -q '"appmenu"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): appmenu path is not resolved"
fi
# The /dev/wsys/ctl `appmenu` verb is how hamUId publishes the
# catalogue.
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"appmenu"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'appmenu' verb is missing - the compositor can't publish the catalogue"
fi

# --- Link 4: compositor publishes, spawns, and drains ---------------
for fn in appmenu_publish_snapshot appmenu_spawn appmenu_drain_launch; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
# publish_snapshot must be called during daemon init.
if ! grep -q "appmenu_publish_snapshot()" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): appmenu_publish_snapshot is never called - the snapshot file stays empty"
fi
# drain_launch must run in the daemon main loop.
if ! grep -q "appmenu_drain_launch(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): appmenu_drain_launch is never called - hamappmenu's click never spawns the prog"
fi
# spawn must be triggered on the Applications panel button click.
if ! grep -q "appmenu_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): appmenu_spawn is never called - the Apps trigger doesn't bring up the menu"
fi
# It must spawn the SEPARATE-PROCESS hamappmenu binary, not draw inline.
if ! grep -q '"/bin/hamappmenu"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamappmenu - extraction is just a comment, not a behaviour change"
fi

# --- Link 5: hamUId watches the launch ctl --------------------------
# The drain helper must read from /dev/wsys/appmenu/launch (the
# launch ctl).
drain_body=$(awk '
    /^def[[:space:]]+appmenu_drain_launch[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/appmenu/launch"' <<< "$drain_body"; then
    fail_link "link 5 (hamUId.ad): appmenu_drain_launch does NOT read /dev/wsys/appmenu/launch - the watcher is wired to nothing"
fi
# It must hand off to daemon_spawn_window_prog so the chosen path
# becomes a real window.
if ! grep -q "daemon_spawn_window_prog" <<< "$drain_body"; then
    fail_link "link 5 (hamUId.ad): appmenu_drain_launch does NOT call daemon_spawn_window_prog - the click result never becomes a window"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: appmenu v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: appmenu v2 extraction intact"
exit 0
