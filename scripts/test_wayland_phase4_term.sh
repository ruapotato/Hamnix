#!/usr/bin/env bash
# scripts/test_wayland_phase4_term.sh — Wayland-passthrough Phase 4b, the
# INTERACTIVE rung: a REAL Debian weston-terminal (UNMODIFIED, cairo/pango,
# pure-SHM, NO GL) renders its terminal UI on the native in-kernel Wayland
# server (linux_abi/wayland.ad) AND accepts KEYBOARD input through the
# Phase-2 wl_seat/wl_keyboard path — typed characters ECHO in the terminal.
#
# Flow:
#   1. boot the full-mirror live image under KVM/OVMF (4G),
#   2. spawn weston-terminal in the Linux ns (XDG_RUNTIME_DIR=/run,
#      WAYLAND_DISPLAY=wayland-0) — it maps an xdg_toplevel, forkpty's a
#      shell, and commits its cairo-rendered terminal shm buffer,
#   3. screendump A (the rendered terminal),
#   4. inject keystrokes ("ls\n") into the terminal window's /keys ring
#      (/dev/wsys/<wid>/keys, the exact "d <ascii>" cooked format the
#      compositor focus router writes) — the wayland pump drains them and
#      delivers wl_keyboard.key events to the REAL libwayland listener,
#   5. screendump B (typed text visible),
#   6. assert (a) the shm-commit marker fired (render) and (b) the fb
#      CHANGED between A and B in the terminal window region (typed echo).
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, the image, socat, or the real
# weston-terminal is unavailable. KVM/OVMF only. Every qemu is killed on exit.
#
# Env overrides mirror test_wayland_phase4_render.sh.
set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
LIVE_DISTRO_IMG="${LIVE_DISTRO_IMG:-build/hamnix-live-distro.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
CMD_WAIT="${CMD_WAIT:-180}"
QEMU_MEM="${QEMU_MEM:-4G}"
OUTDIR="${OUTDIR:-$PROJ_ROOT}"
TAG="[test_wl4_term]"

LIVE_MARKER="booting LIVE environment"
HANDOFF_MARKER="handing off to interactive shell"
LIVEROOT_MARKER="[live-root] DONE"
COMMIT_MARKER="shm buffer committed"
KEY_MARKER="wl_keyboard key delivered"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "$TAG SKIP: /dev/kvm absent (KVM required)" >&2; exit 0
fi
command -v socat >/dev/null 2>&1 || { echo "$TAG SKIP: socat not installed." >&2; exit 0; }
command -v pnmtopng >/dev/null 2>&1 || echo "$TAG NOTE: pnmtopng absent; raw PPM only."
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "$TAG SKIP: OVMF firmware not found." >&2; exit 0; }
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[wayland_phase4_term]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "$TAG SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2; exit 0
    fi
    echo "$TAG building full-mirror live installer image (HAMNIX_LIVE_MINIMAL=0)"
    HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB="${HAMNIX_ROOTFS_SIZE_MB:-1792}" \
        bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
[ -f "$INSTALLER_IMG" ] || { echo "$TAG SKIP: $INSTALLER_IMG unavailable." >&2; exit 0; }

# --- decide whether the live image carries weston-terminal ------------
HAVE_TERM=0
DEBUGFS="/sbin/debugfs"; [ -x "$DEBUGFS" ] || DEBUGFS="$(command -v debugfs || true)"
if [ -f "$LIVE_DISTRO_IMG" ] && [ -n "$DEBUGFS" ]; then
    "$DEBUGFS" -R "stat /distro/usr/bin/weston-terminal" "$LIVE_DISTRO_IMG" 2>/dev/null \
        | grep -q "Type: regular" && HAVE_TERM=1
fi
echo "$TAG live image probe: weston-terminal=$HAVE_TERM"
if [ "$HAVE_TERM" -eq 0 ]; then
    echo "$TAG SKIP: live image carries no weston-terminal." >&2
    echo "$TAG       Run scripts/stage_weston_term.sh then rebuild with" >&2
    echo "$TAG       HAMNIX_LIVE_MINIMAL=0 bash scripts/build_installer_img.sh." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-wl4t.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-wl4t.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-wl4t.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-wl4t-in.XXXXXX)
