# In-guest virtio-gpu 3D on REAL NVIDIA silicon (RTX 3090) — 2026-07-18

**Payoff reached.** The exact same in-guest virtio-gpu 3D path that
`scripts/test_inguest_gpu.sh` proved on llvmpipe now rasterizes on the **RTX
3090** — with **zero guest-code changes**. The guest's virtio-gpu driver +
virgl encoder submit a CLEAR, the host `virglrenderer` rasterizes it on an
**NVIDIA GL 4.6** context, the pixels transfer back into guest memory, and the
guest byte-compares them to the vk2d SW oracle: **GREEN, byte-identical, on the
GPU**.

This was purely a **host-side QEMU-config** fix, exactly as scoped.

## The three-part proof (all required; no false HW claim)

Boot: `build/hamnix-installer.img` under OVMF/KVM with
`-device virtio-gpu-gl-pci -display sdl,gl=on` on a live X server (`DISPLAY=:0`):

```
VREND_DEBUG=all VIRGL_LOG_LEVEL=debug DISPLAY=:0 \
qemu-system-x86_64 -enable-kvm -cpu host -bios OVMF.fd \
  -drive file=hamnix-installer.img,format=raw,if=virtio -m 1G \
  -vga none -device virtio-gpu-gl-pci -display sdl,gl=on -no-reboot -serial stdio
```

1. **Guest byte-verify (GREEN):**
   ```
   [vgpu-virgl] GPU px(5,5) B=0 G=255 R=0
   [vgpu-virgl] PASS: host-GPU virgl fill pixels byte-match the SW oracle (REAL GPU pixels)
   ```
2. **Host context is NVIDIA, not llvmpipe:** virglrenderer logs
   `gl_version 46 - core profile enabled`. On this host llvmpipe tops out at **GL
   4.5** (`egl_device_probe`: `llvmpipe ... 4.5 Mesa 25.0.7`); the NVIDIA driver
   reports **GL 4.6** (`4.6.0 NVIDIA 550.163.01`). GL 4.6 core ⇒ the RTX 3090.
   Crucially, the `nv_gbm_create_device_native failed` error **does not appear**
   on the sdl,gl=on path — virglrenderer never touches GBM.
3. **nvidia-smi residency:** during the run,
   `nvidia-smi` lists `qemu-system-x86_64` resident on GPU 0 (Graphics context,
   ~9→33 MiB growing as the guest renders).

Gate: `scripts/test_inguest_gpu_hw.sh` asserts **all three** and PASSes only when
they all hold; otherwise it SKIPs cleanly (never a false HW claim). Added to
`scripts/ci_battery_manifest.txt`.

## Why sdl,gl=on works where egl-headless can't

The root cause (confirmed with two standalone host probes, sub-second, no VM):

- **`scripts/egl_device_probe.c`** — the RTX 3090 does headless GL **only** via
  the EGL **device** platform (`EGL_PLATFORM_DEVICE_EXT` →
  `GL_RENDERER=NVIDIA GeForce RTX 3090`, GL 4.5/4.6). Its GBM-headless backend
  fails.
- **`scripts/virgl_egl_probe.c`** — the shipped `libvirglrenderer.so.1` (1.1.0)
  opens a `gbm_device` **unconditionally** in its own GL winsys (even with
  `USE_SURFACELESS`). On NVIDIA that always fails
  (`nv_gbm_create_device_native`, `virgl_renderer_init` returns -1). No env
  (`__EGL_VENDOR_LIBRARY_FILENAMES`, `EGL_PLATFORM`, `VIRGL_*`) reaches the
  EGLDevice path — virglrenderer's winsys simply has no EGLDevice code for its
  primary display. So **QEMU `-display egl-headless` (which drives that winsys)
  can only ever get GBM→llvmpipe on NVIDIA.**

The escape hatch: QEMU's **UI** display backends with `gl=on`
(`sdl`, `gtk`) do **not** use virglrenderer's GBM winsys. The UI creates the GL
context itself on the running **X/GLX server — i.e. the NVIDIA driver** — and
hands it to virglrenderer via the caller-supplied `create_gl_context` /
`make_current` callbacks (virglrenderer's `USE_GLX`/external-context path). That
context *is* the RTX 3090, so the identical guest virgl stream rasterizes on the
GPU.

- **`sdl,gl=on`** — WORKS. Clean PASS, no crash.
- **`gtk,gl=on`** — gets the same NVIDIA **GL 4.6** context (log shows
  `gl_version 46`) but then **aborts** on
  `qemu: egl: eglMakeCurrent failed: EGL_BAD_ACCESS` /
  `epoxy: Couldn't find current GLX or EGL context` — GDK owns/threads the EGL
  context, so QEMU's virgl thread can't make it current. Use sdl.

## Runbook / requirements

- A **live GL-capable X server on the NVIDIA GPU** (`DISPLAY` set; `glvnd` +
  `libGLX_nvidia`). This is **not headless** — sdl/gtk open a QEMU window. For a
  truly headless server, run an X server on the NVIDIA card (e.g. `Xorg` with the
  nvidia driver, or `xpra`/virtual-display) and point `DISPLAY` at it; the same
  sdl,gl=on path then works. `-display egl-headless` cannot be used on NVIDIA
  (GBM-only → llvmpipe).
- `qemu-system-x86_64` with the **sdl** display backend compiled in
  (`qemu-system-gui` on Debian) and the `virtio-gpu-gl-pci` device.
- No new package, no QEMU patch, no vhost-user-gpu, no newer virglrenderer
  required. (`vhost-user-gpu` is present but uses the same GBM winsys; and
  `/usr/libexec/virgl_render_server` is absent, so the render-server split isn't
  available anyway.)

## Note for the future: Venus (Vulkan) path

`libvirglrenderer.so.1` also ships **Venus** (`VK_MESA_venus_protocol`,
`vkr_*`), and NVIDIA's Vulkan enumerates the 3090 **headless with no GBM**
(`vk_probe`: `device[0]=NVIDIA GeForce RTX 3090, api 1.3.277, discrete`). A
future guest that negotiates `VIRTIO_GPU_F_VENUS` and emits a Vulkan command
stream (`-device virtio-gpu-gl-pci,venus=on,blob=on,hostmem=...`) would run on
NVIDIA Vulkan directly — a genuinely headless HW path — but that needs a guest
Venus encoder (guest-owned, out of scope here). The sdl,gl=on virgl path above
needs **no** guest change and is the win today.
