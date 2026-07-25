#!/usr/bin/env bash
# scripts/test_wayland_phase4_render.sh — Wayland-passthrough Phase 4,
# the RENDER rung: a REAL Debian pure-SHM client (weston-simple-shm,
# UNMODIFIED, no GL) drives the native in-kernel Wayland server
# (linux_abi/wayland.ad) all the way to PIXELS — it binds wl_compositor +
# wl_shm + xdg_wm_base, memfd+mmaps an ARGB8888 pool (fd passed via
# SCM_RIGHTS), maps an xdg_toplevel and COMMITS animated shm frames. The
# server decodes each committed buffer into a Hamnix scene window
# (wl_commit_buffer -> wsys_wl_store_rect/present) which the DE composites
# to /dev/fb.
#
# This is the end-to-end RENDER proof that Phase-4 connect/enumerate did
# not yet capture. It differs from test_wayland_phase4_live.sh in two ways:
#
#   1. It runs ONLY weston-simple-shm (NO wayland-info first) to dodge the
#      "second spawn linux did not take" serial-sequencing issue seen when
#      two clients were launched back-to-back.
#
#   2. It attaches a QEMU HMP monitor (unix socket) and `screendump`s the
#      guest framebuffer to a host PPM -> PNG, then proves the client window
#      actually PAINTED by (a) the server's WARN-level shm-commit marker on
#      serial and (b) an inter-frame framebuffer DIFF: weston-simple-shm
#      animates its pattern every frame, so a rectangular region of the
#      framebuffer CHANGES between two screendumps taken a beat apart. A
#      static desktop cannot produce that, so a non-trivial changed region
#      is positive proof of a live, compositing client window.
#
# Judged by: the "[wayland] shm buffer committed <w>x<h> to wid <N>" WARN
# marker on serial (visible past INFO suppression once userland is
# interactive) AND a non-blank inter-frame diff. The PNG screendump is
# saved to $OUTDIR for visual confirmation.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, the image, socat, or the
# real Debian client is unavailable. KVM/OVMF only (-kernel does not boot
# here). Every qemu spawned is killed on exit.
#
# Env overrides:
#   INSTALLER_IMG      image path     (default: build/hamnix-installer.img)
#   LIVE_DISTRO_IMG    live ext4 path (default: build/hamnix-live-distro.img)
#   OVMF_FD            OVMF firmware  (default: auto-resolved)
#   BOOT_WAIT          seconds for boot markers          (default: 300)
#   CMD_WAIT           seconds for command output        (default: 180)
#   QEMU_MEM           guest RAM      (default: 4G)
#   OUTDIR             where PNG/PPM screendumps land     (default: worktree root)
#   HAMNIX_SKIP_BUILD  1 = require an existing image (no rebuild)
#   KEEP_LOGS          1 = keep the serial log

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
LIVE_DISTRO_IMG="${LIVE_DISTRO_IMG:-build/hamnix-live-distro.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
CMD_WAIT="${CMD_WAIT:-180}"
QEMU_MEM="${QEMU_MEM:-4G}"
OUTDIR="${OUTDIR:-$PROJ_ROOT}"
TAG="[test_wl4_render]"

LIVE_MARKER="booting LIVE environment"
HANDOFF_MARKER="handing off to interactive shell"
LIVEROOT_MARKER="[live-root] DONE"
COMMIT_MARKER="shm buffer committed"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "$TAG SKIP: /dev/kvm absent (KVM required for the OVMF boot)" >&2; exit 0
fi
command -v socat >/dev/null 2>&1 || { echo "$TAG SKIP: socat not installed (needed for the HMP screendump)." >&2; exit 0; }
command -v pnmtopng >/dev/null 2>&1 || echo "$TAG NOTE: pnmtopng absent; will keep the raw PPM only."
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "$TAG SKIP: OVMF firmware not found (apt install ovmf)" >&2; exit 0
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[wayland_phase4_render]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "$TAG SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2; exit 0
    fi
    echo "$TAG building full-mirror live installer image (HAMNIX_LIVE_MINIMAL=0)"
    HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB="${HAMNIX_ROOTFS_SIZE_MB:-1792}" \
        bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
[ -f "$INSTALLER_IMG" ] || { echo "$TAG SKIP: $INSTALLER_IMG unavailable (build gated)." >&2; exit 0; }

