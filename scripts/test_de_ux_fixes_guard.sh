#!/usr/bin/env bash
# scripts/test_de_ux_fixes_guard.sh — static guards for the four DE UX fixes so
# they don't silently regress (the live proofs are the KVM drivers
# scripts/verify_bug1_fmopen.py / verify_de_fixes.py / verify_bug4_settings.py,
# captured as PNGs). Cheap grep/compile assertions only — no QEMU.
#
#   BUG 1  hamfmscene launches the editor with argv = [bin, path, NULL] so
#          hameditscene sees argc>=2 and preloads the double-clicked file.
#   BUG 2  devwsys auto-raises + focuses a window on its FIRST content commit
#          (map-and-raise) so a freshly-opened window is topmost + focused.
#   BUG 3  hamtermscene decodes ESC '[' A/B/C/D arrows into history (Up/Down)
#          + an in-line cursor (Left/Right), instead of leaking "[A" glyphs.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail=0
pass() { echo "[ux_guard] PASS $1"; }
failf() { echo "[ux_guard] FAIL $1" >&2; fail=1; }
need() { grep -q -- "$2" "$1" && pass "$3" || failf "$3"; }

FM="user/hamfmscene.ad"; TS="user/hamtermscene.ad"; WS="sys/src/9/port/devwsys.ad"

echo "[ux_guard] --- BUG 1: FM passes argv [bin, path, NULL] ---"
# argv[0] = the binary, argv[1] = the path, argv[2] = 0 (terminator).
need "$FM" "ed_argv\[0\] = cast\[uint64\](&ED_BIN\[0\])" "FM argv[0] is the editor binary path"
need "$FM" "ed_argv\[1\] = cast\[uint64\](&ed_path\[0\])" "FM argv[1] is the file path"
need "$FM" "ed_argv\[2\] = 0" "FM argv is NULL-terminated at [2]"
if grep -q "ed_argv: Array\[2," "$FM"; then
    failf "FM ed_argv still sized 2 (no room for [bin,path,NULL])"
else
    pass "FM ed_argv sized for [bin, path, NULL]"
fi

echo "[ux_guard] --- BUG 2: devwsys map-and-raise on first commit ---"
need "$WS" "wsys_win_mapped" "devwsys has a per-window mapped flag"
need "$WS" "if wsys_win_mapped\[u\] == 0 and wsys_scene_len\[u\] > 0" "first-commit map-and-raise gate"
# the gate must raise + focus (skipping pinned backgrounds).
if grep -Pzoq "wsys_win_mapped\[u\] = 1\n\s*if wsys_win_pinned\[u\] == 0:\n\s*_wsys_raise\(wid\)\n\s*_wsys_set_focus\(wid\)" "$WS"; then
    pass "first commit raises + focuses the new window (non-pinned)"
else
    failf "first-commit raise+focus body missing/changed"
fi

echo "[ux_guard] --- BUG 3: hamtermscene arrow decode + history + cursor ---"
need "$TS" "key_esc_st" "terminal has an ESC-CSI key decode state"
need "$TS" "def _key_csi_final" "terminal decodes CSI final bytes (arrows)"
need "$TS" "def _hist_push" "terminal has a command-history ring"
need "$TS" "def _hist_load" "terminal recalls history entries"
need "$TS" "term_line_cur" "terminal tracks an in-line insertion cursor"
need "$TS" "def _redraw_edit_line" "terminal re-renders the edit row on cursor/history change"
# Up=65 recalls older history; Left=68 moves the caret.
need "$TS" "if code == 65:" "Up arrow handled (older history)"
need "$TS" "if code == 68:" "Left arrow handled (caret left)"

echo "[ux_guard] --- QA-N1: default terminal opens clear of the desktop icon strut ---"
# The MATE-style launcher column hamdesktop lays down the LEFT edge (icons +
# labels, widest "System Monitor" ending ~x=130) is a fixed strut. The default
# terminal used to open at x=24, bisecting that column: the leftmost ~6px of
# each icon label's first glyph stayed exposed in the x=[18,24) sliver just
# left of the window border — orphaned single-glyph fragments that read as
# text "bleeding through" the terminal (the compositor z-order was correct;
# the strip simply was not under any window). The terminal must now open at an
# x origin clear of the strut, like every other default DE app.
# (The old `grep -q 'geometry 24 40 '` spot-check that used to live here was
# removed: it pinned BOTH coordinates too, so once y moved to 52 it could no
# longer fire at all -- a return to x=24 would have slipped straight past it.
# The derived x check below subsumes it and actually catches that.)
#
# 2026-07-31: this used to be `need "$TS" "geometry 150 40 "`, pinning BOTH
# coordinates. The Y origin has since moved 40 -> 52, deliberately, in 7919357d
# (#254, rounded SSD titlebar corners): the titlebar sits WSYS_TITLEBAR_H = 18px
# ABOVE the content origin, so a content y of 40 put the titlebar top at 22 --
# tucked UNDER the 28px top panel, where the new rounded corners were occluded.
# y=52 puts it at 34, a clean 6px below the panel. x=150 never moved, and x is
# the only thing QA-N1 is about (see the strut discussion above); the y was
# incidental over-specification that turned a working tree red. Gate rot.
#
# Assert the two properties separately, and derive rather than pin: x must clear
# the ~x=130 icon strut, and the titlebar top (y - WSYS_TITLEBAR_H) must clear
# the top panel.
TITLEBAR_H=$(grep -oE '^WSYS_TITLEBAR_H: int64 = [0-9]+' sys/src/9/port/devwsys.ad \
             | grep -oE '[0-9]+$')
