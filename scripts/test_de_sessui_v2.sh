#!/usr/bin/env bash
# scripts/test_de_sessui_v2.sh — DE pivot wave 8 structural guard:
# the modal "End Session" dialog (Lock Screen / Log Out / Shut Down /
# Cancel) is no longer drawn by the daemon_pixel monolith. It now lives
# in /bin/hamsessui, a separate process that renders its own window.
# The compositor (user/hamUId.ad) publishes the (open, hover) model on
# every dialog mutation and pokes the show serial.
#
# 2026-07-31 -- WHAT CHANGED UNDER LINK 2. hamsessui was a hamui **v2-blit**
# client: hamui_set_protocol_v2 + hamui_v2_commit_rect, painting pixels into a
# kernel backbuffer, and polling /dev/wsys/sessui for its model. It has since
# been ported to the SCENE-FILE DE (docs/de_scene_file_arch.md): it builds a
# display list with the lib/hamui.ad hamscene_* helpers and commits it to
# /dev/wsys/<wid>/scene; the kernel scene compositor owns /dev/fb and, in the
# words of user/hamsessui.ad's own header, "v2 blit clients never paint there".
# The same header records the other two changes: the dialog is spawned
# ON-DEMAND from hamappmenu's "Log Out", so there is "no external open flag, no
# /dev/wsys/sessui snapshot poll", and it reads its OWN input from
# /dev/wsys/<wid>/event and /dev/wsys/<wid>/keys.
#
# Link 2 was therefore demanding all three of the things the port deliberately
# removed, and failing on all three. GATE ROT, not a DE regression -- the
# dialog is not broken, it is a scene client now. Link 2 below asserts the
# protocol hamsessui ACTUALLY speaks.
#
# NOTE for whoever touches this next: links 3 and 4 still pass, which means the
# kernel /dev/wsys/sessui + sessui/show leaves and hamUId's
# sessui_publish_snapshot / sessui_spawn / sessui_poke_show all still exist even
# though the client no longer reads any of them. That plumbing looks vestigial
# after the scene port. It is deliberately left alone here -- deleting kernel
# file-server leaves is not a gate repair -- but it is worth an audit.
#
# Pass marker:  PASS: sessui v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
SESSUI_SRC="user/hamsessui.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$SESSUI_SRC" "$BUILD_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: session-pixel paths are GONE from daemon_pixel ---------
# The legacy modal dialog fanned out an ~58-line cascade inside
# daemon_pixel, keyed on SESSION_OPEN. If any of its render bindings
# (SESSION_W/SESSION_PAD/SESSION_BTN_H/SESSION_ROWS/session_row_label
# rendering) still appear inside daemon_pixel, the renderer regressed
# back to the monolith.
daemon_pixel_body=$(awk '
    /^def[[:space:]]+daemon_pixel[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if [ -z "$daemon_pixel_body" ]; then
    fail_link "link 1 (hamUId.ad): daemon_pixel() not found - is it renamed?"
fi
for sym in "SESSION_W\b" "SESSION_PAD\b" "SESSION_BTN_H" "SESSION_ROWS" "session_row_label"; do
    if grep -qE "$sym" <<< "$daemon_pixel_body"; then
        fail_link "link 1 (hamUId.ad): daemon_pixel still references '$sym' - session-dialog rendering did not extract cleanly"
    fi
done
# A breadcrumb comment marking the extraction must remain so a future
# refactor doesn't silently re-inline.
if ! grep -q "Session dialog .*EXTRACTED" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): the 'Session dialog ... EXTRACTED' breadcrumb is gone - regression marker missing"
fi

# --- Link 2: hamsessui binary is registered + sources --------------
if ! grep -q "build_adder_user hamsessui" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamsessui is not built - the binary won't ship in the initramfs"
fi
# hamsessui must build a display list and commit it to its scene file.
if ! grep -qE "hamscene_begin[[:space:]]*\(" "$SESSUI_SRC"; then
    fail_link "link 2 (hamsessui.ad): does NOT call hamscene_begin - it isn't building a display list"
fi
if ! grep -qE "hamscene_commit[[:space:]]*\(" "$SESSUI_SRC"; then
    fail_link "link 2 (hamsessui.ad): does NOT call hamscene_commit - the display list never reaches /dev/wsys/<wid>/scene"
fi
# The scene port made it self-driving: it reads its OWN pointer and key input
# from its per-window files rather than being fed a model by the compositor.
if ! grep -q '"/event"' "$SESSUI_SRC"; then
    fail_link "link 2 (hamsessui.ad): does NOT open its own /dev/wsys/<wid>/event - pointer input is unwired"
fi
if ! grep -q '"/keys"' "$SESSUI_SRC"; then
    fail_link "link 2 (hamsessui.ad): does NOT open its own /dev/wsys/<wid>/keys - Escape can't dismiss the dialog"
fi
# The v2 blit protocol must be GONE: a scene client that still painted pixels
# would be fighting the kernel scene compositor for /dev/fb.
for legacy in hamui_set_protocol_v2 hamui_v2_commit_rect; do
    if grep -q "$legacy" "$SESSUI_SRC"; then
        fail_link "link 2 (hamsessui.ad): $legacy is BACK - a scene client must not paint through the v2 blit path"
    fi
done

# --- Link 3: kernel exposes /dev/wsys/sessui + show leaves ----------
for sym in "DEV_WSYS_SESSUI\b" "DEV_WSYS_SESSUI_SHOW"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_sessui_read devwsys_sessui_show_read devwsys_sessui_show_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"sessui/show"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): sessui/show path is not resolved"
fi
if ! grep -q '"sessui"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): sessui path is not resolved"
fi
# The /dev/wsys/ctl `sessui` verb is how hamUId publishes the model.
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"sessui"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'sessui' verb is missing - the compositor can't publish the model"
fi

