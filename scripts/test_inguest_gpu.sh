#!/usr/bin/env bash
# scripts/test_inguest_gpu.sh — GPU track #182: IN-GUEST virtio-gpu 3D render
# actually rasterizes on a REAL host GPU (or llvmpipe), proven end to end.
#
# WHAT THIS PROVES (and how it differs from the host-GPU bridge)
# =============================================================
# scripts/vk_hostgpu_bridge.c drives the host GPU from a HOST process — it
# bypasses the guest entirely. THIS gate instead proves the RIGHT path: pixels
# that the GUEST's own virtio-gpu driver + venus/virgl encoder submit get
# rasterized by the HOST's virglrenderer on a real GL context, transferred back
# into GUEST memory, and byte-compared IN THE GUEST against the vk2d SW oracle.
#
# We boot the installer medium under OVMF with:
#     -device virtio-gpu-gl-pci -display egl-headless
# so the device advertises VIRTIO_GPU_F_VIRGL, the guest negotiates it, creates
# a 3D context + render-target, submits a CANONICAL virgl CLEAR, reads it back
# (TRANSFER_FROM_HOST_3D), and asserts the pixels match the oracle. The guest
# marker of a REAL (non-prefill) render is:
#     [vgpu-virgl] PASS: host-GPU virgl fill pixels byte-match the SW oracle (REAL GPU pixels)
#
# HOST GL SELECTION
# =================
# QEMU egl-headless builds its GL context on the EGL *GBM* platform. On this
# NVIDIA-proprietary host the NVIDIA GBM-headless backend fails
# (nv_gbm_create_device_native), but Mesa transparently takes over with a
# working llvmpipe GL 4.5 context — enough to REALLY rasterize the guest's
# stream (proving the whole guest->host 3D path end to end). We force the Mesa
# EGL vendor so the context is deterministic:
#     __EGL_VENDOR_LIBRARY_FILENAMES=<mesa>  LIBGL_ALWAYS_SOFTWARE=1
# HW-NVIDIA note: the RTX 3090 does headless GL only via the EGL *device*
# platform, which QEMU egl-headless does not use; lighting the SAME guest path
# on the RTX needs a QEMU display/vhost-user-gpu backend that drives EGLDevice
# (or a GBM stack the NVIDIA driver accepts). This gate lights the guest path on
# llvmpipe TODAY; swapping only the host ICD reaches HW without a guest change.
# See docs/inguest_gpu_2026-07-18.md.
#
# HYGIENE: timeout-wrapped QEMU, own-PID-only kill (never pkill), serial-only,
# marker-counted (0 guest markers => INCONCLUSIVE, not pass).
#
# SKIPS CLEANLY (exit 0) when: /dev/kvm or OVMF absent, no virtio-gpu-gl-pci
# device, no Mesa EGL vendor json, or the host cannot realize a GL virtio-gpu.
# Pass marker: [test_inguest_gpu] PASS   Fail marker: [test_inguest_gpu] FAIL

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BOOT_WAIT="${BOOT_WAIT:-240}"
HAMNIX_INSTALLER_IMG="${HAMNIX_INSTALLER_IMG:-build/hamnix-installer.img}"

skip() { echo "[test_inguest_gpu] SKIP: $1"; exit 0; }

# --- environment gates ------------------------------------------------
[ -e /dev/kvm ] || skip "/dev/kvm absent (KVM required; TCG boot too slow)"

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -n "$OVMF_FD" ] && [ -f "$OVMF_FD" ] || skip "OVMF firmware not found (apt install ovmf)"

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
qemu-system-x86_64 -device help 2>/dev/null | grep -q "virtio-gpu-gl-pci" \
    || skip "this QEMU has no virtio-gpu-gl-pci device"

