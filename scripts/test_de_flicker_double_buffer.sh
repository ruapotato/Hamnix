#!/usr/bin/env bash
# scripts/test_de_flicker_double_buffer.sh
#
# Fast, deterministic, grep-only (NO QEMU boot) structural regression guard
# for the DE FLICKER KEYSTONE: the offscreen double-buffer present shadow.
#
# The compositor composites into a screen-sized offscreen RAM shadow and
# copies each finished damage rect to scanout in ONE pass (fb_present_flush),
# so a frame is never visible half-drawn. The shadow is installed via
# fb_set_shadow() and lazily allocated at WSYS_SHADOW_ORDER from the buddy
# allocator.
#
# THE TRAP THIS GUARD EXISTS FOR: alloc_pages() refuses any order > MAX_ORDER
# (10 = 4 MiB). The first WIP set WSYS_SHADOW_ORDER=12, so alloc_pages(12)
# returned 0, the shadow NEVER installed, and the entire double-buffer was a
# SILENT NO-OP (flicker returns, every gate still green because direct-scanout
# fallback is correct, just torn). This guard asserts the order stays within
# MAX_ORDER so the shadow can actually allocate.
#
# Pass marker:  PASS: DE flicker double-buffer intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

WSYS="sys/src/9/port/devwsys.ad"
FBT="drivers/video/console/fb_text.ad"
PALLOC="mm/page_alloc.ad"

fail=0
fail_link() { echo "FAIL: $1" >&2; fail=1; }

for f in "$WSYS" "$FBT" "$PALLOC"; do
    [ -f "$f" ] || { echo "FAIL: $f missing" >&2; exit 1; }
done

# --- LINK 1: fb_text provides the shadow present API ----------------------
for sym in fb_set_shadow fb_present_flush fb_shadow_active; do
    if ! grep -qE "def ${sym}" "$FBT"; then
        fail_link "link1: fb_text missing shadow API ${sym}()"
    fi
done
# The RGBA row present must route into the shadow when one is installed.
if ! grep -qE 'fb_shadow_base != 0' "$FBT"; then
    fail_link "link1: fb_present_rgba_row does not write into the shadow buffer"
fi

# --- LINK 2: compositor installs + flushes the shadow ---------------------
if ! grep -qE 'def _wsys_shadow_init_if_needed' "$WSYS"; then
    fail_link "link2: compositor has no _wsys_shadow_init_if_needed (shadow never installed)"
fi
if ! grep -qE 'def _wsys_flush_rect' "$WSYS"; then
    fail_link "link2: compositor has no _wsys_flush_rect (damage never pushed to scanout)"
fi
if ! grep -qE 'fb_set_shadow' "$WSYS"; then
    fail_link "link2: compositor never calls fb_set_shadow"
fi

# --- LINK 3: the shadow order is allocatable (<= MAX_ORDER) ----------------
# THE keystone-was-inert guard.
maxorder="$(grep -oE 'MAX_ORDER: *int32 *= *[0-9]+' "$PALLOC" | grep -oE '[0-9]+$' | head -1)"
shorder="$(grep -oE 'WSYS_SHADOW_ORDER: *int32 *= *[0-9]+' "$WSYS" | grep -oE '[0-9]+$' | head -1)"
if [ -z "$maxorder" ]; then
    fail_link "link3: could not read MAX_ORDER from $PALLOC"
fi
if [ -z "$shorder" ]; then
    fail_link "link3: could not read WSYS_SHADOW_ORDER from $WSYS"
fi
if [ -n "$maxorder" ] && [ -n "$shorder" ] && [ "$shorder" -gt "$maxorder" ]; then
    fail_link "link3: WSYS_SHADOW_ORDER=$shorder > MAX_ORDER=$maxorder — alloc_pages returns 0, shadow NEVER installs (flicker keystone INERT)"
fi

# --- LINK 4: the full-screen present flushes the whole frame after compositing
presentbody="$(awk '/^def _wsys_scene_present_locked/{f=1} /^def /{if(f && $0 !~ /_wsys_scene_present_locked/)f=0} f' "$WSYS")"
if ! grep -qE '_wsys_flush_rect' <<<"$presentbody"; then
    fail_link "link4: _wsys_scene_present_locked does not flush the composited frame to scanout"
fi

if [ "$fail" = "0" ]; then
    echo "PASS: DE flicker double-buffer intact"
    exit 0
fi
echo "FAIL: DE flicker double-buffer regressed" >&2
exit 1