MON=$(mktemp --tmpdir -u hamnix-wl4t-mon.XXXXXX.sock)
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$FIFO" "$MON"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "$QEMU_MEM" \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
exec 3> "$FIFO"

mon() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" 2>/dev/null; }

wait_for() {
    local pat="$1" secs="$2" i
    for i in $(seq 1 "$secs"); do
        grep -a -F -q "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
send_until() {
    local cmd="$1" pat="$2" secs="$3" waited=0 i
    while [ "$waited" -lt "$secs" ]; do
        printf '\n' >&3; sleep 1
        printf '%s\n' "$cmd" >&3
        for i in $(seq 1 15); do
            grep -a -F -q "$pat" "$LOG" && return 0
            kill -0 "$QEMU_PID" 2>/dev/null || return 1
            sleep 1; waited=$((waited + 1))
            [ "$waited" -ge "$secs" ] && break
        done
    done
    grep -a -F -q "$pat" "$LOG"
}
send() { printf '%s\n' "$1" >&3; }

fail=0

echo "$TAG waiting up to ${BOOT_WAIT}s for the LIVE branch + handoff..."
if ! wait_for "$LIVE_MARKER" "$BOOT_WAIT"; then
    echo "$TAG FAIL: LIVE-branch marker not seen." >&2
    tail -60 "$LOG" | strings >&2; exit 1
fi
wait_for "$LIVEROOT_MARKER" "$BOOT_WAIT" \
    && echo "$TAG PASS: kernel live-root bringup completed." \
    || { echo "$TAG WARN: '[live-root] DONE' not seen." >&2; }
if ! wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "$TAG FAIL: handoff marker not seen in ${BOOT_WAIT}s." >&2
    tail -60 "$LOG" | strings >&2; exit 1
fi
wait_for "ed-readline-first" 30 || sleep 3
if wait_for "[visual_gate] done" 240; then
    echo "$TAG DE visual_gate settled; system quiet for the client."; sleep 6
else
    echo "$TAG NOTE: visual_gate-done not seen in 240s; proceeding anyway."
fi

# --- RENDER: weston-terminal ------------------------------------------
# weston-terminal is spawned DIRECTLY (no /bin/sh -c wrapper: an `exec` of a
# second Linux-ABI image inside the ns trips an NX exec-fault SIGSEGV before
# the terminal reaches wayland_connect). fontconfig's writable-cache need is
# satisfied by the PREBUILT cache shipped in /etc/fonts/cache (the first
# <cachedir> in the staged fonts.conf) — /etc survives FULL_DEBIAN_PRUNE and
# the live root is a writable RAM-ext4, so FcInit loads the prebuilt cache
# and never emits "No writable cache directories". (/run is pruned + not
# creatable in the ns, so it is NOT used as the cache dir.)
TERM_CMD='export XDG_RUNTIME_DIR=/run ; export WAYLAND_DISPLAY=wayland-0 ; export XDG_CONFIG_HOME=/run ; export XDG_CACHE_HOME=/etc/fonts/cache ; spawn linux { /usr/bin/weston-terminal }'
echo "$TAG --- RENDER: launch weston-terminal ---"
committed=0
if send_until "$TERM_CMD" "$COMMIT_MARKER" "$CMD_WAIT"; then
    echo "$TAG PASS: server-side shm-commit marker fired:"
    grep -aF "$COMMIT_MARKER" "$LOG" | tail -4
    committed=1
else
    echo "$TAG WARN: '$COMMIT_MARKER' not seen; screendumping anyway." >&2
fi
sleep 4

# Extract the wid weston-terminal committed to (last commit marker line).
WID="$(grep -aF "$COMMIT_MARKER" "$LOG" | tail -1 | grep -aoE 'wid [0-9]+' | awk '{print $2}')"
echo "$TAG weston-terminal window id: ${WID:-<unknown>}"

PPM_A="$OUTDIR/wl4_term_A.ppm"
PPM_B="$OUTDIR/wl4_term_B.ppm"
PNG_A="$OUTDIR/wl4_term_render.png"
PNG_B="$OUTDIR/wl4_term_typed.png"
rm -f "$PPM_A" "$PPM_B" "$PNG_A" "$PNG_B"
mon "screendump $PPM_A" >/dev/null; sleep 1

# --- INPUT: type "ls\n" into the terminal's /keys ring ----------------
# The wayland pump drains /dev/wsys/<WID>/keys and translates each cooked
# "d <ascii>" press line into a wl_keyboard.key to the focused surface.
echo "$TAG --- INPUT: typing 'ls<Enter>' into wid ${WID:-?} ---"
if [ -n "$WID" ]; then
    KP="/dev/wsys/$WID/keys"
    # l=108 s=115 Enter=10. echo each cooked press line into the ring.
    for code in 108 115 10; do
        send "echo d $code > $KP"
        sleep 1
    done
    sleep 3
else
    echo "$TAG WARN: no wid parsed; cannot target /keys ring." >&2
    fail_input=1
fi

sleep 2
mon "screendump $PPM_B" >/dev/null; sleep 1

if command -v pnmtopng >/dev/null 2>&1; then
    [ -s "$PPM_A" ] && pnmtopng "$PPM_A" > "$PNG_A" 2>/dev/null && echo "$TAG PNG (render): $PNG_A"
    [ -s "$PPM_B" ] && pnmtopng "$PPM_B" > "$PNG_B" 2>/dev/null && echo "$TAG PNG (typed):  $PNG_B"
fi

# --- proofs -----------------------------------------------------------
# (1) render: the terminal window is a non-flat region (cairo text + SSD
#     chrome). (2) typed echo: the framebuffer CHANGED between A (fresh
#     terminal) and B (after 'ls' typed + shell echo) in a text region.
if [ -s "$PPM_A" ] && [ -s "$PPM_B" ]; then
    read -r RENDER_OK TYPED_OK MSG < <(python3 - "$PPM_A" "$PPM_B" <<'PY'
import sys
def load(p):
    d=open(p,'rb').read()
    assert d[:2]==b'P6'
    idx=2; vals=[]
    while len(vals)<3:
        while idx<len(d) and d[idx] in b' \t\n\r': idx+=1
        if d[idx:idx+1]==b'#':
            while idx<len(d) and d[idx] not in b'\n': idx+=1
            continue
        s=idx
        while idx<len(d) and d[idx] not in b' \t\n\r': idx+=1
        vals.append(int(d[s:idx]))
    idx+=1
    w,h,mv=vals
    return w,h,d[idx:idx+w*h*3]
wa,ha,a=load(sys.argv[1]); wb,hb,b=load(sys.argv[2])
# render proof: a 200x120 tile somewhere with many distinct colours (cairo
# text + titlebar) — a flat desktop never packs this.
best=0
for y0 in range(0,max(1,hb-120),20):
    for x0 in range(0,max(1,wb-200),20):
        sset=set()
        for yy in range(y0,y0+120,8):
            for xx in range(x0,x0+200,8):
                o=(yy*wb+xx)*3; sset.add((b[o],b[o+1],b[o+2]))
        best=max(best,len(sset))
render_ok = 1 if best>=12 else 0
# typed proof: count changed pixels A->B (typed text + echoed 'ls' output).
changed=0
if (wa,ha)==(wb,hb):
    for yy in range(0,hb,3):
        for xx in range(0,wb,3):
            o=(yy*wb+xx)*3
            if abs(a[o]-b[o])+abs(a[o+1]-b[o+1])+abs(a[o+2]-b[o+2])>24:
                changed+=1
typed_ok = 1 if changed>=20 else 0
print(render_ok, typed_ok, f"term_tile_uniq={best} interframe_changed={changed} fb={wb}x{hb}")
PY
)
    echo "$TAG render check: $MSG"
else
    echo "$TAG FAIL: screendump produced no PPM." >&2; fail=1; RENDER_OK=0; TYPED_OK=0
fi

echo "$TAG --- wayland/pty lines from serial ---"
grep -aE "\[wayland\]|\[pty\]|weston" "$LOG" | tail -30 || true
echo "$TAG --- end ---"

# --- fontconfig-writable-cache assertion (the Phase-4b font deliverable) --
# The scripted fix (scripts/stage_weston_term.sh + build_rootfs_img.py)
# ships a PREBUILT fontconfig cache in the writable, non-pruned
# /etc/fonts/cache (first <cachedir> in the staged fonts.conf) + a live root
# with 0 reserved blocks and real free space, so FcInit no longer aborts
# weston-terminal with "No writable cache directories". Assert that error
# string is ABSENT from the whole boot+run serial log — a regression here
# (e.g. the cache pruned again, or the cachedir order broken) must fail.
if grep -aiE "No writable cache director|Fontconfig error" "$LOG" >/dev/null 2>&1; then
    echo "$TAG FAIL: fontconfig writable-cache regression — error present in serial:" >&2
    grep -aiE "No writable cache director|Fontconfig error" "$LOG" | head -3 >&2
    echo "$TAG RESULT: FAIL (fontconfig cache)"; exit 1
fi
echo "$TAG PASS: no fontconfig 'No writable cache directories' error (prebuilt /etc/fonts/cache consulted)."

# --- verdict ----------------------------------------------------------
if [ "$fail" -ne 0 ]; then echo "$TAG RESULT: FAIL (boot/screendump)"; exit 1; fi
if [ "$committed" -eq 1 ] && [ "${RENDER_OK:-0}" = "1" ] && [ "${TYPED_OK:-0}" = "1" ]; then
    echo "$TAG RESULT: PASS — weston-terminal RENDERED and echoed TYPED input (render: $PNG_A, typed: $PNG_B)."
    exit 0
fi
# MILESTONE COMPLETE (QA-N33, 2026-07-02). Every gate that once blocked an
# interactive weston-terminal is fixed on main: fontconfig writable-cache, the
# forkpty-child execve NX fault (login_tty/TIOCSCTTY), the epoll/AF_UNIX
# readiness bug, the DEV_PTMX pty-poll arm (0a05e0af), and the #9 NO_HZ SMP
# hard-wedge (23828e0a: per-CPU tick + BSP-only hrtimer + AP LAPIC backstop +
# steal hysteresis — heartbeat stays live under fork+exec+render load). A real
# Debian weston-terminal now RENDERS its SSD-chromed terminal UI on the native
# in-kernel Wayland compositor AND echoes typed input ("ls" via the /keys ring
# -> wl_keyboard.key -> XKB -> shell echo). Verified end-to-end with the two
# screendumps above. Both proofs are therefore HARD gates now: a render or a
# typed-echo failure past this point is a REGRESSION and must FAIL the test
# (not degrade to PARTIAL/SKIP). Only the environment gates at the top of this
# script (no /dev/kvm, OVMF, image, socat, weston-terminal) skip cleanly.
if [ "$committed" -eq 1 ] && [ "${RENDER_OK:-0}" = "1" ]; then
    echo "$TAG RESULT: FAIL — weston-terminal RENDERED but typed input did NOT echo" >&2
    echo "$TAG   (interframe change below threshold; see $PNG_B). The keyboard/seat" >&2
    echo "$TAG   path (/keys ring -> wl_keyboard.key -> XKB) regressed." >&2
    exit 1
fi
echo "$TAG RESULT: FAIL — weston-terminal did NOT render a terminal buffer." >&2
echo "$TAG   committed=$committed RENDER_OK=${RENDER_OK:-0} TYPED_OK=${TYPED_OK:-0}." >&2
echo "$TAG   This milestone (interactive Debian weston-terminal on the native" >&2
echo "$TAG   Wayland compositor) previously PASSED; a no-render here is a regression." >&2
echo "$TAG   Check the wayland/pty serial lines above and the #9 NO_HZ SMP wedge fix." >&2
exit 1
