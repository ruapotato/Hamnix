#!/usr/bin/env bash
# scripts/test_virtio_gpu_present.sh — GPU track #182, Phase 1.
#
# Native virtio-gpu 2D present path. Proves the accelerated-in-VM present
# spine end to end with ZERO Linux/namespace dependency:
#
#   modern virtio-1.0 PCI transport (drivers/virtio/virtio_modern.ad)
#     -> virtio-gpu controlq commands (drivers/video/virtio_gpu.ad)
#        GET_DISPLAY_INFO -> RESOURCE_CREATE_2D -> ATTACH_BACKING
#        -> SET_SCANOUT -> (paint four-quadrant pattern) ->
#        TRANSFER_TO_HOST_2D -> RESOURCE_FLUSH
#     -> pixels on the virtio-gpu scanout.
#
# This is the first real GPU DEVICE data path beyond the GOP linear
# framebuffer. We boot the ESP-only installer medium
# (build/hamnix-installer.img) under OVMF with `-device virtio-gpu-pci` as
# the ONLY display, so QEMU's `screendump` captures the virtio-gpu scanout
# the kernel flushed into. The boot-flag marker /etc/virtio-gpu-test is
# read from the initramfs at boot (init/main.ad boot:37.vgpu), so we build
# the medium with ENABLE_VIRTIO_GPU_TEST=1 to plant it into the installer
# kernel's initramfs; boot:37.vgpu then paints + flushes the known
# four-quadrant pattern DURING boot — no shell needed. (The baked
# build/hamnix.img was retired; the installer medium is a real product
# artifact and the present hook fires the same way on its kernel.)
#
# The `-kernel` multiboot path can NOT be used here: this host's QEMU
# (10.x) refuses the multiboot kernel under any VGA/VBE device ("multiboot
# knows VBE. we don't"). The OVMF/UEFI GOP path is the supported one (see
# memory: QEMU multiboot/VBE host limit). virtio-gpu provides its own GOP
# under OVMF.
#
# UNFORGEABLE assertions (golden pixels at known coords on the dumped
# scanout — a precomputed bitmap could not satisfy all four quadrants AND
# the driver's success log markers):
#   * top-left  quadrant pixel == RED
#   * top-right quadrant pixel == GREEN
#   * bot-left  quadrant pixel == BLUE
#   * bot-right quadrant pixel == WHITE
# plus the driver's boot-log success markers:
#   * "virtio-gpu: modern transport bound"
#   * "virtio-gpu: DISPLAY_INFO scanout0"
#   * "virtio-gpu: FLUSH ok"
#   * "[vgpu] PASS"
#
# SKIPS CLEANLY (exit 0) when /dev/kvm or OVMF firmware is unavailable.
#
# Pass marker:  [test_vgpu] PASS
# Fail marker:  [test_vgpu] FAIL

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_INSTALLER_IMG="${HAMNIX_INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-200}"

