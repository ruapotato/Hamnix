#!/usr/bin/env bash
#
# VERDICT 2026-07-28: GATE ROT, NOT lost behaviour — in BOTH directions the
# sweep flagged. The hamcalc keyboard mappings ('+' 43, '=' 61, digits) were
# never lost: 26675f57 made the calculator dual-target and moved _press_kbd
# and friends into lib/hamcalccore.ad, where all of them still are. hamedit's
# Save-As was not lost either, it was UPGRADED — the bespoke bottom-line
# "Save As:" prompt (_commit_save_as + a `prompting` flag) was replaced by
# the SHARED lib/filepick.ad folder-browsing dialog, which is the "GTK-like
# Save As for all apps" the user asked for. Ctrl-S with no filename still
# opens a real chooser instead of dead-ending. Rewritten against both new
# seams; every original requirement is still asserted, and the everyday-
# calculator keys plus the chooser's commit path are now asserted too.
# scripts/test_de_scene_calc_edit_features.sh
#
# Fast, deterministic, grep-only (NO QEMU boot) structural regression guard
# for the scene-DE calculator + editor feature fixes landed in the DE
# bug-fix wave:
#
#   BUG #4  calculator: resize re-layout actually WIRED into the event loop
#           (the handler existed but was never called) + background fill
#           tracks the current size (no black quadrant).
#   BUG #5  calculator: keyboard input — opens /keys, maps digits/ops/=/clear.
#   BUG #6  hamedit: soft-wrap long logical lines into multiple visual rows.
#   BUG #7  hamedit fast-type: the kernel keys ring is large enough not to
#           overflow under a burst (WSYS_KEYS_SIZE >= 4096).
#   BUG #8  hamedit: Ctrl-S with no filename opens a real Save-As prompt
#           (not a dead-end "no filename" message).
#
# These are LOAD-BEARING and silently regressable (a refactor of the event
# loop could drop the keys read, the wrap walk could revert to a clip, the
# ring could shrink). Each link is a grep over the source so the guard runs
# in milliseconds and never flakes on the DE serial flood.
#
# Pass marker:  PASS: DE scene calc+edit features intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

CALC="user/hamcalcscene.ad"        # native wsys TRANSPORT only (dual-target split)
CALCCORE="lib/hamcalccore.ad"      # arithmetic + keypad + layout + input handlers
EDIT="user/hameditscene.ad"
PICK="lib/filepick.ad"             # the SHARED GTK-style file dialog
WSYS="sys/src/9/port/devwsys.ad"

fail=0
fail_link() { echo "FAIL: $1" >&2; fail=1; }

for f in "$CALC" "$CALCCORE" "$EDIT" "$PICK" "$WSYS"; do
    [ -f "$f" ] || { echo "FAIL: $f missing" >&2; exit 1; }
done

# helper: extract a def's body (from "def NAME" to the next top-level "def ").
defbody() { awk -v n="$1" '$0 ~ "^def " n "\\(" {f=1} /^def /{if(f && $0 !~ "^def " n "\\(")f=0} f' "$2"; }

# === BUG #4: calc resize wired into the event loop ========================
# NOTE (2026-07-28): the calculator is now DUAL-TARGET. 26675f57 factored the
# arithmetic/keypad state machine, resize-aware layout, scene builder and the
# pure keyboard+pointer handlers out of user/hamcalcscene.ad into the
# extern-free lib/hamcalccore.ad so they also run (and are gated) on the dev
# host; the native app keeps ONLY the wsys transport. So the resize/keyboard
# links live in the CORE, and the "is it wired?" links live in the TRANSPORT.
mainbody="$(defbody main "$CALC")"
# The core must own the resize-line parser + the apply handler ...
if ! grep -qE 'def hamcalc_resize_line' "$CALCCORE"; then
    fail_link "bug4: $CALCCORE has no hamcalc_resize_line resize parser"
fi
if ! grep -qE 'def _calc_apply_resize' "$CALCCORE"; then
    fail_link "bug4: $CALCCORE has no _calc_apply_resize re-layout handler"
