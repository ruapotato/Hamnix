#!/usr/bin/env bash
#
# VERDICT 2026-07-28: GATE ROT, NOT lost behaviour. The 2026-07-28 sweep red
# was link 4 only, and it was looking in the wrong FILES. The hamUI
# dual-target split (26675f57) moved each app's layout + input state machine
# into an extern-free lib/*core.ad, leaving only the wsys transport in
# user/*scene.ad — so _calc_apply_resize() is alive and well in
# lib/hamcalccore.ad (called from hamcalc_resize_line, which the native
# transport feeds every /event line), and the file manager's handler is
# _parse_resize() + an inline fm_w/fm_h + fmc_set_geometry() apply. All four
# clients parse 'r' (114) and re-layout; nothing regressed. Rewritten to
# assert transport and core separately, and to require that each apply
# handler is actually CALLED, which is the failure the gate exists for
# (re-layout present but dead = maximized window paints a small quadrant).
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
# Terminal, file manager, editor and calculator must each parse the 'r'
# resize line and re-layout from it.
#
# The apps are no longer single files. The hamUI dual-target split
# (26675f57 and friends) moved each app's layout + input state machine into
# an extern-free lib/*core.ad so it can also run on the dev host, leaving
# ONLY the wsys transport (open /event, read it) in user/*scene.ad. So the
# two halves are asserted separately: TRANSPORT must open /event, CORE must
# own the 'r' (114) parse and the apply handler. Checking both in one file
# is what made this gate red for six weeks on a tree that was fine.
#
# label | transport (opens /event) | core (parses 114 + applies) | apply fn
CLIENTS=(
    "terminal|user/hamtermscene.ad|user/hamtermscene.ad|_term_apply_resize"
    "filemgr|user/hamfmscene.ad|user/hamfmscene.ad|_parse_resize"
    "editor|user/hameditscene.ad|user/hameditscene.ad|_ed_apply_resize"
    "calculator|user/hamcalcscene.ad|lib/hamcalccore.ad|_calc_apply_resize"
)
for row in "${CLIENTS[@]}"; do
    IFS='|' read -r label transport core fn <<<"$row"
    for f in "$transport" "$core"; do
        [ -f "$f" ] || { fail_link "link 4 ($label): $f missing"; continue 2; }
    done
    # TRANSPORT: must open the window's /event file for resize notifications.
    if ! grep -qE '"/event"' "$transport"; then
        fail_link "link 4 ($label): $transport does not open its /event file for resize notifications"
    fi
    # CORE: must own the resize handler ...
    if ! grep -qE "def ${fn}\b" "$core"; then
        fail_link "link 4 ($label): $core has no resize handler ${fn}()"
    fi
    # ... and dispatch on the 'r' (114) event-type byte.
    if ! grep -qE '(!=|==) *114|\[0\] *(!=|==) *114' "$core"; then
        fail_link "link 4 ($label): $core does not test the 'r' (114) resize event type"
    fi
    # The parse must be WIRED: some function in the core has to actually call
    # the apply handler, else the re-layout is dead code (the exact shape of
    # the original DE BUG 1 — a maximized window painting a small quadrant).
    if [ "$(grep -cE "\b${fn}\(" "$core")" -lt 2 ]; then
        fail_link "link 4 ($label): ${fn}() is defined but never called in $core (resize re-layout is dead code)"
    fi
done
# The calculator's core is reached through a public wrapper the native
# transport drains /event into; assert that seam explicitly since it spans
# the two files.
if ! grep -qE 'def hamcalc_resize_line' lib/hamcalccore.ad; then
    fail_link "link 4 (calculator): lib/hamcalccore.ad has no hamcalc_resize_line() public resize seam"
fi
if ! grep -qE 'hamcalc_resize_line\(' user/hamcalcscene.ad; then
    fail_link "link 4 (calculator): user/hamcalcscene.ad never feeds /event lines to hamcalc_resize_line (resize dead)"
fi

if [ "$fail" = "0" ]; then
    echo "PASS: DE resize-event re-layout intact"
    exit 0
fi
echo "FAIL: DE resize-event re-layout regressed" >&2
exit 1