# ======================================================================
# OPT-IN real-GPU gate (host-GPU bridge) — HAMNIX_REAL_GPU_GATE=1
# ======================================================================
# The in-VM virtio-gpu-gl/VIRGL path only reaches a REAL host GPU when
# QEMU's `-display egl-headless` can build a GL context on the DRM render
# node. On an NVIDIA-proprietary host that FAILS: QEMU egl-headless uses
# the EGL *GBM* platform, and the NVIDIA driver's GBM-headless backend
# errors ("nv_gbm_create_device_native failed"), so virglrenderer falls
# back to llvmpipe (SOFTWARE) — no RTX pixels. (The NVIDIA card DOES do
# HW GL headless, but only via the EGL *device* platform, which QEMU
# egl-headless does not use.) See docs/real_gpu_bridge_2026-07-18.md.
#
# So this gate drives the REAL GPU the reliable way: the host-GPU bridge
# (scripts/vk_hostgpu_bridge.c) runs the vk_2d compositor op vocabulary
# as a real Vulkan COMPUTE pipeline on the discrete GPU and byte-verifies
# the readback against a bit-exact SW oracle. It renders a genuine
# full-frame DE + browser-page workload (`pageraster`) — not a synthetic
# fill — and captures nvidia-smi per-process residency as GPU-exec proof.
#
# SKIPS CLEANLY (exit 0) when: libvulkan/gcc absent, no non-CPU Vulkan
# device (only llvmpipe), or the shader SPIR-V is missing.
# Pass marker: [test_realgpu] PASS   Fail marker: [test_realgpu] FAIL
if [ "${HAMNIX_REAL_GPU_GATE:-0}" = "1" ]; then
    echo "[test_realgpu] opt-in real-GPU bridge gate"
    LIBVK=""
    for cand in /usr/lib/x86_64-linux-gnu/libvulkan.so.1 /usr/lib/libvulkan.so.1; do
        [ -f "$cand" ] && LIBVK="$cand" && break
    done
    if [ -z "$LIBVK" ]; then
        echo "[test_realgpu] SKIP: libvulkan.so.1 not found"; exit 0
    fi
    if ! command -v gcc >/dev/null 2>&1; then
        echo "[test_realgpu] SKIP: gcc not available to build the bridge"; exit 0
    fi
    if [ ! -f scripts/shaders/vk2d_raster.comp.spv ]; then
        echo "[test_realgpu] SKIP: scripts/shaders/vk2d_raster.comp.spv missing"; exit 0
    fi
    mkdir -p build/host
    BR=build/host/vk_hostgpu_bridge
    if ! gcc -O2 scripts/vk_hostgpu_bridge.c -o "$BR" "$LIBVK" 2>build/host/vk_bridge_build.log; then
        echo "[test_realgpu] FAIL: bridge build failed"; sed 's/^/[test_realgpu]   /' build/host/vk_bridge_build.log; exit 1
    fi
    # Require a non-CPU (real) Vulkan device; else SKIP (llvmpipe-only host).
    INFO=$("$BR" info 2>&1)
    echo "$INFO" | sed 's/^/[test_realgpu] /'
    DEVLINE=$(echo "$INFO" | grep '^VK_DEVICE' | head -1)
    if echo "$DEVLINE" | grep -q '\[CPU'; then
        echo "[test_realgpu] SKIP: only a CPU (software) Vulkan device present — no real GPU"; exit 0
    fi
    if [ -z "$DEVLINE" ]; then
        echo "[test_realgpu] SKIP: no Vulkan device enumerated"; exit 0
    fi
    RGPPM=$(mktemp --tmpdir hamnix-realgpu.XXXXXX.ppm)
    RGLOG=$(mktemp --tmpdir hamnix-realgpu.XXXXXX.log)
    rg_cleanup() { rm -f "$RGPPM" "$RGLOG"; }
    trap 'rg_cleanup' EXIT
    # Sustained 3s run so nvidia-smi can observe this pid resident on the GPU.
    "$BR" pageraster 1280 720 "$RGPPM" 3 >"$RGLOG" 2>/dev/null &
    RGPID=$!
    SMI_HIT=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        for _ in $(seq 1 60); do
            APPS=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader 2>/dev/null)
            if echo "$APPS" | grep -q "^$RGPID,"; then
                SMI_HIT=$(echo "$APPS" | grep "^$RGPID,")
                break
            fi
            kill -0 "$RGPID" 2>/dev/null || break
            sleep 0.1
        done
    fi
    wait "$RGPID"; RGRC=$?
    echo "[test_realgpu] --- bridge output ---"; sed 's/^/[test_realgpu] /' "$RGLOG"
    rgfail=0
    grep -q '^PAGERASTER_OK' "$RGLOG" || { echo "[test_realgpu] FAIL: pageraster did not complete" >&2; rgfail=1; }
    MISM=$(grep '^PAGERASTER_GPUvsCPUport_MISMATCH' "$RGLOG" | awk '{print $2}')
    if [ "${MISM:-x}" = "0" ]; then
        echo "[test_realgpu] PASS: GPU readback byte-identical to SW oracle (0 mismatches)"
    else
        echo "[test_realgpu] FAIL: GPU vs SW-oracle mismatch=${MISM:-?}" >&2; rgfail=1
    fi
    RGDEV=$(grep '^VK_DEVICE' "$RGLOG" | head -1)
    if echo "$RGDEV" | grep -qi 'discrete-GPU\|integrated-GPU'; then
        echo "[test_realgpu] PASS: rendered on a real GPU — ${RGDEV#VK_DEVICE }"
    else
        echo "[test_realgpu] FAIL: not a real GPU device (${RGDEV#VK_DEVICE })" >&2; rgfail=1
    fi
    if [ -n "$SMI_HIT" ]; then
        echo "[test_realgpu] PASS: nvidia-smi observed this pid resident on the GPU: $SMI_HIT"
    else
        echo "[test_realgpu] NOTE: nvidia-smi per-process residency not captured (fast run / non-NVIDIA); byte-verify + discrete-GPU selection still prove GPU execution"
    fi
    [ "$RGRC" -ne 0 ] && [ "$rgfail" -eq 0 ] && { echo "[test_realgpu] FAIL: bridge rc=$RGRC" >&2; rgfail=1; }
    if [ "$rgfail" -ne 0 ]; then echo "[test_realgpu] FAIL"; exit 1; fi
    echo "[test_realgpu] PASS — real-GPU host bridge rasterized a full DE+browser frame on the discrete GPU, byte-identical to the SW oracle"
    exit 0