fi
if ! printf '%s\n' "$(defbody hamcalc_resize_line "$CALCCORE")" \
        | grep -qE '_calc_apply_resize\('; then
    fail_link "bug4: hamcalc_resize_line never applies the resize (dead code)"
fi
# ... and the native main loop must actually CALL it (not just link it).
if ! printf '%s\n' "$mainbody" | grep -qE 'hamcalc_resize_line'; then
    fail_link "bug4: calc main loop never CALLS hamcalc_resize_line (resize dead code)"
fi
# The scene background fill must use the live calc_w/calc_h, not fixed dims.
emitbody="$(defbody hamcalc_build_scene "$CALCCORE")"
if ! printf '%s\n' "$emitbody" | grep -qE 'hamscene_fill\(0, 0, calc_w, calc_h'; then
    fail_link "bug4: hamcalc_build_scene background fill not sized to calc_w/calc_h (black quadrant returns)"
fi

# === BUG #5: calc keyboard ================================================
if ! grep -qE '"/keys"' "$CALC"; then
    fail_link "bug5: calc does not open its /keys stream"
fi
if ! grep -qE 'def _press_kbd' "$CALCCORE"; then
    fail_link "bug5: $CALCCORE has no _press_kbd keyboard mapping"
fi
if ! grep -qE 'def hamcalc_key_line' "$CALCCORE"; then
    fail_link "bug5: $CALCCORE has no hamcalc_key_line /keys line parser"
fi
if ! printf '%s\n' "$mainbody" | grep -qE 'hamcalc_key_line'; then
    fail_link "bug5: calc main loop never drains /keys via hamcalc_key_line"
fi
# Sanity: the mapping handles a digit (48..57), '+' (43) and '=' (61).
kbdbody="$(defbody _press_kbd "$CALCCORE")"
for code in 'c >= 48 and c <= 57' 'c == 43' 'c == 61'; do
    if ! printf '%s\n' "$kbdbody" | grep -qF "$code"; then
        fail_link "bug5: _press_kbd missing key mapping ($code)"
    fi
done
# The everyday-calculator keys (5639686e) ride the same mapping: '.' (46),
# '%' (37) and backspace (8) must not silently drop out of it again.
for code in 'c == 46' 'c == 37' 'c == 8'; do
    if ! printf '%s\n' "$kbdbody" | grep -qF "$code"; then
        fail_link "bug5: _press_kbd missing everyday-calculator key mapping ($code)"
    fi
done

# === BUG #6: hamedit soft-wrap ============================================
# The renderer must walk VISUAL rows (wrap) — the wrap helper + a VIS_COLS
# wrap check in emit_scene. A revert to a hard clip would drop these.
if ! grep -qE 'def _visual_row_of' "$EDIT"; then
    fail_link "bug6: hamedit has no _visual_row_of (wrap-aware scroll) helper"
fi
editemit="$(defbody emit_scene "$EDIT")"
if ! printf '%s\n' "$editemit" | grep -qE 'rl < VIS_COLS'; then
    fail_link "bug6: hamedit emit_scene does not wrap at VIS_COLS (long lines clipped)"
fi
if ! printf '%s\n' "$editemit" | grep -qE 'vrow'; then
    fail_link "bug6: hamedit emit_scene not rendering in visual-row space (no wrap)"
fi

# === BUG #7: keys ring large enough =======================================
ring="$(grep -oE 'WSYS_KEYS_SIZE: *uint64 *= *[0-9]+' "$WSYS" | grep -oE '[0-9]+$' | head -1)"
if [ -z "$ring" ]; then
    fail_link "bug7: WSYS_KEYS_SIZE not found in $WSYS"
elif [ "$ring" -lt 4096 ]; then
    fail_link "bug7: WSYS_KEYS_SIZE=$ring < 4096 (fast-type burst can overflow + drop keys)"
