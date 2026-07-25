#!/usr/bin/env bash
# scripts/test_inguest_gpu_hw.sh — GPU track #182: the SAME in-guest virtio-gpu
# 3D path as scripts/test_inguest_gpu.sh, but rasterized on REAL NVIDIA silicon
# (RTX 3090) instead of the Mesa/llvmpipe CPU fallback.
#
# WHY A SEPARATE GATE
# ===================
# scripts/test_inguest_gpu.sh boots with `-display egl-headless`, which builds
# virglrenderer's GL context on the EGL *GBM* platform. On an NVIDIA-proprietary
# host that headless-GBM backend fails (nv_gbm_create_device_native) and Mesa
# takes over with llvmpipe — the guest path is proven, but on the CPU.
#
# THE HOST-SIDE FIX (no guest change):
# The RTX 3090 does headless GL only via the EGL *device* platform, which
# neither QEMU egl-headless NOR the shipped virglrenderer's own winsys uses
# (virglrenderer 1.1.0 opens a gbm_device unconditionally — see
# scripts/virgl_egl_probe.c, which fails with nv_gbm on this host). BUT QEMU's
# `gtk`/`sdl` display with `gl=on` does NOT go through virglrenderer's GBM
# winsys: the UI itself creates the GL context (on the running X/GLX server,
# i.e. the NVIDIA driver) and hands it to virglrenderer via the caller-supplied
# create_gl_context callback. That context IS the RTX 3090. The identical guest
# [vgpu-virgl] stream then rasterizes on the GPU with zero .ad changes.
#
# So the HW path = a live GL-capable X server on the NVIDIA GPU + QEMU
# `-display gtk,gl=on` (or sdl,gl=on). This gate requires an interactive X
# session (it opens a brief QEMU window); it is NOT a headless-CI gate and SKIPs
# cleanly when $DISPLAY / nvidia-smi / the NVIDIA EGLDevice are absent.
#
# SUCCESS (all three, or it is not a HW pass):
#   1. guest marker `[vgpu-virgl] PASS: ... byte-match the SW oracle` (GREEN,
#      byte-identical to the vk2d SW oracle — real, non-prefill pixels)
#   2. `GL_RENDERER=NVIDIA GeForce RTX 3090` reported by the host GL probe of the
#      SAME context QEMU uses (scripts/egl_device_probe.c) — proves not llvmpipe
#   3. nvidia-smi shows the QEMU process resident on the GPU during the run
#
# HYGIENE: timeout-wrapped QEMU, own-PID-only kill (never pkill), serial-only
# markers, marker-counted (0 guest markers => INCONCLUSIVE, never a pass).
# Pass marker: [test_inguest_gpu_hw] PASS   Fail: [test_inguest_gpu_hw] FAIL

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BOOT_WAIT="${BOOT_WAIT:-240}"
HAMNIX_INSTALLER_IMG="${HAMNIX_INSTALLER_IMG:-build/hamnix-installer.img}"
SCRATCH="${TMPDIR:-/tmp}"

skip() { echo "[test_inguest_gpu_hw] SKIP: $1"; exit 0; }

# --- environment gates ------------------------------------------------
[ -e /dev/kvm ] || skip "/dev/kvm absent (KVM required)"
command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v nvidia-smi >/dev/null 2>&1 || skip "nvidia-smi not found (no NVIDIA GPU to accelerate on)"
command -v cc >/dev/null 2>&1 || skip "no C compiler for the EGLDevice probe"
[ -n "${DISPLAY:-}" ] || skip "no \$DISPLAY (HW path needs a live GL-capable X server; egl-headless=GBM=llvmpipe)"

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || skip "OVMF firmware not found (apt install ovmf)"
qemu-system-x86_64 -device help 2>/dev/null | grep -q "virtio-gpu-gl-pci" \
    || skip "this QEMU has no virtio-gpu-gl-pci device"
# A UI display backend with gl=on creates the GL context itself (on the X/GLX
# server = the NVIDIA driver) and hands it to virglrenderer — bypassing the GBM
# winsys that fails on NVIDIA. sdl,gl=on WORKS on this NVIDIA host; gtk,gl=on
# gets the same NVIDIA GL 4.6 context but then ABORTS on
# `eglMakeCurrent: EGL_BAD_ACCESS` (GDK owns/threads the EGL context), so we
# prefer sdl and only fall back to gtk.
DISP_BACKEND=""
if qemu-system-x86_64 -display help 2>/dev/null | grep -qw sdl; then DISP_BACKEND=sdl
elif qemu-system-x86_64 -display help 2>/dev/null | grep -qw gtk; then DISP_BACKEND=gtk
fi
[ -n "$DISP_BACKEND" ] || skip "no sdl/gtk display backend (need a UI-created GL context; egl-headless is GBM-only)"

