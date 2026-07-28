#!/usr/bin/env bash
#
# ON-DEMAND *AND CURRENTLY RED*: not in ci_battery_manifest.txt because it
# FAILS on 55c842b9 (2026-07-28 unregistered-gate sweep, <0.1 s). It is a
# grep-guard from 2026-06-19 that requires named handlers in the pre-scene-
# pivot app shape: _fm_apply_resize() in user/hamfmscene.ad,
# _calc_apply_resize() plus an 'r' (114) resize-event branch in
# user/hamcalcscene.ad. Those symbols are gone. Either the resize re-layout
# behaviour moved (scene-file pivot) and this gate needs rewriting against the
# new seam, or it regressed and nobody noticed for six weeks — a maximized
# window rendering into a small quadrant is exactly the bug it was written
# for, so DECIDE WHICH by driving the DE, not by reading the grep.
# scripts/test_de_resize_event_relayout.sh — structural regression guard for
# the window-resize TEAR + "maximized window renders to a small quadrant" bug
# (DE BUG 1).
#
# Fast, deterministic, grep-only (NO QEMU boot).
#
# TWO root causes, ONE fix:
#  (a) A WM geometry change (maximize / snap / free-resize) updated
#      wsys_win_w/h but never re-rasterized the per-window cache, so the
#      present path read old-width cache rows at the NEW width stride — a
#      diagonal shear. _wsys_geo_post_change() must re-rasterize at the new
#      size.
#  (b) No resize event reached the client, so it kept committing at its
#      original size. The compositor must emit "r <w> <h>" on the window's
#      event ring, and each resize-aware scene client must parse it and
#      re-layout.
#
# Pass marker:  PASS: DE resize-event re-layout intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

WSYS_SRC="sys/src/9/port/devwsys.ad"

fail=0
fail_link() { echo "FAIL: $1" >&2; fail=1; }

[ -f "$WSYS_SRC" ] || { echo "FAIL: $WSYS_SRC missing" >&2; exit 1; }

# --- LINK 1: compositor emits an 'r <w> <h>' resize event ----------------
# 'r' is ASCII 114. The emitter pushes byte 114 then the w/h decimals.
if ! grep -qE 'def _wsys_evt_emit_resize' "$WSYS_SRC"; then
    fail_link "link 1: _wsys_evt_emit_resize() (resize-event emitter) missing"
fi
if ! awk '/^def _wsys_evt_emit_resize/{f=1} /^def /{if(f && $0 !~ /_wsys_evt_emit_resize/)f=0} f' "$WSYS_SRC" \
        | grep -qE '_wsys_evt_push_byte\(wid, 114\)'; then
    fail_link "link 1: resize emitter does not push the 'r' (114) event type byte"
fi

# --- LINK 2: a geometry change re-rasterizes + emits the resize event ----
if ! grep -qE 'def _wsys_geo_post_change' "$WSYS_SRC"; then
    fail_link "link 2: _wsys_geo_post_change() (re-raster + notify) missing"
fi
geo_body=$(awk '/^def _wsys_geo_post_change/{f=1} /^def /{if(f && $0 !~ /_wsys_geo_post_change/)f=0} f' "$WSYS_SRC")
if ! printf '%s\n' "$geo_body" | grep -qE '_wsys_rasterize_window'; then
    fail_link "link 2: geo-change does not re-rasterize the cache at the new size (shear will return)"
fi
if ! printf '%s\n' "$geo_body" | grep -qE '_wsys_evt_emit_resize'; then
    fail_link "link 2: geo-change does not emit the resize event"
fi

# --- LINK 3: the WM paths invoke the geo-change hook ---------------------
# _wsys_apply_geo (maximize/snap/restore) and the free-resize drag must call it.
apply_body=$(awk '/^def _wsys_apply_geo/{f=1} /^def /{if(f && $0 !~ /_wsys_apply_geo/)f=0} f' "$WSYS_SRC")
if ! printf '%s\n' "$apply_body" | grep -qE '_wsys_geo_post_change'; then
    fail_link "link 3: _wsys_apply_geo does not call _wsys_geo_post_change (maximize/snap tear)"
fi

# --- LINK 4: resize-aware clients parse the 'r' event --------------------
# Terminal, file manager and editor must each parse the 'r' resize line.
declare -A CLIENT_FN=(
    [user/hamtermscene.ad]="_term_apply_resize"
    [user/hamfmscene.ad]="_fm_apply_resize"
    [user/hameditscene.ad]="_ed_apply_resize"
    [user/hamcalcscene.ad]="_calc_apply_resize"
)
for src in "${!CLIENT_FN[@]}"; do
    fn="${CLIENT_FN[$src]}"
    [ -f "$src" ] || { fail_link "link 4: $src missing"; continue; }
    if ! grep -qE "def ${fn}" "$src"; then
        fail_link "link 4: $src has no resize handler ${fn}()"
    fi
    # Must open the /event file and react to the 'r' (114) type byte.
    if ! grep -qE '"/event"' "$src"; then
        fail_link "link 4: $src does not open its /event file for resize notifications"
    fi
    if ! grep -qE '114' "$src"; then
        fail_link "link 4: $src does not test the 'r' (114) resize event type"
    fi
done

if [ "$fail" = "0" ]; then
    echo "PASS: DE resize-event re-layout intact"
    exit 0
fi
echo "FAIL: DE resize-event re-layout regressed" >&2
exit 1