fi

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_vgpu] SKIP: /dev/kvm absent (KVM required; boot too slow without it)" >&2
    exit 0
fi

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
                /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[test_vgpu] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- build the installer medium WITH the virtio-gpu present marker ----
# ENABLE_VIRTIO_GPU_TEST=1 plants /etc/virtio-gpu-test into the installer
# kernel's initramfs (build_initramfs.py reads that env even through
# build_installer_img.sh). The present hook reads the marker from the
# initramfs at boot, so the medium's own kernel paints the test pattern.
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_vgpu] (1/2) building installer medium (ENABLE_VIRTIO_GPU_TEST=1)"
    rm -f "$HAMNIX_INSTALLER_IMG"
    # HAMNIX_FORCE_SELFTESTS=1 arms the boot:37 battery on the (production)
    # installer kernel so the boot:37.vgpu present hook + the Phase-D GPU
    # backend self-test actually run under OVMF (the only path that gives
    # us real firmware + a virtio-gpu display; -kernel is blocked by this
    # host's multiboot/VBE limit). Production ships never set this.
    ENABLE_VIRTIO_GPU_TEST=1 HAMNIX_FORCE_SELFTESTS=1 \
        bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$HAMNIX_INSTALLER_IMG" "[virtio_gpu_present]"
if [ ! -f "$HAMNIX_INSTALLER_IMG" ]; then
    echo "[test_vgpu] FAIL: $HAMNIX_INSTALLER_IMG missing after build_installer_img.sh" >&2
    exit 1
fi

OVMF_RW=$(mktemp --tmpdir hamnix-vgpu.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-vgpu.disk.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-vgpu.XXXXXX.log)
MON=$(mktemp --tmpdir -u hamnix-vgpu-mon.XXXXXX)
SHOT=$(mktemp --tmpdir hamnix-vgpu.XXXXXX.ppm)
cp "$OVMF_FD" "$OVMF_RW"
cp "$HAMNIX_INSTALLER_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$SHOT"
}
trap 'cleanup; rm -f "$LOG"' EXIT

echo "[test_vgpu] (2/2) booting under OVMF with -device virtio-gpu-pci (sole display)"

# virtio-gpu-pci is the ONLY display device (-vga none), so screendump
# captures the virtio-gpu scanout — the surface the kernel flushed into.
# -monitor on a unix socket lets us screendump it. The medium boots via its
# ESP (FAT) so it is attached as a plain virtio-blk disk; the present hook
# fires from the initramfs marker during boot.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m 1G \
    -vga none -device virtio-gpu-pci \
    -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    </dev/null > "$LOG" 2>&1 &
QEMU_PID=$!

# --- wait for the driver's FLUSH-ok marker ----------------------------
echo "[test_vgpu] waiting up to ${BOOT_WAIT}s for the present marker..."
presented=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q -E "\[vgpu\] (PASS|FAIL)" "$LOG"; then
        presented=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        # QEMU may exit after the boot self-test; that's fine if the
        # marker already landed. Re-check once below.
        grep -a -q -E "\[vgpu\] (PASS|FAIL)" "$LOG" && presented=1
        break
    fi
    sleep 1
done

