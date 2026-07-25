#!/usr/bin/env bash
# scripts/test_wayland_gl_egl.sh — Wayland-passthrough GL rung: a REAL Debian
# weston-simple-egl (raw wl_egl_window + GLES2, UNMODIFIED) renders its
# spinning-triangle frames on the native in-kernel Wayland compositor
# (linux_abi/wayland.ad) using Mesa SOFTWARE OpenGL (llvmpipe/swrast) drawing
# into wl_shm buffers — NO GPU, NO /dev/dri, NO GBM device. This proves the
# software-GL/EGL stack works end-to-end in the GL-free Linux namespace, the
# unlock the parked Firefox render thread needs.
#
# THE PATH: the compositor advertises wl_shm only (no wl_drm / linux-dmabuf),
# so Mesa's EGL Wayland platform falls back to dri2_initialize_wayland_swrast:
# llvmpipe rasterizes into a wl_shm pool buffer and commits it. Requires the
# Mesa closure staged by scripts/stage_mesa_gl.sh (swrast_dri.so + the gallium
# megadriver + LLVM + libEGL/glvnd + weston-simple-egl).
#
# Flow: boot the full-mirror live image (KVM/OVMF, 4G); spawn weston-simple-egl
# in the Linux ns with LIBGL_ALWAYS_SOFTWARE=1 / GALLIUM_DRIVER=llvmpipe /
# EGL_PLATFORM=wayland; wait for the server-side "shm buffer committed" marker
# (= EGL init + first GL frame mapped); screendump; assert the committed
# window region is a non-flat, multi-colour GL frame.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, the image, socat, or
# weston-simple-egl (the Mesa staging) is unavailable.
set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
LIVE_DISTRO_IMG="${LIVE_DISTRO_IMG:-build/hamnix-live-distro.img}"
BOOT_WAIT="${BOOT_WAIT:-400}"
CMD_WAIT="${CMD_WAIT:-240}"
QEMU_MEM="${QEMU_MEM:-4G}"
OUTDIR="${OUTDIR:-$PROJ_ROOT}"
TAG="[test_wl_gl_egl]"

LIVE_MARKER="booting LIVE environment"
HANDOFF_MARKER="handing off to interactive shell"
COMMIT_MARKER="shm buffer committed"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then echo "$TAG SKIP: /dev/kvm absent." >&2; exit 0; fi
command -v socat >/dev/null 2>&1 || { echo "$TAG SKIP: socat absent." >&2; exit 0; }
command -v pnmtopng >/dev/null 2>&1 || echo "$TAG NOTE: pnmtopng absent; raw PPM only."
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || { echo "$TAG SKIP: OVMF not found." >&2; exit 0; }
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$INSTALLER_IMG" "[wayland_gl_egl]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "$TAG SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2; exit 0
    fi
    echo "$TAG building full-mirror live installer image (HAMNIX_LIVE_MINIMAL=0)"
    HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB="${HAMNIX_ROOTFS_SIZE_MB:-2048}" \
        bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
[ -f "$INSTALLER_IMG" ] || { echo "$TAG SKIP: $INSTALLER_IMG unavailable." >&2; exit 0; }

# --- decide whether the live image carries weston-simple-egl + Mesa ----
HAVE_GL=0
DEBUGFS="/sbin/debugfs"; [ -x "$DEBUGFS" ] || DEBUGFS="$(command -v debugfs || true)"
if [ -f "$LIVE_DISTRO_IMG" ] && [ -n "$DEBUGFS" ]; then
    "$DEBUGFS" -R "stat /distro/usr/bin/weston-simple-egl" "$LIVE_DISTRO_IMG" 2>/dev/null \
        | grep -q "Type: regular" && HAVE_GL=1
fi
echo "$TAG live image probe: weston-simple-egl=$HAVE_GL"
if [ "$HAVE_GL" -eq 0 ]; then
    echo "$TAG SKIP: live image carries no weston-simple-egl (Mesa GL not staged)." >&2
    echo "$TAG       Run scripts/stage_weston_term.sh then scripts/stage_mesa_gl.sh," >&2
    echo "$TAG       then rebuild with HAMNIX_LIVE_MINIMAL=0 scripts/build_installer_img.sh." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-wlgl.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-wlgl.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-wlgl.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-wlgl-in.XXXXXX)
MON=$(mktemp --tmpdir -u hamnix-wlgl-mon.XXXXXX.sock)
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
send() { printf '%s\n' "$1" >&3; }
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

echo "$TAG waiting up to ${BOOT_WAIT}s for LIVE branch + handoff..."
if ! wait_for "$LIVE_MARKER" "$BOOT_WAIT"; then
    echo "$TAG FAIL: LIVE-branch marker not seen." >&2; tail -60 "$LOG" | strings >&2; exit 1
fi
if ! wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "$TAG FAIL: handoff marker not seen." >&2; tail -60 "$LOG" | strings >&2; exit 1
fi
wait_for "ed-readline-first" 30 || sleep 3
if wait_for "[visual_gate] done" 240; then
    echo "$TAG DE visual_gate settled; quiet for the client."; sleep 6