# --- Link 4: compositor publishes, spawns, and pokes ---------------
for fn in sessui_publish_snapshot sessui_spawn sessui_poke_show sessui_publish_if_changed; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
# publish + poke must fire from session_open (the modal becomes visible).
session_open_body=$(awk '
    /^def[[:space:]]+session_open[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if [ -z "$session_open_body" ]; then
    fail_link "link 4 (hamUId.ad): session_open() not found"
fi
if ! grep -q "sessui_publish_snapshot()" <<< "$session_open_body"; then
    fail_link "link 4 (hamUId.ad): session_open() does NOT call sessui_publish_snapshot - hamsessui won't see the dialog open"
fi
if ! grep -q "sessui_poke_show()" <<< "$session_open_body"; then
    fail_link "link 4 (hamUId.ad): session_open() does NOT call sessui_poke_show - the client never gets woken"
fi
# spawn must be called from daemon startup.
if ! grep -q "sessui_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): sessui_spawn is never called - the client is never launched"
fi
# It must spawn the SEPARATE-PROCESS hamsessui binary, not draw inline.
if ! grep -q '"/bin/hamsessui"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamsessui - extraction is just a comment, not a behaviour change"
fi
# publish_if_changed must run in the per-frame overlay path.
post_present_body=$(awk '
    /^def[[:space:]]+post_present_overlays[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q "sessui_publish_if_changed()" <<< "$post_present_body"; then
    fail_link "link 4 (hamUId.ad): post_present_overlays does NOT call sessui_publish_if_changed - hover updates never reach the client"
fi

# --- Link 5: publish path uses the kernel files --------------------
pub_body=$(awk '
    /^def[[:space:]]+sessui_publish_snapshot[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctl"' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): sessui_publish_snapshot does NOT write /dev/wsys/ctl - the model never reaches the kernel"
fi
if ! grep -q '"sessui "' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): sessui_publish_snapshot does NOT emit the 'sessui' verb - the kernel won't accept the payload"
fi
poke_body=$(awk '
    /^def[[:space:]]+sessui_poke_show[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/sessui/show"' <<< "$poke_body"; then
    fail_link "link 5 (hamUId.ad): sessui_poke_show does NOT write /dev/wsys/sessui/show - the show-serial never bumps"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: sessui v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: sessui v2 extraction intact"
exit 0