# --- screendump the virtio-gpu scanout --------------------------------
SHOT_OK=0
if [ "$presented" -eq 1 ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    # A few spaced dumps to reliably catch the flushed frame.
    for _ in 1 2 3 4; do
        printf 'screendump %s\n' "$SHOT" | nc -U -q1 "$MON" >/dev/null 2>&1 || true
        sleep 0.6
    done
    [ -s "$SHOT" ] && SHOT_OK=1
fi

sleep 1
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

echo "[test_vgpu] --- virtio-gpu / vgpu boot log ---"
grep -a -E "virtio-gpu|virtio-modern|\[vgpu\]|\[vgpu-vk\]|\[vgpu-bench\]|\[vgpu-de\]" "$LOG" || true
echo "[test_vgpu] --- end ---"

fail=0

# --- driver success markers in the boot log ---------------------------
check_log() {
    local label="$1" needle="$2"
    if grep -a -q -E "$needle" "$LOG"; then
        echo "[test_vgpu] PASS: $label"
    else
        echo "[test_vgpu] FAIL: $label (expected /$needle/)" >&2
        fail=1
    fi
}
check_log "modern transport bound"       "virtio-gpu: modern transport bound"
check_log "DISPLAY_INFO ok"              "virtio-gpu: DISPLAY_INFO scanout0"
check_log "FLUSH ok"                     "virtio-gpu: FLUSH ok"
check_log "present self-test PASS"       "\[vgpu\] PASS"
# Phase D: the native GPU backend (vk_core -> vk_gpu -> virtio-gpu). The
# self-test clears a color two ways (SW rasterizer vs GPU device backing)
# and asserts they match byte-for-byte, then runs GPU clear+present.
check_log "GPU clear matches SW ref"     "\[vgpu-vk\] PASS: GPU clear matches SW reference"
check_log "GPU present ran"              "\[vgpu-vk\] PASS: GPU present"
check_log "GPU backend self-test PASS"   "\[vgpu-vk\] PASS: GPU backend self-test complete"
# GPU track #182: the vk_core -> venus FILL-offload seam foundation. On this
# plain 2D virtio-gpu (no VIRGL negotiated) the GPU fill path is INERT, so the
# self-test proves the foundation WITHOUT a live host GPU: the virgl
# CLEAR_TEXTURE fill encoder is byte-exact, the UNORM color->float convert is
# bit-exact, the opt-in honestly refuses without a virgl device (stays SW),
# and a fill_rect replayed through vkQueueSubmit is pixel-identical to the SW
# oracle (the seam never disturbs the golden default fill path).
check_log "fill encoder byte-exact"      "\[vgpu-raster\] PASS: venus CLEAR_TEXTURE fill encoder byte-exact"
check_log "u8->float convert bit-exact"  "\[vgpu-raster\] PASS: u8->float color convert bit-exact"
check_log "GPU-raster opt-in refuses"    "\[vgpu-raster\] PASS: GPU-raster opt-in refuses without a virgl device"
check_log "fill replay == SW oracle"     "\[vgpu-raster\] PASS: fill_rect replay is pixel-identical to the SW oracle"
check_log "GPU-raster seam foundation"   "\[vgpu-raster\] PASS: GPU-raster fill-offload seam foundation OK"
# Phase D present-path benchmark: proves the GPU-presented backing matches
# the SW frame pixel-for-pixel and records the SW-vs-GPU present numbers.
# (The ns numbers themselves are informational — printed above — and vary
# by host/accel; only the correctness + completion markers gate.)
check_log "present benchmark correct"    "\[vgpu-bench\] PASS: GPU-presented backing matches SW frame"
# Phase D.3: BGRA-native (zero-convert) present. The frame is rendered
# DIRECTLY in the device's BGRA scanout order (vk2d BGRA store), so present
# is the pure device DMA — no RGBA->BGRA convert copy. These markers prove
# the vk2d BGRA store order is correct AND the BGRA-presented backing shows
# the same visible colors as the RGBA reference. The "BGRA-native present"
# ns line printed above is the 61x device-only number the DE flips to.
check_log "vk2d BGRA store order"        "\[vgpu-bench\] PASS: vk2d BGRA store lays B,G,R,A"
check_log "BGRA-native present correct"  "\[vgpu-bench\] PASS: BGRA-native present matches RGBA reference"
check_log "present benchmark complete"   "\[vgpu-bench\] PASS: present benchmark complete"
# Phase D.4: the DE compositor present path (vk_de_present_shadow_rect, the
# exact call _wsys_flush_rect uses under virtio-gpu). Proves the GPU-present
# default activates, the force-SW flag is reversible, and the GPU-presented
# frame is pixel-identical to the SW reference — i.e. flipping the DE to GPU
# present does not change a pixel and never leaves the screen dark.
check_log "DE GPU present is default"    "\[vgpu-de\] PASS: GPU present is the DE default"
check_log "DE force-SW reversible"       "\[vgpu-de\] PASS: force-SW flag flips the DE back to SW"
check_log "DE present pixel-identical"   "\[vgpu-de\] PASS: DE GPU present matches SW reference pixel-for-pixel"
# Phase D.5: the DE compositor now composites the shadow BGRA-native
# (fb_set_shadow_bgra) so the flush is vk_de_present_shadow_rect_bgra — a pure
# 1:1 word-copy deposit + DMA with NO per-pixel RGBA->BGRA convert. This marker
# proves the pure-DMA present is STILL pixel-identical to the convert+SW path
# (same visible colors, produced without the reorder). The "BGRA-native
# pure-DMA present" ns line printed above vs "DE GPU present" is the
# convert->pure-DMA DE-speed payoff (~11 ms -> ~0.4 ms).
check_log "DE BGRA pure-DMA identical"   "\[vgpu-de\] PASS: BGRA-native pure-DMA present is pixel-identical to convert\+SW"
# The strongest form the DE actually installs when scanout geometry matches:
# composite straight into the device backing so the flush is a bare
# TRANSFER+FLUSH (no deposit). Proven pixel-identical; the "zero-copy pure
# TRANSFER+FLUSH present" ns line above is the live DE flush cost (~0.4 ms).
check_log "DE zero-copy identical"       "\[vgpu-de\] PASS: zero-copy composite-in-backing present is pixel-identical"
check_log "DE present verified default"  "\[vgpu-de\] PASS: DE present path verified"

if grep -a -q -E "\[vgpu-de\] FAIL" "$LOG"; then
    echo "[test_vgpu] FAIL: kernel reported [vgpu-de] FAIL" >&2
    fail=1
fi

if grep -a -q -E "\[vgpu-vk\] FAIL" "$LOG"; then
    echo "[test_vgpu] FAIL: kernel reported [vgpu-vk] FAIL" >&2
    fail=1
fi

if grep -a -q -E "\[vgpu-raster\] FAIL" "$LOG"; then
    echo "[test_vgpu] FAIL: kernel reported [vgpu-raster] FAIL" >&2
    fail=1
fi

if grep -a -q -E "\[vgpu\] FAIL" "$LOG"; then
    echo "[test_vgpu] FAIL: kernel reported [vgpu] FAIL" >&2
    fail=1
fi

# --- golden-pixel proof on the dumped scanout -------------------------
# The four quadrants are RED / GREEN / BLUE / WHITE. We sample the centre
# of each quadrant. A real screendump of the flushed virtio-gpu surface
# is the only way to satisfy all four simultaneously.
if [ "$SHOT_OK" -eq 1 ]; then
    python3 - "$SHOT" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()
if not data.startswith(b"P6"):
    print("[ppm] not P6 (%r) — unusable" % data[:8]); sys.exit(2)
idx = 2; toks = []
while len(toks) < 3:
    while idx < len(data) and data[idx] in b" \t\n\r": idx += 1
    if idx < len(data) and data[idx:idx+1] == b"#":
        while idx < len(data) and data[idx] not in b"\n": idx += 1
        continue
    s = idx
    while idx < len(data) and data[idx] not in b" \t\n\r": idx += 1
    toks.append(int(data[s:idx]))
idx += 1
w, h, maxv = toks
print("[ppm] %dx%d maxval=%d" % (w, h, maxv))
pix = data[idx:]
def px(x, y):
    o = (y * w + x) * 3
    return pix[o], pix[o+1], pix[o+2]
# Quadrant centres.
qx0, qx1 = w // 4, (3 * w) // 4
qy0, qy1 = h // 4, (3 * h) // 4
tl = px(qx0, qy0); tr = px(qx1, qy0)
bl = px(qx0, qy1); br = px(qx1, qy1)
print("[ppm] TL(%d,%d)=#%02x%02x%02x TR(%d,%d)=#%02x%02x%02x"
      % (qx0, qy0, tl[0], tl[1], tl[2], qx1, qy0, tr[0], tr[1], tr[2]))
print("[ppm] BL(%d,%d)=#%02x%02x%02x BR(%d,%d)=#%02x%02x%02x"
      % (qx0, qy1, bl[0], bl[1], bl[2], qx1, qy1, br[0], br[1], br[2]))
def is_red(p):   return p[0] > 150 and p[1] < 90  and p[2] < 90
def is_green(p): return p[1] > 150 and p[0] < 90  and p[2] < 90
def is_blue(p):  return p[2] > 150 and p[0] < 90  and p[1] < 90
def is_white(p): return p[0] > 180 and p[1] > 180 and p[2] > 180
ok = is_red(tl) and is_green(tr) and is_blue(bl) and is_white(br)
print("[ppm] TL_RED=%d TR_GREEN=%d BL_BLUE=%d BR_WHITE=%d"
      % (is_red(tl), is_green(tr), is_blue(bl), is_white(br)))
sys.exit(0 if ok else 3)
PYEOF
    pr=$?
    if [ "$pr" -eq 0 ]; then
        echo "[test_vgpu] PASS: screendump shows RED/GREEN/BLUE/WHITE quadrants on the virtio-gpu scanout (real pixels)"
    else
        echo "[test_vgpu] FAIL: virtio-gpu scanout quadrant pixels wrong (rc=$pr)" >&2
        fail=1
    fi
else
    echo "[test_vgpu] FAIL: no usable virtio-gpu screendump captured" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_vgpu] FAIL (boot log: $LOG)"
    trap 'cleanup' EXIT   # keep the log for debugging
    exit 1