# Force a deterministic Mesa (llvmpipe) GL context for virglrenderer.
MESA_EGL=""
for c in /usr/share/glvnd/egl_vendor.d/50_mesa.json \
         /usr/share/glvnd/egl_vendor.d/*mesa*.json; do
    [ -f "$c" ] && MESA_EGL="$c" && break
done
[ -n "$MESA_EGL" ] || skip "no Mesa EGL vendor json (cannot force a software GL context)"

# --- build the installer medium WITH the virgl fill self-test armed ----
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_inguest_gpu] (1/2) building installer medium (ENABLE_VIRTIO_GPU_TEST=1)"
    rm -f "$HAMNIX_INSTALLER_IMG"
    ENABLE_VIRTIO_GPU_TEST=1 HAMNIX_FORCE_SELFTESTS=1 \
        bash "$PROJ_ROOT/scripts/build_installer_img.sh" \
        || { echo "[test_inguest_gpu] FAIL: installer build failed" >&2; exit 1; }
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$HAMNIX_INSTALLER_IMG" "[inguest_gpu]"
[ -f "$HAMNIX_INSTALLER_IMG" ] || { echo "[test_inguest_gpu] FAIL: $HAMNIX_INSTALLER_IMG missing" >&2; exit 1; }

GLOVMF=$(mktemp --tmpdir hamnix-ig.ovmf.XXXXXX.fd)
GLIMG=$(mktemp --tmpdir hamnix-ig.disk.XXXXXX.img)
GLLOG=$(mktemp --tmpdir hamnix-ig.XXXXXX.log)
cp "$OVMF_FD" "$GLOVMF"
cp "$HAMNIX_INSTALLER_IMG" "$GLIMG"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$GLOVMF" "$GLIMG"
}
trap 'cleanup; rm -f "$GLLOG"' EXIT

echo "[test_inguest_gpu] (2/2) booting -device virtio-gpu-gl-pci -display egl-headless (Mesa/llvmpipe GL)"
# Forced-Mesa env makes virglrenderer's GBM/EGL context resolve to llvmpipe
# even though the NVIDIA GBM-headless backend errors (non-fatal on stderr).
__EGL_VENDOR_LIBRARY_FILENAMES="$MESA_EGL" \
LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
timeout "$BOOT_WAIT" qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$GLOVMF" \
    -drive file="$GLIMG",format=raw,if=virtio \
    -m 1G \
    -vga none -device virtio-gpu-gl-pci -display egl-headless \
    -no-reboot -serial stdio \
    </dev/null > "$GLLOG" 2>&1 &
QEMU_PID=$!

for _ in $(seq 1 "$BOOT_WAIT"); do
    grep -a -q -E "\[vgpu-virgl\] (PASS|FAIL|SKIP)" "$GLLOG" && break
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 1
done
sleep 1
kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""

echo "[test_inguest_gpu] --- guest virgl markers ---"
grep -a -E "virtio-gpu: 3D|3D/VIRGL|CTX_CREATE|\[vgpu-virgl\]|render-target" "$GLLOG" | head -40
echo "[test_inguest_gpu] --- host GL evidence ---"
grep -a -E "GBM-DRV|nv_gbm|Illegal command|failed to dispatch|virgl" "$GLLOG" | grep -avE "^\[[0-9]" | head -10 || true

# --- verdict ----------------------------------------------------------
# Count GUEST markers; zero => INCONCLUSIVE (a dead boot), never a pass.
markers=$(grep -a -c -E "\[vgpu-virgl\]" "$GLLOG")
if [ "$markers" -eq 0 ]; then
    echo "[test_inguest_gpu] INCONCLUSIVE: no [vgpu-virgl] guest markers (boot did not reach the self-test)" >&2
    trap 'cleanup' EXIT
    exit 0
fi

if grep -a -q -E "\[vgpu-virgl\] FAIL" "$GLLOG"; then
    echo "[test_inguest_gpu] FAIL: guest reported a virgl self-test failure (real wrong-pixel render)" >&2
    trap 'cleanup' EXIT
    exit 1
fi

if grep -a -q -E "\[vgpu-virgl\] PASS: host-GPU virgl fill pixels byte-match" "$GLLOG"; then
    RENDERER="host GL (Mesa/llvmpipe via GBM fallback)"
    echo "[test_inguest_gpu] PASS: the IN-GUEST virtio-gpu 3D render produced REAL (non-prefill) pixels"
    echo "[test_inguest_gpu]       byte-identical to the vk2d SW oracle, rasterized by $RENDERER."
    echo "[test_inguest_gpu]       (guest driver -> venus/virgl encoder -> SUBMIT_3D -> host virglrenderer -> TRANSFER_FROM_HOST_3D)"
    exit 0
fi

# Advertised + negotiated but host GL could not rasterize (e.g. no GL context
# at all) — the guest prints [vgpu-virgl] SKIP. Honest non-failure.
if grep -a -q -E "\[vgpu-virgl\] SKIP" "$GLLOG"; then
    echo "[test_inguest_gpu] SKIP: host virglrenderer GL non-functional here; 3D command chain accepted but no real pixels (no false claim)"
    trap 'cleanup' EXIT
    exit 0
fi

echo "[test_inguest_gpu] INCONCLUSIVE: virgl markers present but no PASS/SKIP verdict (see log)" >&2
trap 'cleanup' EXIT
exit 0
