#!/usr/bin/env bash
#
# ON-DEMAND *AND CURRENTLY RED — LIKELY GATE ROT, DELETION CANDIDATE*: not in
# ci_battery_manifest.txt because it FAILS on 55c842b9 (2026-07-28
# unregistered-gate sweep, 0.1 s).
#
# Unlike the other reds from that sweep, the evidence here points at the GATE,
# not the tree. It is a grep-guard that pins EXACT declaration text from the
# June-2026 #442(c) design:
#     wsys_backbuffer Array[36864000,uint8]   -> devwsys.ad now declares
#                                                wsys_backbuffer_page (24 hits)
#     h_v2_bb Array[4096000,uint8]            -> lib/hamui.ad now declares
#                                                h_v2_bb_addr / h_v2_bb_w/h
# i.e. the substrate EXISTS but was reshaped (paged backbuffers, dynamic
# dims), so the gate reds on renames rather than on lost behaviour. It also
# predates the DE scene-file pivot, which moved pixel ownership out of the
# kernel entirely. Before deleting it, confirm the blit wire format ('B'/'D'
# verbs) is asserted by a scene-era gate; if it is not, REWRITE this one
# against the current names instead of deleting the only coverage.
# scripts/test_de_rio_blit.sh — #442 (c) rio blit protocol substrate guard.
#
# THE KEYSTONE. graphical_stack_audit.md recommends a hard pivot away
# from the daemon_pixel monolith to a rio-faithful blit protocol whose
# wire format has been SPEC'D at the head of sys/src/9/port/devwsys.ad
# (lines ~61-98) for two days. This guard pins the substrate that
# implements the spec: kernel parser + per-window backbuffer storage,
# client-side rasterizer in lib/hamui.ad, and the compositor adoption
# seam in user/hamUId.ad.
#
# Subsequent agents port panel / menus / popups / cycler / calendar /
# run-dialog onto this substrate. If any of these links breaks, the
# pivot regressed — surface that loudly.
#
# Pass marker:  PASS: rio blit protocol substrate intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUI_SRC="lib/hamui.ad"
COMPOSITOR_SRC="user/hamUId.ad"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUI_SRC" "$COMPOSITOR_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: kernel parser for the 'B' / 'D' / 'C' binary verbs ------
# The keystone: the spec block at devwsys.ad:61-98 has been "next
# increment landing pad" for too long. _wsys_blit_parse() is what flips
# that from spec to substrate.
if ! grep -Eq "def[[:space:]]+_wsys_blit_parse[[:space:]]*\(" "$KERN_SRC"; then
    fail_link "link 1 (devwsys.ad): _wsys_blit_parse() definition is gone - the blit-verb parser doesn't exist"
