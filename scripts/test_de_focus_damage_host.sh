#!/usr/bin/env bash
# scripts/test_de_focus_damage_host.sh - regression guard for the DE
# focus-change titlebar repaint (user-reported 2026-07-19).
#
# THE BUG. When a window lost focus, its title bar was supposed to repaint
# immediately to the muted (unfocused) grey style. Instead the newly-unfocused
# window kept its stale ACTIVE (blue) title bar in the #410 SCENE_CACHE: only
# the cursor's small save-under region regreyed as the pointer passed over it,
# so the user saw "the grey header doesn't redraw until you mouse over it, and
# then only updates AROUND the mouse". The old devwsys-era compositor had a
# focus-repaint (commit 8e984dc3) but it was never carried into the pivoted
# user/hamUId.ad scene compositor.
#
# THE FIX (user/hamUId.ad, daemon_frame). The front-most window is the focused
# one and wears the active title-bar; every other window wears the grey. We
# track the focused window's UID across frames (EVL_LAST_FOCUS_UID) and, on a
# transition, damage_window() BOTH the window that lost focus AND the one that
# gained it — marking each content-dirty so its backbuffer refills with the
# correct focus chrome. This covers every focus-change path (click/raise,
# spawned window, close/minimise promoting a new front, workspace switch).
#
# This is a fast, deterministic, grep+compile guard (NO QEMU boot).
#
# GATE HYGIENE (2026-07-31). Links 2 and 3 used to be spelled
#     echo "$frame_body" | grep -Eq ...
# under `set -o pipefail`. `grep -q` exits the instant it matches, closing the
# pipe under the still-writing `echo`; `echo` then dies of SIGPIPE (141) and
# pipefail promotes that to the pipeline's exit status, so a MATCHING
# assertion reported FAILURE. Measured ~1.5% per grep, ~6% per gate run and
# markedly worse under host load - it manufactured a red that no tree change
# could explain, and could only ever hit these four `grep -q` links (link 1
# greps a file directly; link 3's counter uses `grep -c`, which drains its
# input and so never SIGPIPEs the writer). Every assertion now greps a
# materialised temp FILE: no pipeline, no race. Do not reintroduce
# `echo ... | grep -q` here.
#
# Pass marker:  PASS: DE focus-change titlebar repaint intact
# Fail marker:  FAIL: <which link broke>

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UID_SRC="user/hamUId.ad"
fail=0
fail_link() { echo "FAIL: $1" >&2; fail=1; }

if [ ! -f "$UID_SRC" ]; then
    echo "FAIL: $UID_SRC missing" >&2
    exit 1
fi

# --- Link 1: cross-frame focus tracker global exists -----------------------
if ! grep -Eq "^EVL_LAST_FOCUS_UID[[:space:]]*:" "$UID_SRC"; then
    fail_link "link 1 (hamUId.ad): EVL_LAST_FOCUS_UID global is gone - focus can't be tracked across frames"
fi

# --- Link 2: daemon_frame computes the current focus UID + reacts to change -
# Materialise the function body to a private temp file. Concurrent sweeps in
# the same checkout must not share these paths, hence mktemp -d.
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/de_focus_gate.XXXXXX") || {
    echo "INCONCLUSIVE: cannot create a temp dir for the focus gate" >&2
    exit 125
}
trap 'rm -rf "$WORK_DIR"' EXIT
FRAME_BODY="$WORK_DIR/daemon_frame.body"

awk '
    /^def[[:space:]]+daemon_frame[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$UID_SRC" >"$FRAME_BODY"

if [ ! -s "$FRAME_BODY" ]; then
    fail_link "link 2 (hamUId.ad): no 'def daemon_frame(' body found at all"
fi

if ! grep -Eq "cur_focus_uid[[:space:]]*=[[:space:]]*DWIN_UID\[DWIN_COUNT - 1\]" "$FRAME_BODY"; then
    fail_link "link 2 (hamUId.ad): daemon_frame no longer reads the front-most window's UID as the current focus"
fi
if ! grep -Eq "if[[:space:]]+cur_focus_uid[[:space:]]*!=[[:space:]]*EVL_LAST_FOCUS_UID" "$FRAME_BODY"; then
    fail_link "link 2 (hamUId.ad): daemon_frame no longer detects a focus transition"
fi

# --- Link 3: BOTH the losing AND the gaining window get damaged ------------
# The whole point is a full-frame repaint on BOTH ends of the transition, so
# the two damage_window() calls (over slot_for_uid of the old + new focus UID)
# must survive.
if ! grep -Eq "slot_for_uid\(EVL_LAST_FOCUS_UID\)" "$FRAME_BODY"; then
    fail_link "link 3 (hamUId.ad): the window that LOST focus is no longer resolved/damaged - its stale blue titlebar won't regrey"
fi
if ! grep -Eq "slot_for_uid\(cur_focus_uid\)" "$FRAME_BODY"; then
    fail_link "link 3 (hamUId.ad): the window that GAINED focus is no longer resolved/damaged"
fi
awk '
    /if[[:space:]]+cur_focus_uid[[:space:]]*!=[[:space:]]*EVL_LAST_FOCUS_UID/ { inside=1; out=""; next }
    inside && /EVL_LAST_FOCUS_UID[[:space:]]*=[[:space:]]*cur_focus_uid/ { print out; exit }
    inside { out = out $0 "\n" }
' "$FRAME_BODY" >"$WORK_DIR/focus_block"
dw_focus=$(grep -c "damage_window(" "$WORK_DIR/focus_block")
if [ "${dw_focus:-0}" -lt 2 ]; then
    fail_link "link 3 (hamUId.ad): expected TWO damage_window() calls in the focus-transition block (losing + gaining), found ${dw_focus:-0}"
fi

# --- Link 4: the compositor still compiles with the fix in place -----------
# Output goes in the private WORK_DIR: a shared build/host/ path let two
# concurrent sweeps clobber each other's .elf/.log and manufacture a red.
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        "$UID_SRC" -o "$WORK_DIR/hamUId_focusgate.elf" \
        >"$WORK_DIR/hamUId_focusgate.log" 2>&1; then
    fail_link "link 4: user/hamUId.ad did not compile for x86_64-adder-user"
    tail -20 "$WORK_DIR/hamUId_focusgate.log" >&2
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE focus-change titlebar repaint BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE focus-change titlebar repaint intact"
exit 0
