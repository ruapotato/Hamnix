#!/usr/bin/env bash
# scripts/test_de_cursor_decouple.sh - structural regression guard for the
# DE perf cursor-decouple path (kernel-overlay cursor independent of the
# compositor hot path).
#
# Background. The compositor's main loop (user/hamUId.ad) does input,
# layout, scene-build, and present in one thread. Before this guard, the
# cursor sprite was painted INLINE during scene_blit_rect via
# cursor_pixel_over — which meant a slow daemon_present() (a window drag,
# a popup composite) pegged cursor latency at compositor cadence (~0.5 Hz
# under load). The fix lifts the cursor into the kernel as a true OVERLAY
# layer (drivers/video/fb_cdev.ad): userland writes one 24-byte CURS
# command to /dev/fbctl on every mouse pump, and the kernel paints the
# sprite on top of every subsequent blit. Cursor latency = mouse-rx ->
# CURS write, NEVER blocked by the compositor's slow path.
#
# This is a fast, deterministic, grep-only guard (NO QEMU boot). It locks
# in the five load-bearing links of the decoupled cursor chain so a future
# refactor can't silently sever any of them without a CI failure naming
# exactly which link broke:
#
#   1. drivers/video/fb_cdev.ad
#        FBCTL_CURS_MAGIC (= 0x53525543, 'CURS' LE) is defined, and the
#        CURS-command dispatcher _fbctl_curs_command + magic recogniser
#        _fbctl_is_curs exist. These are the kernel entry points the
#        userland write lands on.
#
#   2. drivers/video/fb_cdev.ad
#        The cursor SPRITE save/redraw primitives (_kcursor_save_under,
#        _kcursor_paint, _kcursor_erase, _kcursor_redraw) exist. Without
#        these the kernel can't snapshot underlay pixels or composite the
#        arrow on top — so a CURS write would either no-op or scribble.
#
#   3. drivers/video/fb_cdev.ad
#        devfb_write AND _fbctl_rect_present (called from devfbctl_write)
#        call _kcursor_erase BEFORE the blit and _kcursor_redraw AFTER it.
#        This is what keeps the kernel cursor on TOP of whatever the
#        compositor most recently drew, even when the compositor's slow
#        path is overwriting a region that overlaps the sprite.
#
#   4. user/hamUId.ad
#        kcursor_send + kcursor_push_live are DEFINED, the CURS magic
#        FBCTL_CURS_MAGIC_HUI matches the kernel constant byte-for-byte,
#        AND kcursor_push_live() is CALLED from daemon_pump_mouse — the
#        load-bearing decouple point. Without the daemon_pump_mouse call
#        the kernel cursor only advances when the compositor manages a
#        present, which puts us right back on the slow path.
#
#   5. user/hamUId.ad
#        The legacy in-line userland cursor overlay (cursor_pixel_over)
#        GATES on KCURSOR_ACTIVE — when the kernel overlay is live, the
#        userland overlay returns early so the sprite is NOT painted
#        twice (once by the kernel, again — stale — by the cached scene
#        blit).
#
# Pass marker:  PASS: DE cursor-decouple chain intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

FBCDEV="drivers/video/fb_cdev.ad"
UID_SRC="user/hamUId.ad"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

require_file() {
    if [ ! -f "$1" ]; then
        fail_link "source file missing: $1"
        return 1
    fi
    return 0
}

for f in "$FBCDEV" "$UID_SRC"; do
    require_file "$f" || true
done
if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE cursor-decouple guard - required source file(s) missing" >&2
    exit 1
fi

# --- Link 1: CURS magic + kernel dispatcher ----------------------------------
# 'CURS' little-endian = 0x53525543 ('C'=0x43, 'U'=0x55, 'R'=0x52, 'S'=0x53).
if ! grep -Eq "FBCTL_CURS_MAGIC[[:space:]]*:[[:space:]]*uint32[[:space:]]*=[[:space:]]*0x53525543" "$FBCDEV"; then
    fail_link "link 1 (fb_cdev.ad): FBCTL_CURS_MAGIC is not defined as 0x53525543 ('CURS' LE) - kernel can't recognise the userland cursor command"
fi
if ! grep -Eq "def[[:space:]]+_fbctl_curs_command" "$FBCDEV"; then
    fail_link "link 1 (fb_cdev.ad): _fbctl_curs_command() definition is gone - the kernel CURS dispatcher is missing"
fi
if ! grep -Eq "def[[:space:]]+_fbctl_is_curs" "$FBCDEV"; then
    fail_link "link 1 (fb_cdev.ad): _fbctl_is_curs() magic recogniser is gone - devfbctl_write can no longer route CURS"
fi
# The recogniser MUST be invoked from devfbctl_write or the route is dead.
if ! grep -q "_fbctl_is_curs" "$FBCDEV"; then
    fail_link "link 1 (fb_cdev.ad): _fbctl_is_curs is never called - the CURS command is unreachable"
fi

# --- Link 2: sprite save / paint / erase / redraw primitives -----------------
for fn in _kcursor_save_under _kcursor_paint _kcursor_erase _kcursor_redraw; do
    if ! grep -Eq "def[[:space:]]+${fn}" "$FBCDEV"; then
        fail_link "link 2 (fb_cdev.ad): ${fn}() definition is gone - the kernel cursor overlay can't manage its sprite"
    fi
