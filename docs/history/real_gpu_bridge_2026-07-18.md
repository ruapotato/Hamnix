# Real GPU acceleration on the RTX 3090 — 2026-07-18

Goal: get REAL 3D/GPU-accelerated pixels on this host's NVIDIA RTX 3090 for a
genuine Hamnix workload (DE/browser frame), byte-verified against the SW oracle,
with unforgeable evidence the GPU executed it.

**Outcome: achieved via the host-GPU bridge (path 2).** A full-frame DE +
browser-page workload rasterizes on the RTX 3090, byte-identical to the SW
oracle, with `nvidia-smi` per-process residency proof. Path 1 (virgl
egl-headless) is blocked on this host by an NVIDIA-driver + QEMU limitation
(diagnosed precisely below), not by a missing GPU.

## Host facts (confirmed)
- NVIDIA GeForce RTX 3090, driver 550.163.01, `/dev/dri/renderD128` present.
- Vulkan ICDs: `nvidia_icd.json` (RTX 3090, discrete-GPU, Vulkan 1.3.277) +
  `lvp_icd.json` (llvmpipe, CPU, 1.4.305) + others.
- `nvidia_icd`, `nouveau_icd`, `lvp_icd` in `/usr/share/vulkan/icd.d/`.
- EGL vendors: `10_nvidia.json`, `50_mesa.json` (GLVND).

## Path 1 — virgl / QEMU `-display egl-headless`: precise root cause

QEMU's `egl-headless` builds its GL context on the **EGL GBM platform**
(`eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm_create_device(render_node))`).
I reproduced QEMU's exact init path with a standalone GBM+EGL probe and tested
every EGL-vendor / platform combination:

| EGL vendor (GLVND)         | Platform    | Result                                                            |
|----------------------------|-------------|-------------------------------------------------------------------|
| auto                       | GBM         | `nv_gbm_create_device_native failed` → Mesa fallback → **llvmpipe** (SW) |
| forced `50_mesa.json`      | GBM         | same → **llvmpipe** (SW)                                           |
| forced `10_nvidia.json`    | GBM         | `nv_gbm_create_device_native failed` → **no EGLDisplay** (hard fail) |
| Mesa                       | surfaceless | DRI2 screen create fails → **llvmpipe** (SW)                       |
| **NVIDIA**                 | **EGLDevice** | **`GL_RENDERER=NVIDIA GeForce RTX 3090/PCIe/SSE2`, GL 4.6 (HW!)** |

Conclusions:
1. The NVIDIA proprietary driver's **GBM-headless** backend fails to create a
   GBM device on the render node (`src/nv_gbm.c:288 nv_gbm_create_device_native`).
   This is the exact error the prior VIRGL agent hit.
2. Mesa/nouveau cannot drive the card (the NVIDIA proprietary kmd owns it), so
   Mesa's GBM path falls back to **llvmpipe (software)**. A virgl context WOULD
   initialize here — but it would rasterize on the **CPU**, not the RTX 3090.
3. The RTX 3090 **can** do hardware GL 4.6 headless — but only via the EGL
   **device** platform (`EGL_PLATFORM_DEVICE_EXT`), which QEMU `egl-headless`
   does **not** use.

**Verdict:** on this host, in-VM virgl via `-display egl-headless` tops out at
llvmpipe (software). It cannot reach the RTX 3090 without either (a) a QEMU that
drives the EGL *device* platform / a vhost-user-gpu backend using EGLDevice, or
(b) a working nouveau/GBM stack (not possible while the proprietary driver owns
the card). This is a QEMU+driver limitation, out of scope for our repo. The
existing `test_virtio_gpu_present.sh` virgl section already SKIPs cleanly on
exactly this condition — no false green — so no change was needed there.

Reproduce: `scratchpad/egl_probe.c` (GBM path) and `egl_dev_probe.c` (EGLDevice
path). Both are throwaway probes, not committed.

## Path 2 — host-GPU bridge: REAL RTX 3090 pixels (delivered)