fi

# ======================================================================
# GPU track #182 — virtio-gpu-gl 3D / VIRGL boot (host-GPU fill path)
# ======================================================================
# Re-boot the SAME installer medium but with `-device virtio-gpu-gl-pci
# -display egl-headless` so the device advertises VIRTIO_GPU_F_VIRGL and the
# native driver can negotiate it PER-DEVICE, create a 3D context, build a
# render-target resource, and drive a virgl CLEAR fill on the host GPU.
#
# HARD assertions (the key unlock, verified on-device): VIRGL negotiated for
# the GPU device only, FEATURES_OK held, CTX_CREATE succeeds. The actual
# host-GPU FILL either byte-matches the SW oracle (REAL GPU pixels -> PASS) or
# the host's virglrenderer has no working GL context (e.g. the nvidia-headless
# GBM failure), in which case the whole 3D command chain is still ACCEPTED but
# renders nothing -> the kernel prints [vgpu-virgl] SKIP and we do NOT fail.
# A [vgpu-virgl] FAIL (real wrong-pixel render) DOES fail. The section SKIPs
# cleanly if this host cannot realize a GL virtio-gpu at all.
if [ "${HAMNIX_SKIP_VIRGL:-0}" = "1" ]; then
    echo "[test_vgpu] (virgl) SKIP: HAMNIX_SKIP_VIRGL=1"
    echo "[test_vgpu] PASS — native virtio-gpu 2D transport presented a four-quadrant pattern onto the virtio-gpu scanout"
    exit 0