done

# --- Link 3: composition hook on BOTH devfb_write and _fbctl_rect_present ----
# The hook must erase BEFORE a blit and redraw AFTER, on both present paths,
# or the sprite gets overwritten / left as a ghost on slow recomposites.
if ! grep -q "_kcursor_erase" "$FBCDEV"; then
    fail_link "link 3 (fb_cdev.ad): no call to _kcursor_erase - the cursor would be overwritten by every compositor blit"
fi
if ! grep -q "_kcursor_redraw" "$FBCDEV"; then
    fail_link "link 3 (fb_cdev.ad): no call to _kcursor_redraw - the cursor would never reappear after a compositor blit"
fi
# Both BLIT paths must compose with the cursor: devfb_write (full-frame /dev/fb
# writes) AND _fbctl_rect_present (the RECT dirty-rectangle path). Without
# either hook, a slow daemon_present() taking the un-hooked path would erase
# the cursor visually.
erase_calls=$(grep -c "_kcursor_erase" "$FBCDEV" || true)
redraw_calls=$(grep -c "_kcursor_redraw" "$FBCDEV" || true)
# Erase + redraw should each appear at least 3 times: 1 definition + 2 call
# sites (devfb_write and devfbctl_write's RECT branch).
if [ "${erase_calls:-0}" -lt 3 ]; then
    fail_link "link 3 (fb_cdev.ad): _kcursor_erase is referenced only ${erase_calls:-0} times (need definition + 2 call sites: devfb_write + RECT path)"
fi
if [ "${redraw_calls:-0}" -lt 3 ]; then
    fail_link "link 3 (fb_cdev.ad): _kcursor_redraw is referenced only ${redraw_calls:-0} times (need definition + 2 call sites: devfb_write + RECT path)"
fi

# --- Link 4: userland CURS sender + mouse-pump hook --------------------------
# The userland magic constant must match the kernel byte-for-byte. A mismatch
# would silently make every CURS write a no-op verb in the kernel.
if ! grep -Eq "FBCTL_CURS_MAGIC_HUI[[:space:]]*:[[:space:]]*uint32[[:space:]]*=[[:space:]]*0x53525543" "$UID_SRC"; then
    fail_link "link 4 (hamUId.ad): FBCTL_CURS_MAGIC_HUI is not defined as 0x53525543 - the userland CURS write would not match the kernel magic"
fi
if ! grep -Eq "def[[:space:]]+kcursor_send" "$UID_SRC"; then
    fail_link "link 4 (hamUId.ad): kcursor_send() definition is gone"
fi
if ! grep -Eq "def[[:space:]]+kcursor_push_live" "$UID_SRC"; then
    fail_link "link 4 (hamUId.ad): kcursor_push_live() definition is gone"
fi
# kcursor_push_live MUST be called - and the load-bearing call site is inside
# daemon_pump_mouse so the kernel cursor advances every mouse packet.
push_calls=$(grep -c "kcursor_push_live(" "$UID_SRC" || true)
if [ "${push_calls:-0}" -lt 2 ]; then
    fail_link "link 4 (hamUId.ad): kcursor_push_live is defined but never called (found ${push_calls:-0} occurrence(s); need definition + call site)"
fi
# Verify the daemon_pump_mouse loop carries the push. We extract the function
# body (def daemon_pump_mouse up to the next top-level def) and grep inside it.
pump_body=$(awk '
    /^def[[:space:]]+daemon_pump_mouse/ { inside=1; print; next }
    /^def[[:space:]]/ { inside=0 }
    inside { print }
' "$UID_SRC")
if ! grep -q "kcursor_push_live" <<<"$pump_body"; then
    fail_link "link 4 (hamUId.ad): kcursor_push_live() is no longer called inside daemon_pump_mouse - the kernel cursor only updates at compositor-present cadence (decouple is dead)"
fi

# --- Link 5: legacy in-line overlay gates on KCURSOR_ACTIVE ------------------
# cursor_pixel_over MUST early-out when KCURSOR_ACTIVE != 0 or the sprite is
# painted TWICE (once by the kernel on the wire, once by the cached scene blit
# at the pre-pump position).
if ! grep -Eq "def[[:space:]]+cursor_pixel_over" "$UID_SRC"; then
    fail_link "link 5 (hamUId.ad): cursor_pixel_over() is gone (the legacy in-line overlay was the kernel-old fallback)"
fi
cpo_body=$(awk '
    /^def[[:space:]]+cursor_pixel_over/ { inside=1; print; next }
    /^def[[:space:]]/ { inside=0 }
    inside { print }
' "$UID_SRC")
if ! grep -q "KCURSOR_ACTIVE" <<<"$cpo_body"; then
    fail_link "link 5 (hamUId.ad): cursor_pixel_over does not gate on KCURSOR_ACTIVE - the legacy overlay still paints under the kernel sprite (duplicate cursor / stale ghost during slow presents)"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE cursor-decouple chain BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE cursor-decouple chain intact"
exit 0
