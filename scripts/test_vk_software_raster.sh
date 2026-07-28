#!/usr/bin/env bash
# scripts/test_vk_software_raster.sh — GPU track #181, Phase 0.
#
# Native Vulkan-shaped graphics spine with a NATIVE software rasterizer,
# presenting to /dev/fb. ZERO Linux dependency. This test boots the
# kernel once with /etc/vk-test planted (ENABLE_VK_TEST=1); init/main.ad
# at boot:37.vk drives the whole Vulkan-shaped API
# (instance/device/queue/memory/buffer/image/command-buffer/submit/
# present) through lib/vk's software rasterizer to render a depth-tested
# two-triangle scene into an off-screen R8G8B8A8 color image + D32 depth
# image, then presents it.
#
# UNFORGEABLE assertions the kernel self-test prints as [vk] lines, all
# of which this script requires:
#   * corner pixel (0,0)      == the clear color           -> clear ran
#   * far-only pixel (8,55)    carries the FAR triangle's gradient
#                              -> per-vertex color interpolation ran
#   * overlap pixel (40,30)    shows the NEAR triangle's palette
#                              -> the depth test arbitrated occlusion
#   * a deterministic FNV-1a checksum of the whole color image equals a
#     golden constant pinned in lib/vk/vk_selftest.ad
#   * the spine PASS banner
#
# Asserting actual pixel values at known coordinates (corner == clear,
# triangle interior == interpolated color, occluded == nearer triangle)
# proves the rasterizer + depth test really ran — not a precomputed
# bitmap.
#
# Pass marker:  [test_vk] PASS
# Fail marker:  [test_vk] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_vk] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_vk] (2/3) Build kernel with /etc/vk-test marker"
INIT_ELF=build/user/init.elf ENABLE_VK_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_vk] (3/3) Boot QEMU and run the Vulkan-spine self-test"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_vk] --- vk self-test output ---"
grep -E "\[vk\]" "$LOG" || true
echo "[test_vk] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_vk] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -qF "[vk] FAIL" "$LOG"; then
    echo "[test_vk] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_vk] PASS: $label"
    else
        echo "[test_vk] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "clear color at corner"            "[vk] PASS: corner pixel is clear color"
check "far-only interpolated gradient"   "[vk] PASS: far-only pixel carries far triangle gradient"
check "depth test chose nearer triangle" "[vk] PASS: overlap shows NEAR triangle (depth test won)"
check "color image checksum matches golden" "[vk] PASS: color image checksum matches golden"
check "present advanced pixel count"     "[vk] PASS: present advanced pixel count by W*H"
check "spine self-test complete"         "[vk] PASS: Phase-0 spine self-test complete"

if [ "$fail" -ne 0 ]; then
    echo "[test_vk] FAIL"
    exit 1
fi

echo "[test_vk] PASS — native Vulkan-shaped software rasterizer rendered a depth-tested scene and presented it"