TOP_PANEL_H=28
geo=$(grep -oE '"geometry [0-9]+ [0-9]+ "' "$TS" | head -1)
if [ -z "$geo" ] || [ -z "${TITLEBAR_H:-}" ]; then
    failf "terminal default geometry literal not found in $TS (or WSYS_TITLEBAR_H missing from devwsys.ad)"
else
    geo_x=$(awk '{print $2}' <<<"$geo")
    geo_y=$(awk '{print $3}' <<<"$geo")
    if [ "$geo_x" -lt 140 ]; then
        failf "terminal default x origin is $geo_x - must clear the desktop icon strut (labels end ~x=130)"
    else
        pass "terminal default origin clears the icon strut (x=$geo_x)"
    fi
    if [ "$((geo_y - TITLEBAR_H))" -le "$TOP_PANEL_H" ]; then
        failf "terminal titlebar top is at $((geo_y - TITLEBAR_H)) - occluded by the ${TOP_PANEL_H}px top panel (#254 rounded corners invisible)"
    else
        pass "terminal titlebar top ($((geo_y - TITLEBAR_H))) clears the ${TOP_PANEL_H}px top panel"
    fi
fi

echo "[ux_guard] --- QA-N2: hamterm closes its window when the shell exits ---"
# `exit` (or Ctrl-D/EOF) in the DE terminal's hamsh must tear the terminal
# WINDOW down, like any terminal — not leave an orphaned empty window. The DE
# launches /bin/hamtermscene (NOT the legacy user/hamterm.ad — #126), whose
# _drain_shell clears sh_alive on the shell stdout-pipe EOF; the main loop must
# then emit "shell exited; closing window" and break/return so the process
# exits and the compositor's owner-dead reaper frees the wid. (This guard used
# to check user/hamterm.ad — the wrong file — a false-green fixed in #133.)
HT="user/hamtermscene.ad"
if grep -Pzoq 'shell exited; closing window(.|\n)*?(break|return 0)' "$HT"; then
    pass "hamtermscene exits its loop when the shell exits (window teardown)"
else
    failf "hamtermscene shell-exit branch no longer breaks/returns (window would orphan)"
fi

echo "[ux_guard] --- QA-N3: notification tray popup has working [X] + [Clear] ---"
UID_AD="user/hamUId.ad"; TRAY="user/hamtray.ad"
# The compositor must hit-test a dedicated [X] close box in the tray header.
need "$UID_AD" "def in_tray_close_btn" "compositor has an [X] close-box hit-test"
# The click handler must dismiss the popup on the [X].
if grep -Pzoq 'if in_tray_close_btn\(CUR_X, CUR_Y, scr_w\) != 0:\n\s*TRAY_OPEN = 0' "$UID_AD"; then
    pass "[X] close box dismisses the tray popup"
else
    failf "[X] close box does not set TRAY_OPEN = 0"
fi
# [Clear] must empty the ring AND close the popup.
if grep -Pzoq 'if in_tray_clear_btn\(CUR_X, CUR_Y, scr_w\) != 0:\n\s*nhist_clear\(\)\n\s*TRAY_OPEN = 0' "$UID_AD"; then
    pass "[Clear] empties notifications AND closes the popup"
else
    failf "[Clear] no longer clears + closes the popup"
fi
# The render client must draw both header buttons (close box + clear bar).
need "$TRAY" "close box" "hamtray renders the [X] close box"
# DE13 self-test must cover the new close-box zone.
need "$UID_AD" "in_tray_close_btn(closex, hdr_y, scr_w)" "DE13 asserts the [X] close-box hit-zone"

echo "[ux_guard] --- compile the touched user binaries ---"
# shellcheck source=_adder_cc.sh
source "$PROJ_ROOT/scripts/_adder_cc.sh"
mkdir -p build/user
for n in hamfmscene hamtermscene hamterm hamtray hamUId; do
    if adder_cc_compile compile --target=x86_64-adder-user "user/${n}.ad" \
            -o "build/user/${n}.elf" >/dev/null 2>&1; then
        pass "user/${n}.ad compiles"
    else
        failf "user/${n}.ad failed to compile"
    fi
done

echo "[ux_guard] --- result ---"
if [ "$fail" = 0 ]; then echo "[ux_guard] RESULT: PASS"; exit 0
else echo "[ux_guard] RESULT: FAIL"; exit 1; fi