fi
# It must accept all three verbs.
parse_body=$(awk '
    /^def[[:space:]]+_wsys_blit_parse[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$KERN_SRC")
# 'B' = 66, 'D' = 68, 'C' = 67 in ASCII.
for verb_id in 66 67 68; do
    if ! echo "$parse_body" | grep -q "verb == ${verb_id}"; then
        fail_link "link 1 (devwsys.ad): _wsys_blit_parse does NOT dispatch verb=${verb_id} - one of B/C/D is unimplemented"
    fi
done

# --- Link 2: per-window protocol-version byte (the v0/v1 vs v2 gate) -
# version-2 negotiation must be a real per-window field, set via wctl
# `version 2`, gated through wsys_win_version_get().
if ! grep -Eq "^wsys_win_version:[[:space:]]+Array" "$KERN_SRC"; then
    fail_link "link 2 (devwsys.ad): wsys_win_version Array global is missing - the per-window protocol-version gate isn't stored"
fi
if ! grep -Eq "def[[:space:]]+wsys_win_version_get[[:space:]]*\(" "$KERN_SRC"; then
    fail_link "link 2 (devwsys.ad): wsys_win_version_get() accessor is missing - callers can't ask whether a window is v2"
fi
# The wctl `version N` verb must exist (this is how clients opt in).
if ! grep -E "_wctl_word_eq" "$KERN_SRC" | grep -q "\"version\""; then
    fail_link "link 2 (devwsys.ad): wctl `version <n>` verb is missing - clients can't negotiate protocol version"
fi

# --- Link 3: per-window backbuffer storage + accessor seam -----------
# 9 windows * W*H*4 bytes. The flat Array is how the kernel holds the
# v2 pixel state. Widened from 320x200 (2 304 000 B) to 1280x800
# (36 864 000 B) so the panel can cover the full screen width.
if ! grep -Eq "^wsys_backbuffer:[[:space:]]+Array\[(2304000|36864000)," "$KERN_SRC"; then
    fail_link "link 3 (devwsys.ad): wsys_backbuffer Array[36864000,uint8] is missing - no per-window backbuffer storage"
fi
for fn in wsys_backbuffer_ptr wsys_backbuffer_dims_w wsys_backbuffer_dims_h \
          wsys_backbuffer_stride wsys_bb_serial_get wsys_bb_dirty_get \
          wsys_bb_dirty_clear; do
    if ! grep -Eq "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): backbuffer accessor ${fn}() is missing - the compositor seam is broken"
    fi
done

# --- Link 4: cursor sprite storage + accessors -----------------------
# The 'C' verb is part of the spec and is what removes the cursor-
# decoupling canary in finding §4 of the audit. Per-window cursor.
if ! grep -Eq "^wsys_cursor_pix:[[:space:]]+Array" "$KERN_SRC"; then
    fail_link "link 4 (devwsys.ad): wsys_cursor_pix Array is missing - per-window cursor sprite storage gone"
fi
for fn in wsys_cursor_get_w wsys_cursor_get_h wsys_cursor_get_hx \
          wsys_cursor_get_hy wsys_cursor_ptr wsys_cursor_gen_get; do
    if ! grep -Eq "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 4 (devwsys.ad): cursor accessor ${fn}() is missing"
    fi
done

# --- Link 5: draw/ctl entry point routes B/D/C BEFORE the ASCII path -
# A v2 window's draw/ctl write whose first byte is 'B' / 'D' / 'C'
# (66 / 68 / 67) must dispatch through _wsys_blit_parse and NOT the
# legacy tokeniser. If the gate ever flips to ASCII first, v2 clients
# get EINVAL on every blit.
draw_ctl_body=$(awk '
    /^def[[:space:]]+devwsys_draw_ctl_write[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$KERN_SRC")
if ! echo "$draw_ctl_body" | grep -q "_wsys_blit_parse"; then
    fail_link "link 5 (devwsys.ad): devwsys_draw_ctl_write does NOT call _wsys_blit_parse - v2 blit verbs fall through to the ASCII tokeniser"
fi
if ! echo "$draw_ctl_body" | grep -q "wsys_win_version_get"; then
    fail_link "link 5 (devwsys.ad): devwsys_draw_ctl_write does NOT gate the blit dispatch on wsys_win_version_get - legacy v0/v1 markup may misroute through the blit parser"
fi

# --- Link 6: namec dispatches v2 file leaves -------------------------
# /dev/wsys/<wid>/bbstate and /dev/wsys/<wid>/backbuffer are how the
# (userland) compositor reads the kernel-side v2 state. namec must
# resolve them AND dispatch read.
for kind in DEV_WSYS_BBSTATE DEV_WSYS_BACKBUFFER; do
    if ! grep -Eq "^${kind}:[[:space:]]+int32" "$NAMEC_SRC"; then
        fail_link "link 6 (namec.ad): ${kind} DEV constant is missing"
    fi
done
for fn in devwsys_bbstate_read devwsys_backbuffer_read; do
    if ! grep -Eq "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 6 (devwsys.ad): ${fn}() definition is missing - the v2 file leaf has no read path"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 6 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"/bbstate"' "$NAMEC_SRC"; then
    fail_link "link 6 (namec.ad): /bbstate suffix is not matched in _devtab_lookup_wsys"
fi
if ! grep -q '"/backbuffer"' "$NAMEC_SRC"; then
    fail_link "link 6 (namec.ad): /backbuffer suffix is not matched in _devtab_lookup_wsys"
fi

# --- Link 7: client-side rasterizer in lib/hamui.ad ------------------
# This is the toolkit half of the keystone: a client backbuffer + the
# 'B'+'D' commit primitive. Without it, the panel/menu/popup ports
# that are queued behind this commit have no client API to call.
for fn in hamui_set_protocol_v2 hamui_v2_is_active hamui_v2_clear \
          hamui_v2_fill_rect hamui_v2_set_pixel hamui_v2_commit_rect \
          hamui_v2_set_cursor; do
    if ! grep -Eq "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUI_SRC"; then
        fail_link "link 7 (lib/hamui.ad): client-side API ${fn}() is missing - the toolkit cannot drive the blit protocol"
    fi
done
# The client backbuffer must be at module scope (not a local —
# multi-MB would blow Adder's frame). Widened to full screen
# (1280x800x4 = 4 096 000 B) so the panel covers the full width.
if ! grep -Eq "^h_v2_bb:[[:space:]]+Array\[(256000|4096000)," "$HAMUI_SRC"; then
    fail_link "link 7 (lib/hamui.ad): h_v2_bb Array[4096000,uint8] client backbuffer is missing"
fi
# The commit primitive must compose a 'B' header (verb byte 66) and a
# 'D' header (verb byte 68). We check via the verb-byte writes.
commit_body=$(awk '
    /^def[[:space:]]+hamui_v2_commit_rect[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUI_SRC")
if ! echo "$commit_body" | grep -q "h_v2_msg\[0\] = 66"; then
    fail_link "link 7 (lib/hamui.ad): hamui_v2_commit_rect does NOT write a 'B' (66) verb byte - it isn't speaking the blit wire format"
fi
if ! echo "$commit_body" | grep -q "h_v2_msg\[0\] = 68"; then
    fail_link "link 7 (lib/hamui.ad): hamui_v2_commit_rect does NOT write a 'D' (68) verb byte - dirty rect won't reach the kernel"
fi

# --- Link 8: compositor adoption seam in user/hamUId.ad --------------
# The user-facing payoff: v2 windows BYPASS daemon_pixel. The
# compositor walks DWIN_PROTO_V2 slots and blits their kernel-side
# backbuffers straight to /dev/fb after the present.
for sym in DWIN_PROTO_V2 V2_LAST_SERIAL; do
    if ! grep -Eq "^${sym}:[[:space:]]+Array" "$COMPOSITOR_SRC"; then
        fail_link "link 8 (hamUId.ad): ${sym} per-window flag/state Array is missing - the compositor has no v2 opt-in slot"
    fi
done
for fn in v2_present_dirty_windows v2_blit_window_dirty_rect \
          v2_read_bbstate v2_window_mark_proto; do
    if ! grep -Eq "def[[:space:]]+${fn}[[:space:]]*\(" "$COMPOSITOR_SRC"; then
        fail_link "link 8 (hamUId.ad): v2 compositor seam ${fn}() is missing"
    fi
done
# v2_present_dirty_windows must be called per-frame. It's hooked through
# post_present_overlays() (next to the rubber-band overlay), so the v2
# blit lands AFTER the cached SCENE_CACHE blit but BEFORE the next
# frame's daemon_pixel pass — same shape as the rubber-band hoist.
ppo_body=$(awk '
    /^def[[:space:]]+post_present_overlays[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$COMPOSITOR_SRC")
if ! echo "$ppo_body" | grep -q "v2_present_dirty_windows"; then
    fail_link "link 8 (hamUId.ad): post_present_overlays does NOT call v2_present_dirty_windows - v2 windows never paint"
fi

# --- Link 9: the spec block stays present + dated --------------------
# The spec at the head of devwsys.ad is the load-bearing piece of
# documentation. If a future refactor strips it, the wire format
# becomes folklore.
if ! grep -q "#442 RIO-FAITHFUL RESHAPE" "$KERN_SRC"; then
    fail_link "link 9 (devwsys.ad): the #442 wire-format spec block at the head of the file is gone - the protocol becomes folklore"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: rio blit protocol substrate BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: rio blit protocol substrate intact"
exit 0