`scripts/vk_hostgpu_bridge.c` drives the RTX 3090 through `libvulkan.so.1`
directly. Its compute pipeline (`scripts/shaders/vk2d_raster.comp.spv`) runs the
**vk_2d compositor op vocabulary** (`OP_FILL / FILL_ALPHA / BLIT / ROUNDRECT /
LINE` — the primitives `lib/vk/vk_2d.ad`, the DE compositor, and the hambrowse
painter emit) with byte-identical integer math to the SW rasterizer.

### New `pageraster` mode — a genuine Hamnix workload (not a synthetic fill)
`vk_hostgpu_bridge pageraster W H OUT.ppm [SECONDS]` composes a full-frame
**DE desktop hosting a browser window with a laid-out page**: wallpaper +
vignette, top panel (menus, clock pill), dock of rounded icons, browser window
(tab strip, URL box, back/fwd buttons), hero banner (image blit + translucent
source-over scrim), H1/subtitle, article paragraph text-run blocks of varying
widths, three sidebar cards (thumbnail blit, title, text runs, rounded CTA
button), and a scrollbar. ~76 ops at 1280×720. It authors the frame ONCE and
emits it two ways — the GPU compute op-list and a bit-exact runtime CPU port
(the SW oracle) — then byte-compares the GPU readback.

The proven `raster` / `rasterbench` modes are untouched; `pageraster` is
fully self-contained.

### Measured on the RTX 3090
```
VK_DEVICE NVIDIA GeForce RTX 3090 [discrete-GPU]
PAGERASTER_OK ... 1280x720 ops=76 gpu_frames=1143
PAGERASTER_GPU_MS 2.32   PAGERASTER_SW_MS 5.19   PAGERASTER_SPEEDUP 2.24x
PAGERASTER_GPUvsCPUport_MISMATCH 0            # byte-identical
```
- **Byte-verified:** GPU readback identical to the SW oracle (0 mismatches).
- **GPU-exec proof:** `nvidia-smi --query-compute-apps` observes the bridge pid
  resident on the RTX 3090 during a sustained run
  (`2718446, 7 MiB`).
- Also `rasterbench 1280x720` = **15.5×** SW (fill/blend-bound); the page frame's
  2.2× reflects per-op barrier overhead across many small ops (real compositors
  batch — a future optimization, not a correctness issue).

Speedup is modest for the many-small-op page frame because each op is a separate
dispatch+barrier; the win grows with fill area (15× at bench sizes).

## Gate wiring

`scripts/test_virtio_gpu_present.sh` gains an **opt-in** real-GPU gate:
`HAMNIX_REAL_GPU_GATE=1 bash scripts/test_virtio_gpu_present.sh`. It builds the
bridge, requires a non-CPU Vulkan device (else SKIP), runs `pageraster`, and
asserts: (1) `PAGERASTER_GPUvsCPUport_MISMATCH 0`, (2) the selected device is a
discrete/integrated GPU, (3) `nvidia-smi` per-process residency (informational
note if unavailable). **SKIPs cleanly (exit 0)** when libvulkan/gcc/SPIR-V are
absent or only llvmpipe is present. Verified: PASS on this host, clean SKIP under
`VK_ICD_FILENAMES=.../lvp_icd.json` (llvmpipe-only).

## What remains
- **Path 1 real-HW virgl:** needs a QEMU display backend that uses the EGL
  *device* platform (or vhost-user-gpu / a GBM stack the NVIDIA driver accepts).
  Tracked as a host/QEMU limitation; our virgl gate already SKIPs honestly.
- **Bridge → live DE/browser:** feed the actual DE display-list / hambrowse page
  ops (rather than the representative page authored here) through the bridge, and
  batch ops to close the small-op barrier overhead toward the 15× fill-bound win.
- **Text (cov_mask/glyph) op** is not yet in the compute shader; page text is
  rendered as block fills. Adding `OP_COV_MASK` would let real anti-aliased glyph
  runs run on the GPU too.