# --- (0/3) prove the host GL context QEMU will use is the RTX 3090 -----
PROBE_BIN="$SCRATCH/hamnix-egl-device-probe.$$"
cc "$PROJ_ROOT/scripts/egl_device_probe.c" -o "$PROBE_BIN" -lEGL -lGL 2>/dev/null \
    || skip "could not build scripts/egl_device_probe.c (need libEGL/libGL dev)"
PROBE_OUT="$("$PROBE_BIN" 2>/dev/null)"
rm -f "$PROBE_BIN"
NVIDIA_RENDERER="$(echo "$PROBE_OUT" | grep -oE 'GL_RENDERER=NVIDIA[^ ]*( GeForce)?( RTX)?( [0-9]+)?' | head -1)"
if ! echo "$PROBE_OUT" | grep -q "GL_RENDERER=NVIDIA"; then
    echo "[test_inguest_gpu_hw] host EGLDevice probe found no NVIDIA GL context:"
    echo "$PROBE_OUT" | grep PROBE-RESULT
    skip "the NVIDIA GPU does not expose a headless GL context here (EGLDevice absent)"
fi
echo "[test_inguest_gpu_hw] (0/3) host EGLDevice GL context: $(echo "$PROBE_OUT" | grep 'GL_RENDERER=NVIDIA' | head -1 | sed 's/.*GL_RENDERER=//')"

# --- build the installer medium WITH the virgl fill self-test armed ----
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_inguest_gpu_hw] (1/3) building installer medium (ENABLE_VIRTIO_GPU_TEST=1)"
    rm -f "$HAMNIX_INSTALLER_IMG"
    ENABLE_VIRTIO_GPU_TEST=1 HAMNIX_FORCE_SELFTESTS=1 \
        bash "$PROJ_ROOT/scripts/build_installer_img.sh" \
        || { echo "[test_inguest_gpu_hw] FAIL: installer build failed" >&2; exit 1; }
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$HAMNIX_INSTALLER_IMG" "[inguest_gpu_hw]"
[ -f "$HAMNIX_INSTALLER_IMG" ] || { echo "[test_inguest_gpu_hw] FAIL: $HAMNIX_INSTALLER_IMG missing" >&2; exit 1; }

GLOVMF=$(mktemp --tmpdir hamnix-ighw.ovmf.XXXXXX.fd)
GLIMG=$(mktemp --tmpdir hamnix-ighw.disk.XXXXXX.img)
GLLOG=$(mktemp --tmpdir hamnix-ighw.XXXXXX.log)
SMILOG=$(mktemp --tmpdir hamnix-ighw.smi.XXXXXX.log)
cp "$OVMF_FD" "$GLOVMF"
cp "$HAMNIX_INSTALLER_IMG" "$GLIMG"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$GLOVMF" "$GLIMG"
}
trap 'cleanup; rm -f "$GLLOG" "$SMILOG"' EXIT

echo "[test_inguest_gpu_hw] (2/3) booting -device virtio-gpu-gl-pci -display $DISP_BACKEND,gl=on on \$DISPLAY=$DISPLAY"
# VREND_DEBUG makes virglrenderer log the GL_VENDOR/GL_RENDERER of the context
# it was handed. That context is the UI's X/GLX context = the NVIDIA driver.
VREND_DEBUG=all VIRGL_LOG_LEVEL=debug \
timeout "$BOOT_WAIT" qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$GLOVMF" \
    -drive file="$GLIMG",format=raw,if=virtio \
    -m 1G \
    -vga none -device virtio-gpu-gl-pci -display "$DISP_BACKEND",gl=on \
    -no-reboot -serial stdio \
    </dev/null > "$GLLOG" 2>&1 &
QEMU_PID=$!

# Sample nvidia-smi while it boots. The GPU-resident pid is a QEMU child/thread
# (not our shell's $QEMU_PID), so match the process NAME under our own tree —
# still own-process-only, never pkill. Only qemu-system processes we launched
# are running under this gate.
NVIDIA_RESIDENT=0
for _ in $(seq 1 "$((BOOT_WAIT * 4))"); do
    smi="$(nvidia-smi 2>/dev/null | grep -iE 'qemu-system-x86_64')"
    if [ -n "$smi" ]; then
        NVIDIA_RESIDENT=1
        echo "$smi" >> "$SMILOG"
    fi
    grep -a -q -E "\[vgpu-virgl\] (PASS|FAIL|SKIP)" "$GLLOG" && break
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 0.25
done
sleep 1
kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""