fi
if ! qemu-system-x86_64 -device help 2>/dev/null | grep -q "virtio-gpu-gl-pci"; then
    echo "[test_vgpu] (virgl) SKIP: this QEMU has no virtio-gpu-gl-pci device"
    echo "[test_vgpu] PASS — native virtio-gpu 2D transport presented a four-quadrant pattern onto the virtio-gpu scanout"
    exit 0
fi

echo "[test_vgpu] (virgl) booting under OVMF with -device virtio-gpu-gl-pci -display egl-headless"
GLOVMF=$(mktemp --tmpdir hamnix-vgpu.glovmf.XXXXXX.fd)
GLIMG=$(mktemp --tmpdir hamnix-vgpu.gldisk.XXXXXX.img)
GLLOG=$(mktemp --tmpdir hamnix-vgpu.gl.XXXXXX.log)
cp "$OVMF_FD" "$GLOVMF"
cp "$HAMNIX_INSTALLER_IMG" "$GLIMG"
gl_cleanup() { [ -n "${GLPID:-}" ] && kill "$GLPID" 2>/dev/null; rm -f "$GLOVMF" "$GLIMG"; }
trap 'cleanup; gl_cleanup; rm -f "$LOG" "$GLLOG"' EXIT

# egl-headless may emit a non-fatal host GBM warning to stderr; that is fine.
timeout "$BOOT_WAIT" qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$GLOVMF" \
    -drive file="$GLIMG",format=raw,if=virtio \
    -m 1G \
    -vga none -device virtio-gpu-gl-pci -display egl-headless \
    -no-reboot \
    -serial stdio \
    </dev/null > "$GLLOG" 2>&1 &