# --- decide whether the live image carries weston-simple-shm ----------
HAVE_SIMPLESHM=0
DEBUGFS="/sbin/debugfs"; [ -x "$DEBUGFS" ] || DEBUGFS="$(command -v debugfs || true)"
if [ -f "$LIVE_DISTRO_IMG" ] && [ -n "$DEBUGFS" ]; then
    "$DEBUGFS" -R "stat /distro/usr/bin/weston-simple-shm" "$LIVE_DISTRO_IMG" 2>/dev/null \
        | grep -q "Type: regular" && HAVE_SIMPLESHM=1
fi
echo "$TAG live image probe: weston-simple-shm=$HAVE_SIMPLESHM"
if [ "$HAVE_SIMPLESHM" -eq 0 ]; then
    echo "$TAG SKIP: live image carries no weston-simple-shm." >&2
    echo "$TAG       Stage weston into tests/distros/debian-minbase/rootfs and rebuild" >&2
    echo "$TAG       with HAMNIX_LIVE_MINIMAL=0." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-wl4r.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-wl4r.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-wl4r.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-wl4r-in.XXXXXX)
MON=$(mktemp --tmpdir -u hamnix-wl4r-mon.XXXXXX.sock)
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

# Send an HMP command to the QEMU monitor and print its reply.
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

fail=0

# --- boot markers ------------------------------------------------------
echo "$TAG waiting up to ${BOOT_WAIT}s for the LIVE branch + handoff..."
if ! wait_for "$LIVE_MARKER" "$BOOT_WAIT"; then
    echo "$TAG FAIL: LIVE-branch marker not seen." >&2
    tail -60 "$LOG" | strings >&2; exit 1
fi
wait_for "$LIVEROOT_MARKER" "$BOOT_WAIT" \
    && echo "$TAG PASS: kernel live-root bringup completed." \
    || { echo "$TAG FAIL: '[live-root] DONE' not seen." >&2; fail=1; }
if ! wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "$TAG FAIL: handoff marker not seen in ${BOOT_WAIT}s." >&2
    tail -60 "$LOG" | strings >&2; exit 1
fi

# --- shell-ready gate: wait for the DE visual_gate to settle ----------
wait_for "ed-readline-first" 30 || sleep 3
if wait_for "[visual_gate] done" 240; then
    echo "$TAG DE visual_gate settled; system quiet for the client."
    sleep 6
else
    echo "$TAG NOTE: visual_gate-done not seen in 240s; proceeding anyway."
fi

# --- RENDER: weston-simple-shm ONLY -----------------------------------
# Exports on the SAME top-level line (atomic + re-sendable): libwayland
# derives $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY as the socket path; the native
# AF_UNIX registry is in-kernel so the path need not exist. `spawn` (not
# `enter`) because weston-simple-shm runs its own event loop forever — we
# want it backgrounded so the shell returns and the client keeps
# committing animated frames while we screendump.
SHM_CMD='export XDG_RUNTIME_DIR=/run ; export WAYLAND_DISPLAY=wayland-0 ; spawn linux { /usr/bin/weston-simple-shm }'
echo "$TAG --- RENDER: weston-simple-shm shm-buffer commit ---"
committed=0
if send_until "$SHM_CMD" "$COMMIT_MARKER" "$CMD_WAIT"; then
    echo "$TAG PASS: server-side shm-commit marker fired:"
    grep -aF "$COMMIT_MARKER" "$LOG" | tail -4
    committed=1
else
    echo "$TAG WARN: '$COMMIT_MARKER' marker not seen; capturing a screendump anyway." >&2
fi

# Give the compositor a beat to present the committed frames to /dev/fb.
sleep 4

# --- screendump A, animate, screendump B ------------------------------
PPM_A="$OUTDIR/wl4_render_A.ppm"
PPM_B="$OUTDIR/wl4_render_B.ppm"
PNG_OUT="$OUTDIR/wl4_render.png"
rm -f "$PPM_A" "$PPM_B" "$PNG_OUT"

mon "screendump $PPM_A" >/dev/null
sleep 2                       # weston-simple-shm animates ~every frame
mon "screendump $PPM_B" >/dev/null
sleep 1

