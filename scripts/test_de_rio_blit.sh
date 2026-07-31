#!/usr/bin/env bash
#
# VERDICT 2026-07-28: GATE ROT, NOT lost behaviour — and NOT a deletion
# candidate. The 2026-07-28 sweep red was 4 links (3 and 7) pinning EXACT
# declaration text from the June-2026 #442(c) design against a substrate that
# had been RESHAPED, not removed:
#     wsys_backbuffer Array[36864000,uint8] -> wsys_backbuffer_page: Array[32,
#         uint64], demand-allocated per wid from the buddy allocator (the flat
#         ~125 MiB BSS array OOMed a modest-RAM VM once MAX_WINDOWS hit 32)
#     h_v2_bb Array[4096000,uint8]          -> h_v2_bb_addr + h_v2_bb_w/h/
#         stride, a demand-zero anon mmap sized to the real window dims
#     h_v2_msg[0] = 66/68                   -> msg[0] = 66/68 via the
#         _h_v2_msg() accessor (same bytes, same wire format)
# Links 1/2/4/5/6/8/9 stayed green throughout, i.e. the blit protocol itself
# never regressed. The 'B'/'D' verb assertions are covered by NO other gate,
# so this was rewritten against the current names rather than deleted, and
# STRENGTHENED where the reshape created new failure modes the old flat-array
# form could not have: backbuffer alloc/release lifecycle (a leaked 4 MiB
# block per closed window) and the header rect/format payload.
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
    if ! grep -q "verb == ${verb_id}" <<<"$parse_body"; then
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
if ! grep -q "\"version\"" <<<"$(grep -E "_wctl_word_eq" "$KERN_SRC")"; then
    fail_link "link 2 (devwsys.ad): wctl `version <n>` verb is missing - clients can't negotiate protocol version"
fi

# --- Link 3: per-window backbuffer storage + accessor seam -----------
# The kernel's v2 pixel state. This used to be ONE flat static
# Array[36864000,uint8] of BSS; when MAX_WINDOWS went 9 -> 32 that shape
# (~125 MiB) OOMed a modest-RAM VM at boot, so it is now a 32-slot array of
# POINTERS, each demand-allocated from the buddy allocator on first blit and
# freed when the wid slot is released. Assert the CURRENT shape plus the
# alloc/release lifecycle the pointer form introduced — a leaked or
# never-freed block is a new failure mode the flat Array could not have.
if ! grep -Eq "^wsys_backbuffer_page:[[:space:]]+Array\[[0-9]+,[[:space:]]*uint64\]" "$KERN_SRC"; then
    fail_link "link 3 (devwsys.ad): wsys_backbuffer_page Array[N,uint64] is missing - no per-window backbuffer storage"
fi
if ! grep -Eq "^WSYS_BB_ORDER:[[:space:]]+int32" "$KERN_SRC"; then
    fail_link "link 3 (devwsys.ad): WSYS_BB_ORDER (buddy order for a backbuffer block) is missing"
fi
# Lazy alloc on first use ...
ens_body=$(awk '
    /^def[[:space:]]+_wsys_backbuffer_ensure[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$KERN_SRC")
if [ -z "$ens_body" ]; then
    fail_link "link 3 (devwsys.ad): _wsys_backbuffer_ensure() is missing - backbuffers are never allocated"
elif ! grep -q "alloc_pages(WSYS_BB_ORDER)" <<<"$ens_body"; then
    fail_link "link 3 (devwsys.ad): _wsys_backbuffer_ensure does not alloc_pages(WSYS_BB_ORDER)"
fi
# ... and release on slot teardown (else 32 windows leak ~4 MiB each).
rel_body=$(awk '
    /^def[[:space:]]+_wsys_backbuffer_release[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$KERN_SRC")
if [ -z "$rel_body" ]; then
    fail_link "link 3 (devwsys.ad): _wsys_backbuffer_release() is missing - backbuffer blocks leak on window close"
elif ! grep -q "free_pages(wsys_backbuffer_page" <<<"$rel_body"; then
    fail_link "link 3 (devwsys.ad): _wsys_backbuffer_release does not free_pages the block - ~4 MiB leaks per closed window"
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
if ! grep -q "_wsys_blit_parse" <<<"$draw_ctl_body"; then
    fail_link "link 5 (devwsys.ad): devwsys_draw_ctl_write does NOT call _wsys_blit_parse - v2 blit verbs fall through to the ASCII tokeniser"
fi
if ! grep -q "wsys_win_version_get" <<<"$draw_ctl_body"; then
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
# The client backbuffer must be at module scope (not a local — multi-MB
# would blow Adder's frame). It used to be a fixed Array[4096000,uint8]
# sized to a full 1280x800 screen; it is now a demand-zero anon mmap sized
# to the ACTUAL window dims, so the module-scope state is the mapping
# address plus the dims every draw primitive clips against.
for g in h_v2_bb_addr h_v2_msg_addr h_v2_bb_w h_v2_bb_h h_v2_bb_stride; do
    if ! grep -Eq "^${g}:[[:space:]]+uint64" "$HAMUI_SRC"; then
        fail_link "link 7 (lib/hamui.ad): client backbuffer global ${g}: uint64 is missing"
    fi
done
if ! grep -Eq "def[[:space:]]+_h_v2_alloc[[:space:]]*\(" "$HAMUI_SRC"; then
    fail_link "link 7 (lib/hamui.ad): _h_v2_alloc() is missing - the client backbuffer is never mapped"
fi
# The commit primitive must compose a 'B' header (verb byte 66) and a
# 'D' header (verb byte 68). We check via the verb-byte writes. The buffer
# is reached through the _h_v2_msg() accessor now that it is mmap'd, so
# match the write to the local alias rather than the old global name.
commit_body=$(awk '
    /^def[[:space:]]+hamui_v2_commit_rect[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUI_SRC")
if ! grep -qE "^[[:space:]]*msg\[0\] = 66\b" <<<"$commit_body"; then
    fail_link "link 7 (lib/hamui.ad): hamui_v2_commit_rect does NOT write a 'B' (66) verb byte - it isn't speaking the blit wire format"
fi
if ! grep -qE "^[[:space:]]*msg\[0\] = 68\b" <<<"$commit_body"; then
    fail_link "link 7 (lib/hamui.ad): hamui_v2_commit_rect does NOT write a 'D' (68) verb byte - dirty rect won't reach the kernel"
fi
# The 'B' payload must be tagged with the pixel format byte and both
# headers must carry the x0/y0/x1/y1 rect (little-endian i32 quads).
if ! grep -q "HAMUI_V2_FMT_RGBA8888" <<<"$commit_body"; then
    fail_link "link 7 (lib/hamui.ad): the 'B' header does not carry the pixel-format byte"
fi
if [ "$(echo "$commit_body" | grep -c "_h_v2_emit_i32_le")" -lt 8 ]; then
    fail_link "link 7 (lib/hamui.ad): the 'B'/'D' headers do not both emit a 4-word LE rect"
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
if ! grep -q "v2_present_dirty_windows" <<<"$ppo_body"; then
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