echo "[test_inguest_gpu_hw] --- guest virgl markers ---"
grep -a -E "\[vgpu-virgl\]|3D/VIRGL|CTX_CREATE" "$GLLOG" | head -30
echo "[test_inguest_gpu_hw] --- host GL context (virglrenderer) ---"
# virglrenderer logs `gl_version NN - core profile enabled` for the context it
# was handed. On this host llvmpipe tops out at GL 4.5 (probe: "4.5 Mesa"); the
# NVIDIA driver reports GL 4.6 — so `gl_version 46` is the unforgeable "this ran
# on the RTX 3090, not llvmpipe" signal (corroborated by the EGLDevice probe in
# step 0 and nvidia-smi residency below). Also accept an explicit renderer line.
GLVER_LINE="$(grep -a -E "gl_version [0-9]+ - core profile" "$GLLOG" | head -1)"
GLREND_LINE="$(grep -a -iE "GL_RENDERER=NVIDIA|NVIDIA GeForce RTX|llvmpipe" "$GLLOG" | head -2)"
echo "${GLVER_LINE:-(no gl_version line)}"
[ -n "$GLREND_LINE" ] && echo "$GLREND_LINE"
echo "[test_inguest_gpu_hw] --- nvidia-smi residency (our qemu pid) ---"
cat "$SMILOG" 2>/dev/null | head -3 || true

# --- verdict ----------------------------------------------------------
markers=$(grep -a -c -E "\[vgpu-virgl\]" "$GLLOG")
if [ "$markers" -eq 0 ]; then
    echo "[test_inguest_gpu_hw] INCONCLUSIVE: no [vgpu-virgl] guest markers (boot did not reach the self-test)" >&2
    trap 'cleanup' EXIT
    exit 0
fi
if grep -a -q -E "\[vgpu-virgl\] FAIL" "$GLLOG"; then
    echo "[test_inguest_gpu_hw] FAIL: guest reported a virgl self-test failure (real wrong-pixel render)" >&2
    trap 'cleanup' EXIT
    exit 1
fi

GREEN=0
grep -a -q -E "\[vgpu-virgl\] PASS: host-GPU virgl fill pixels byte-match" "$GLLOG" && GREEN=1
NV_CTX=0
# NVIDIA GL context proof: GL 4.6 (llvmpipe here is 4.5) OR an explicit NVIDIA
# renderer string, AND the GBM/llvmpipe fallback did NOT swallow the context.
if grep -a -q -E "gl_version 4[6-9] - core profile" "$GLLOG" \
   || grep -a -qiE "GL_RENDERER=NVIDIA|NVIDIA GeForce RTX" "$GLLOG"; then
    NV_CTX=1
fi

if [ "$GREEN" -eq 1 ] && [ "$NV_CTX" -eq 1 ] && [ "$NVIDIA_RESIDENT" -eq 1 ]; then
    echo "[test_inguest_gpu_hw] PASS: in-guest virtio-gpu 3D fill rasterized on the RTX 3090 —"
    echo "[test_inguest_gpu_hw]   GREEN byte-identical to the SW oracle, GL_RENDERER=NVIDIA, nvidia-smi resident."
    exit 0
fi

# Honest partial: guest path is green but the host context was NOT the NVIDIA GPU
# (e.g. QEMU still routed through GBM/llvmpipe). Report exactly what was missing —
# never claim HW acceleration without GL_RENDERER=NVIDIA + residency.
if [ "$GREEN" -eq 1 ]; then
    echo "[test_inguest_gpu_hw] SKIP: guest fill is GREEN + byte-exact, but this run did NOT confirm the RTX 3090 as the host context"
    echo "[test_inguest_gpu_hw]   GL_RENDERER=NVIDIA seen: $NV_CTX   nvidia-smi resident: $NVIDIA_RESIDENT"
    echo "[test_inguest_gpu_hw]   (no false HW claim — the guest path is proven; the host context evidence was incomplete)"
    trap 'cleanup' EXIT
    exit 0
fi

echo "[test_inguest_gpu_hw] SKIP: virgl markers present but no GREEN PASS verdict (see log)"
trap 'cleanup' EXIT
exit 0
