#!/usr/bin/env bash
# scripts/test_de_damage_clip.sh - structural regression guard for the
# DE perf P0-B damage-clipping (drag / move / resize / menu) win.
#
# Background. Before this guard, every motion packet during a window
# drag / rubber-band sweep / resize / open-menu state escalated to
# damage_full() in daemon_frame, which forced daemon_present() to call
# scene_build_full() — the ~1267-line per-pixel daemon_pixel cascade
# over the WHOLE framebuffer. That threw out the #410 SCENE_CACHE every
# interactive frame. The user saw drag/menu tracking collapse to ~0.5 Hz
# while the still-desktop mouse stayed snappy.
#
# The P0-B fix in user/hamUId.ad:
#   1. The MOUSE_SCENE_DIRTY-driven damage_full() in daemon_frame is
#      replaced by per-state damage_*_old_new() routes (move / resize
#      / rubber-band / popup-union); damage_full survives ONLY as a
#      safety fallback for unrecognised dirty-causes.
#   2. The rubber-band edge test that used to run for every screen
#      pixel inside daemon_pixel is HOISTED OUT into a tiny
#      scene_blit_rect_outline() overlay called after the cached
#      scene rect is blitted. The outline lives ONLY on scanout —
#      never in SCENE_CACHE — so SCENE_CACHE stays valid across
#      interactive frames.
#   3. The per-state bbox helpers (rb_bbox, move_bbox, resize_bbox,
#      popup_bbox) compute (prev-frame, current-frame) bboxes which
#      damage_rect unions into the frame's damage accumulator. The
#      previous bbox covers the trailing-edge area that has to be
#      repainted with the underlay.
#
# This is a fast, deterministic, grep-only guard (NO QEMU boot).
#
# 2026-07-31 -- WHY THIS FILE USES HERESTRINGS, NOT `echo ... | grep`.
# Links 3, 4 and 5 used to pipe an extracted function body into `grep -q`.
# `grep -q` exits the instant it matches; with a 16.9 KB body and the match near
# the TOP, the upstream `echo` then dies of SIGPIPE, and `set -o pipefail` makes
# the whole pipeline report 141. So the pipeline reported FAILURE precisely when
# the pattern WAS present:
#
#   link 4  `if ! echo "$frame_body" | grep -q "$hook"`  -> false RED
#           (all four hooks present in daemon_frame, all four reported missing)
#   link 3  `if echo "$pixel_body" | grep -q "imin(DRAG_X0"` -> latent false
#           GREEN. Same construct, inverted sense: a 141 reads as "pattern
#           absent", so the forbidden per-pixel test could come back and this
#           link would say nothing. Measured on this tree it does NOT misfire
#           yet -- daemon_pixel's body is 9147 bytes and the pipeline returns 0
#           cleanly, whereas daemon_frame's 16901-byte body returns 141 ten
#           times out of ten. The hazard is a function of body size, so link 3
#           was one refactor away from silently going blind. That is the worse
#           of the two failure modes and it is why this was worth fixing
#           properly rather than just unbreaking link 4.
#
# The gate stayed green for as long as grep happened to drain the pipe before
# exiting. Code motion inside daemon_frame moved the damage_*_old_new calls
# nearer the top, grep started matching (and exiting) early, and the gate turned
# red. The rc=141 was structural and reproducible on an IDLE host -- not the
# loaded-host SIGPIPE flake it looked like.
#
# A herestring is not a pipeline: there is no upstream process to kill, so
# grep's early exit is harmless and `pipefail` has nothing to poison. Do not
# reintroduce `echo "$body" | grep` here.
#
# Pass marker:  PASS: DE damage-clip / rubber-band hoist intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UID_SRC="user/hamUId.ad"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

if [ ! -f "$UID_SRC" ]; then
    echo "FAIL: $UID_SRC missing" >&2
    exit 1
fi

# --- Link 1: per-state damage helpers + bbox builders exist ----------------
for fn in rb_bbox move_bbox resize_bbox popup_bbox \
          damage_rb_old_new damage_move_old_new damage_resize_old_new \
          damage_popup_old_new; do
    if ! grep -Eq "def[[:space:]]+${fn}[[:space:]]*\(" "$UID_SRC"; then
        fail_link "link 1 (hamUId.ad): ${fn}() definition is gone - the per-state damage-clip helper is missing"
    fi
done