else
    echo "$TAG NOTE: visual_gate-done not seen in 240s; proceeding."
fi

# --- RENDER: weston-simple-egl (Mesa llvmpipe over wl_shm) -------------
# KEEP THIS COMMAND SHORT. hamsh's serial console wraps typed input at ~262
# columns; a longer line silently truncates the trailing `spawn linux { ... }`
# clause so the client never launches (the same trap documented in
# test_wayland_firefox.sh). Four exports fit comfortably: XDG_RUNTIME_DIR +
# WAYLAND_DISPLAY point Mesa's EGL Wayland platform at the compositor socket;
# LIBGL_ALWAYS_SOFTWARE forces the software path; GALLIUM_DRIVER=llvmpipe picks
# the llvmpipe swrast driver. The compositor advertises wl_shm only, so Mesa
# takes dri2_initialize_wayland_swrast automatically (no /dev/dri, no GBM). The
# remaining knobs (swrast override, single-thread, shader-cache-disable) are
# Mesa defaults / non-essential and are dropped to stay under the wrap column.
pre_commits=$(grep -acF "$COMMIT_MARKER" "$LOG" 2>/dev/null | head -1)
GL_CMD='export XDG_RUNTIME_DIR=/run ; export WAYLAND_DISPLAY=wayland-0 ; export LIBGL_ALWAYS_SOFTWARE=1 ; export GALLIUM_DRIVER=llvmpipe ; spawn linux { /usr/bin/weston-simple-egl }'
echo "$TAG --- RENDER: launch weston-simple-egl (llvmpipe/swrast) ---"
committed=0
if send_until "$GL_CMD" "$COMMIT_MARKER" "$CMD_WAIT"; then
    post_commits=$(grep -acF "$COMMIT_MARKER" "$LOG" 2>/dev/null | head -1)
    if [ "${post_commits:-0}" -gt "${pre_commits:-0}" ]; then
        echo "$TAG PASS: GL client committed a wl_shm buffer (EGL init + first frame)."
        grep -aF "$COMMIT_MARKER" "$LOG" | tail -3
        committed=1
    fi
else
    echo "$TAG WARN: '$COMMIT_MARKER' not seen; screendumping + dumping GL diag." >&2
fi
sleep 4

WID="$(grep -aF "$COMMIT_MARKER" "$LOG" | tail -1 | grep -aoE 'wid [0-9]+' | awk '{print $2}')"
echo "$TAG weston-simple-egl window id: ${WID:-<unknown>}"

PPM="$OUTDIR/wl_gl_egl.ppm"
PNG="$OUTDIR/wl_gl_egl.png"
rm -f "$PPM" "$PNG"
mon "screendump $PPM" >/dev/null; sleep 1
if command -v pnmtopng >/dev/null 2>&1 && [ -s "$PPM" ]; then
    pnmtopng "$PPM" > "$PNG" 2>/dev/null && echo "$TAG PNG (GL frame): $PNG"
fi

echo "$TAG --- Mesa/EGL/GL diagnostic lines from serial ---"
grep -aiE "llvmpipe|swrast|libEGL|EGL_|eglInit|MESA|gallium|dri2|GLESv2|libgbm|renderD|no matching|failed to|not provide|assert|abort|segfault|SIGSEGV|NX exec" "$LOG" | tail -40 || true
echo "$TAG --- wayland lines ---"
grep -aE "\[wayland\]|weston-simple|shm buffer" "$LOG" | tail -20 || true

# --- proof: the committed GL window region is a non-flat GL frame ------
RENDER_OK=0
if [ -s "$PPM" ]; then
    RENDER_OK=$(python3 - "$PPM" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
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
w,h,mv=vals; px=d[idx:idx+w*h*3]
best=0
for y0 in range(0,max(1,h-120),20):
    for x0 in range(0,max(1,w-200),20):
        sset=set()
        for yy in range(y0,y0+120,8):
            for xx in range(x0,x0+200,8):
                o=(yy*w+xx)*3; sset.add((px[o],px[o+1],px[o+2]))
        best=max(best,len(sset))
print(1 if best>=12 else 0)
PY
)
fi
echo "$TAG render check: multi-colour GL tile = ${RENDER_OK}"

echo "$TAG --- verdict ---"
if [ "$committed" = "1" ] && [ "${RENDER_OK:-0}" = "1" ]; then
    echo "$TAG RESULT: PASS — Mesa software GL (llvmpipe/swrast) rendered a GL frame on the compositor ($PNG)."
    exit 0
fi
if [ "$committed" = "1" ]; then
    echo "$TAG RESULT: PARTIAL — GL client committed a buffer but the frame region was flat (see $PNG)." >&2
    exit 1
fi
echo "$TAG RESULT: FAIL — weston-simple-egl did not commit a GL frame." >&2
echo "$TAG   EGL init likely failed in the ns; see the Mesa/EGL diagnostic lines above." >&2
exit 1