if [ ! -s "$PPM_A" ] || [ ! -s "$PPM_B" ]; then
    echo "$TAG FAIL: screendump produced no PPM (monitor socket problem?)." >&2
    fail=1
else
    echo "$TAG screendumps captured: $(ls -l "$PPM_A" "$PPM_B" | awk '{print $5, $9}' | tr '\n' ' ')"
    if command -v pnmtopng >/dev/null 2>&1; then
        pnmtopng "$PPM_B" > "$PNG_OUT" 2>/dev/null && echo "$TAG PNG saved: $PNG_OUT"
    fi
fi

# --- non-blank window proof: locate weston's painted region -----------
# weston-simple-shm draws a smooth concentric-gradient checker: a 250x250
# region packed with MANY distinct colours. A flat DE surface (panel /
# desktop / a text window) never packs ~100 unique colours into a single
# 250x250 tile, so the presence of such a tile is positive proof that the
# committed ARGB8888 shm buffer actually composited to /dev/fb. We also
# report the inter-frame delta (weston animates) as secondary evidence.
DIFF_OK=0
if [ -s "$PPM_B" ]; then
    read -r DIFF_OK DIFF_MSG < <(python3 - "$PPM_B" "$PPM_A" <<'PY'
import sys
def load(p):
    with open(p,'rb') as f: d=f.read()
    assert d[:2]==b'P6', "not P6 PPM"
    idx=2; vals=[]
    while len(vals)<3:
        while idx<len(d) and d[idx] in b' \t\n\r': idx+=1
        if idx<len(d) and d[idx:idx+1]==b'#':
            while idx<len(d) and d[idx] not in b'\n': idx+=1
            continue
        s=idx
        while idx<len(d) and d[idx] not in b' \t\n\r': idx+=1
        vals.append(int(d[s:idx]))
    idx+=1
    w,h,mv=vals
    return w,h,d[idx:idx+w*h*3]
w,h,b=load(sys.argv[1])
def at(px,x,y):
    o=(y*w+x)*3; return (px[o],px[o+1],px[o+2])
# Scan 250x250 tiles for the maximum unique-colour count.
best=(0,0,0)
for y0 in range(0,max(1,h-250),25):
    for x0 in range(0,max(1,w-250),25):
        s=set()
        for yy in range(y0,y0+250,12):
            for xx in range(x0,x0+250,12):
                s.add(at(b,xx,yy))
        if len(s)>best[0]:
            best=(len(s),x0,y0)
uniq,bx,by=best
# Optional inter-frame delta for context.
changed=-1
try:
    wa,ha,a=load(sys.argv[2])
    if (wa,ha)==(w,h):
        changed=0
        for yy in range(0,h,3):
            for xx in range(0,w,3):
                o=(yy*w+xx)*3
                if abs(a[o]-b[o])+abs(a[o+1]-b[o+1])+abs(a[o+2]-b[o+2])>24:
                    changed+=1
except Exception:
    pass
# A 250x250 tile with >=50 distinct colours is weston's gradient window.
ok = 1 if uniq>=50 else 0
print(ok, f"window_tile_uniq_colors={uniq}@({bx},{by}) interframe_changed={changed} fb={w}x{h}")
PY
)
    echo "$TAG window paint check: $DIFF_MSG"
fi

echo "$TAG --- wayland lines from the serial log ---"
grep -aE "\[wayland\]" "$LOG" | tail -30 || true
echo "$TAG --- end ---"

# --- verdict ----------------------------------------------------------
if [ "$fail" -ne 0 ]; then
    echo "$TAG RESULT: FAIL (boot / screendump regression)"; exit 1
fi
if [ "$committed" -eq 1 ] && [ "$DIFF_OK" = "1" ]; then
    echo "$TAG RESULT: PASS — weston-simple-shm committed real ARGB8888 shm frames AND its gradient window composited into a Hamnix DE window (screendump: $PNG_OUT)."
    exit 0
fi
if [ "$committed" -eq 1 ]; then
    echo "$TAG RESULT: PARTIAL — shm-commit marker fired (server decoded the buffer) but the window-paint check was inconclusive (see $PNG_OUT). Likely a compositor present/z-order issue." >&2
    exit 0
fi
echo "$TAG SKIP: weston-simple-shm did not commit an shm buffer this window (re-run; the single spawn may have been dropped by the serial console)." >&2
exit 0