# --- Link 2: rubber-band outline overlay exists (hoisted out of daemon_pixel) ---
if ! grep -Eq "def[[:space:]]+scene_blit_rect_outline[[:space:]]*\(" "$UID_SRC"; then
    fail_link "link 2 (hamUId.ad): scene_blit_rect_outline() is gone - rubber-band overlay can't paint without running daemon_pixel's per-pixel cascade"
fi
# The outline must be invoked after the present — wired through
# post_present_overlays() (called from daemon_flush_damage).
if ! grep -Eq "def[[:space:]]+post_present_overlays[[:space:]]*\(" "$UID_SRC"; then
    fail_link "link 2 (hamUId.ad): post_present_overlays() is gone - the scene_blit_rect_outline call site is unwired"
fi
ppo_calls=$(grep -c "post_present_overlays(" "$UID_SRC" || true)
if [ "${ppo_calls:-0}" -lt 2 ]; then
    fail_link "link 2 (hamUId.ad): post_present_overlays is defined but only called ${ppo_calls:-0} time(s); expected definition + at least one call from daemon_flush_damage"
fi

# --- Link 3: rubber-band edge test REMOVED from daemon_pixel ---------------
# The old per-pixel cascade tested `if x == rx0 or x == rx1 or y == ry0 or y == ry1`
# against the rubber-band coords inside daemon_pixel; that's the hot-path
# the P0-B fix kills. Extract daemon_pixel's body and assert the test is gone.
pixel_body=$(awk '
    /^def[[:space:]]+daemon_pixel[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$UID_SRC")
# A signature snippet of the OLD inline test: `imin(DRAG_X0, CUR_X)` only
# ever appears inside the rubber-band per-pixel test in daemon_pixel.
if grep -q "imin(DRAG_X0" <<<"$pixel_body"; then
    fail_link "link 3 (hamUId.ad): rubber-band coord computation (imin(DRAG_X0, ...)) is STILL inside daemon_pixel - the per-pixel edge-test wasn't hoisted out"
fi
# And the DRAG_ACTIVE-gated outline branch must be gone from daemon_pixel.
if grep -qE "^[[:space:]]+if[[:space:]]+DRAG_ACTIVE" <<<"$pixel_body"; then
    fail_link "link 3 (hamUId.ad): a DRAG_ACTIVE branch survives in daemon_pixel - the rubber-band paint still runs per-pixel"
fi

# --- Link 4: daemon_frame uses damage_*_old_new on the interactive routes ---
frame_body=$(awk '
    /^def[[:space:]]+daemon_frame[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$UID_SRC")
for hook in damage_move_old_new damage_resize_old_new \
            damage_rb_old_new damage_popup_old_new; do
    if ! grep -q "$hook" <<<"$frame_body"; then
        fail_link "link 4 (hamUId.ad): daemon_frame does NOT call $hook - interactive damage is not being clipped"
    fi
done

# --- Link 5: the OLD damage_full() escalation on MOUSE_SCENE_DIRTY is GONE ---
# The pre-P0B daemon_frame had a top-level "if MOUSE_SCENE_DIRTY != 0:
# damage_full()" immediately after MOUSE_SCENE_DIRTY = 0. After P0B, the
# MOUSE_SCENE_DIRTY branch must route through per-state helpers; damage_full
# only fires as a fallback inside that branch (when no state matched), NOT
# unconditionally.
# Heuristic: extract the block after `if MOUSE_SCENE_DIRTY != 0:` from the
# frame body and assert it contains at least one damage_*_old_new call
# before damage_full.
msdb=$(awk '
    /if[[:space:]]+MOUSE_SCENE_DIRTY[[:space:]]*!=[[:space:]]*0/ { inside=1; out=""; next }
    inside && /MOUSE_SCENE_DIRTY[[:space:]]*=[[:space:]]*0/ { print out; exit }
    inside { out = out $0 "\n" }
' <<<"$frame_body")
if ! grep -q "damage_.*_old_new" <<<"$msdb"; then
    fail_link "link 5 (hamUId.ad): MOUSE_SCENE_DIRTY branch in daemon_frame still escalates straight to damage_full - per-state damage-clip not wired"
fi

# --- Link 6: previous-frame bbox state globals exist -----------------------
for sym in PREV_RB_VALID PREV_MOVE_VALID PREV_RESIZE_VALID PREV_POPUP_VALID; do
    if ! grep -Eq "^${sym}[[:space:]]*:" "$UID_SRC"; then
        fail_link "link 6 (hamUId.ad): ${sym} global is missing - cross-frame bbox tracking is broken"
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE damage-clip / rubber-band hoist BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE damage-clip / rubber-band hoist intact"
exit 0
