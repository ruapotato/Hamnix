#!/usr/bin/env bash
#
# ON-DEMAND *AND CURRENTLY RED*: not in ci_battery_manifest.txt because it
# FAILS on 55c842b9 (2026-07-28 unregistered-gate sweep, <0.1 s). Grep-guard
# from 2026-06-19; the missing pieces it reports are hamcalc keyboard mappings
# ('+' 43, '=' 61) and hamedit's Save-As prompt (_commit_save_as, the prompting
# modal state, Ctrl-S-with-no-file entering the prompt). Those are USER-VISIBLE
# features, so this is more likely lost behaviour than a rename — verify by
# using the app before assuming gate rot.
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

CALC="user/hamcalcscene.ad"
EDIT="user/hameditscene.ad"
WSYS="sys/src/9/port/devwsys.ad"

fail=0
fail_link() { echo "FAIL: $1" >&2; fail=1; }

for f in "$CALC" "$EDIT" "$WSYS"; do
    [ -f "$f" ] || { echo "FAIL: $f missing" >&2; exit 1; }
done

# helper: extract a def's body (from "def NAME" to the next top-level "def ").
defbody() { awk -v n="$1" '$0 ~ "^def " n "\\(" {f=1} /^def /{if(f && $0 !~ "^def " n "\\(")f=0} f' "$2"; }

# === BUG #4: calc resize wired into the event loop ========================
mainbody="$(defbody main "$CALC")"
# The main loop must actually CALL the resize parser (not just define it).
if ! grep -qE '_calc_resize_line' "$CALC"; then
    fail_link "bug4: calc has no _calc_resize_line resize parser"
fi
if ! printf '%s\n' "$mainbody" | grep -qE '_calc_resize_line'; then
    fail_link "bug4: calc main loop never CALLS _calc_resize_line (resize dead code)"
fi
# emit_scene background fill must use the live calc_w/calc_h, not fixed dims.
emitbody="$(defbody emit_scene "$CALC")"
if ! printf '%s\n' "$emitbody" | grep -qE 'hamscene_fill\(0, 0, calc_w, calc_h'; then
    fail_link "bug4: emit_scene background fill not sized to calc_w/calc_h (black quadrant returns)"
fi

# === BUG #5: calc keyboard ================================================
if ! grep -qE '"/keys"' "$CALC"; then
    fail_link "bug5: calc does not open its /keys stream"
fi
if ! grep -qE 'def _press_kbd' "$CALC"; then
    fail_link "bug5: calc has no _press_kbd keyboard mapping"
fi
if ! printf '%s\n' "$mainbody" | grep -qE '_calc_key_line'; then
    fail_link "bug5: calc main loop never drains /keys via _calc_key_line"
fi
# Sanity: the mapping handles a digit (48..57), '+' (43) and '=' (61).
kbdbody="$(defbody _press_kbd "$CALC")"
for code in 'c >= 48 and c <= 57' 'c == 43' 'c == 61'; do
    if ! printf '%s\n' "$kbdbody" | grep -qF "$code"; then
        fail_link "bug5: _press_kbd missing key mapping ($code)"
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

# === BUG #8: hamedit Save-As prompt =======================================
if ! grep -qE 'def _commit_save_as' "$EDIT"; then
    fail_link "bug8: hamedit has no _commit_save_as (Save-As prompt commit)"
fi
if ! grep -qE 'prompting' "$EDIT"; then
    fail_link "bug8: hamedit has no prompting modal state"
fi
# Ctrl-S (code 19) with no file must OPEN the prompt, not dead-end.
csbody="$(defbody _handle_code "$EDIT")"
if ! printf '%s\n' "$csbody" | grep -qE 'has_file == 0'; then
    fail_link "bug8: Ctrl-S does not branch on missing filename (no Save-As)"
fi
if ! printf '%s\n' "$csbody" | grep -qE 'prompting = 1'; then
    fail_link "bug8: Ctrl-S with no file does not enter the Save-As prompt"
fi
# The Save-As prompt field must be rendered.
if ! printf '%s\n' "$editemit" | grep -qiE 'Save As'; then
    fail_link "bug8: emit_scene does not render the 'Save As:' input field"
fi

if [ "$fail" = "0" ]; then
    echo "PASS: DE scene calc+edit features intact"
    exit 0
fi
echo "FAIL: DE scene calc+edit features regressed" >&2
exit 1