fi
# The backing buffer must be >= 32 * WSYS_KEYS_SIZE.
buf="$(grep -oE 'wsys_keys_buf: *Array\[[0-9]+' "$WSYS" | grep -oE '[0-9]+$' | head -1)"
if [ -n "$ring" ] && [ -n "$buf" ] && [ "$buf" -lt $((32 * ring)) ]; then
    fail_link "bug7: wsys_keys_buf ($buf) < 32 * WSYS_KEYS_SIZE ($((32 * ring)))"
fi

# === BUG #8: hamedit Save-As ==============================================
# NOTE (2026-07-28): the original fix was a bespoke bottom-line "Save As:"
# text prompt (_commit_save_as + a `prompting` modal flag). That was
# UPGRADED, not lost: the prompt was replaced by the SHARED lib/filepick.ad
# dialog — the real folder-browsing file chooser every app now raises — which
# is what the user asked for ("a GTK-like Save As for all apps"). The
# requirement is unchanged and asserted in full: Ctrl-S with no filename must
# open a real Save-As chooser rather than dead-ending on a "no filename"
# message. Only the mechanism it is asserted against moved.
if ! grep -qE 'def _ed_pop_picker' "$EDIT"; then
    fail_link "bug8: hamedit has no _ed_pop_picker (raises the shared Save-As dialog)"
fi
if ! grep -qE 'def _ed_apply_pick' "$EDIT"; then
    fail_link "bug8: hamedit has no _ed_apply_pick (a committed pick never saves)"
fi
if ! grep -qE 'from lib\.filepick import' "$EDIT"; then
    fail_link "bug8: hamedit does not use the SHARED lib/filepick.ad dialog"
fi
if ! grep -qE 'def filepick_open' "$PICK" || ! grep -qE '^FILEPICK_SAVE' "$PICK"; then
    fail_link "bug8: lib/filepick.ad has no filepick_open()/FILEPICK_SAVE mode"
fi
# Ctrl-S (code 19) with no file must OPEN the chooser in SAVE mode, not
# dead-end. This is the exact regression the link was written for, so it is
# scoped to the `code == 19` ARM ONLY: grepping the whole _handle_code body
# lets the unrelated Ctrl-W ("Save As" on an already-named buffer) arm
# satisfy the check, and a Ctrl-S that dead-ends on "no filename" then slips
# through green — verified by mutation, 2026-07-28.
csbody="$(defbody _handle_code "$EDIT")"
ctrls_arm="$(printf '%s\n' "$csbody" \
    | awk '/^    if code == 19:/{f=1;print;next} /^    if code ==/{f=0} f')"
if [ -z "$ctrls_arm" ]; then
    fail_link "bug8: no Ctrl-S (code 19) arm in _handle_code"
fi
if ! printf '%s\n' "$ctrls_arm" | grep -qE 'has_file == 0'; then
    fail_link "bug8: Ctrl-S does not branch on missing filename (no Save-As)"
fi
if ! printf '%s\n' "$ctrls_arm" | grep -qE '_ed_pop_picker\(FILEPICK_SAVE\)'; then
    fail_link "bug8: Ctrl-S with no file does not raise the Save-As chooser (dead-end)"
fi
# Ctrl-W = always-available "Save As" even when the buffer already has a name.
if ! printf '%s\n' "$csbody" | grep -qE 'code == 23'; then
    fail_link "bug8: no Ctrl-W always-available Save As binding"
fi
# The modal must be RENDERED while active, and must own the keyboard while up.
if ! printf '%s\n' "$editemit" | grep -qE 'filepick_active\(\)'; then
    fail_link "bug8: emit_scene does not render the Save-As chooser overlay"
fi
if ! printf '%s\n' "$csbody" | grep -qE 'filepick_handle_code'; then
    fail_link "bug8: the Save-As chooser does not take the keyboard while open"
fi
if ! grep -qE 'filepick_take_result' "$EDIT"; then
    fail_link "bug8: hamedit never collects the chooser result (Save-As never completes)"
fi

if [ "$fail" = "0" ]; then
    echo "PASS: DE scene calc+edit features intact"
    exit 0
fi
echo "FAIL: DE scene calc+edit features regressed" >&2
exit 1