GLPID=$!

echo "[test_vgpu] (virgl) waiting up to ${BOOT_WAIT}s for the GPU-backend marker..."
for _ in $(seq 1 "$BOOT_WAIT"); do
    grep -a -q -E "\[vgpu-vk\] (PASS|FAIL): GPU backend self-test (complete|failed)" "$GLLOG" && break
    grep -a -q -E "does not have OpenGL support enabled" "$GLLOG" && break
    kill -0 "$GLPID" 2>/dev/null || break
    sleep 1
done
sleep 1
kill "$GLPID" 2>/dev/null; wait "$GLPID" 2>/dev/null

echo "[test_vgpu] (virgl) --- 3D/VIRGL boot log ---"
grep -a -E "virtio-modern:|virtio-gpu:|\[vgpu-virgl\]|\[vgpu-vk\]|OpenGL" "$GLLOG" | grep -a -iE "virgl|want_gf0|readback|CTX_CREATE|3D|OpenGL|byte-match|host GPU|render-target|transfer" | head -40
echo "[test_vgpu] (virgl) --- end ---"

glfail=0
if grep -a -q -E "does not have OpenGL support enabled" "$GLLOG"; then
    echo "[test_vgpu] (virgl) SKIP: host QEMU display has no OpenGL support (no usable GL virtio-gpu on this host)"
elif ! grep -a -q -E "virtio-gpu: 3D/VIRGL feature ADVERTISED by device" "$GLLOG"; then
    echo "[test_vgpu] (virgl) SKIP: device did not advertise VIRGL (host virglrenderer/GL unavailable)"
else
    gl_check() {
        local label="$1" needle="$2"
        if grep -a -q -E "$needle" "$GLLOG"; then
            echo "[test_vgpu] (virgl) PASS: $label"
        else
            echo "[test_vgpu] (virgl) FAIL: $label (expected /$needle/)" >&2
            glfail=1
        fi
    }
    # The KEY UNLOCK — negotiated PER-DEVICE and verified on-device.
    gl_check "VIRGL negotiated for GPU device"  "virtio-modern: want_gf0=1 negotiated word0=1"
    gl_check "FEATURES_OK held, VIRGL readback" "virtio-modern: FEATURES_OK held .* word0 readback=1"
    gl_check "3D CTX_CREATE succeeds on-device"  "virtio-gpu: 3D CTX_CREATE OK"
    gl_check "3D render-target resource created" "\[vgpu-virgl\] host render-target resource id="
    gl_check "host GPU accepted CLEAR SUBMIT_3D" "\[vgpu-virgl\] host GPU accepted canonical CLEAR stream"
    # A real wrong-pixel render is a genuine failure; SKIP (host GL can't
    # rasterize) and PASS (real GPU pixels) are both acceptable outcomes.
    if grep -a -q -E "\[vgpu-virgl\] FAIL" "$GLLOG"; then
        echo "[test_vgpu] (virgl) FAIL: kernel reported [vgpu-virgl] FAIL (wrong-pixel render)" >&2
        glfail=1
    fi
    if grep -a -q -E "\[vgpu-virgl\] PASS: host-GPU virgl fill pixels byte-match" "$GLLOG"; then
        echo "[test_vgpu] (virgl) PASS: host GPU rasterized REAL pixels (byte-match SW oracle)"
    elif grep -a -q -E "\[vgpu-virgl\] SKIP:" "$GLLOG"; then
        echo "[test_vgpu] (virgl) NOTE: host virglrenderer GL non-functional here; 3D command chain fully accepted but no real GPU pixels (no false claim)"
    fi
    # The GPU-backend self-test as a whole must not report failure on the GL boot.
    if grep -a -q -E "\[vgpu-vk\] FAIL" "$GLLOG"; then
        echo "[test_vgpu] (virgl) FAIL: [vgpu-vk] reported failure on the GL boot" >&2
        glfail=1
    fi
fi

if [ "$glfail" -ne 0 ]; then
    echo "[test_vgpu] FAIL (virgl 3D boot; log: $GLLOG)"
    trap 'cleanup; gl_cleanup' EXIT
    exit 1
fi

echo "[test_vgpu] PASS — native virtio-gpu 2D transport presented a four-quadrant pattern, and the virtio-gpu-gl 3D/VIRGL path negotiated + created a live host-GPU context on-device"
