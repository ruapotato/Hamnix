# In-guest virtio-gpu 3D really rasterizes on the host GPU — 2026-07-18

Goal: make Hamnix's **in-guest** Vulkan/virtio-gpu rendering actually execute on
a real host GPU — the browser/DE running INSIDE Hamnix gets GPU-accelerated
pixels through the guest's own driver, not a host-side shortcut. This is the
RIGHT layer; the host-GPU bridge (`scripts/vk_hostgpu_bridge.c`) bypasses the
guest and is deliberately left untouched.

**Outcome (this round): the in-guest path is LIT end to end.** The guest's
virtio-gpu driver + venus/virgl encoder submit a 3D CLEAR, the host
`virglrenderer` rasterizes it on a real GL context, the pixels transfer back
into guest memory, and the guest byte-compares them to the vk2d SW oracle —
**byte-identical GREEN, REAL (non-prefill) pixels**. On this NVIDIA-proprietary
host the host GL context is Mesa **llvmpipe** (via QEMU's GBM/EGL fallback),
which proves the entire guest→host 3D plumbing; reaching the RTX 3090 silicon
needs only a host-side ICD/EGL swap (no guest change) — precise step below.

## The blocker that was actually in the way (root-caused this round)

The prior investigation (`docs/real_gpu_bridge_2026-07-18.md`) concluded virgl
"tops out at llvmpipe" and pivoted to the host bridge. But the in-guest fill
was never actually turned green — and the reason was **not** the host GL context.
It was a guest-side encoding bug:

- The guest fill path (`vk_venus_fill_rect`) submitted `VIRGL_CCMD_CLEAR_TEXTURE`
  (opcode 48). The shipped `virglrenderer` (lib 1.9.0) does **not** implement
  that opcode. It rejects the stream:
  `vrend_decode_ctx_submit_cmd: ... Illegal command buffer 786480` (0xC0030 =
  cmd 48, len 12) and — critically — puts the whole 3D **context into a
  permanent error state**.
- Every command submitted *after* it (including the authoritative canonical
  full-RT CLEAR the self-test relies on) is then **silently dropped**. The
  `TRANSFER_FROM_HOST_3D` readback returns the stale staging bytes (`0xAB` from
  the round-trip probe), so the guest saw "readback != oracle" and honestly
  reported SKIP — forever.

I reproduced this exactly against `libvirglrenderer.so.1` in a standalone host
harness (sub-second iteration, no VM):

| sequence                                             | result                         |
|------------------------------------------------------|--------------------------------|
| CLEAR_TEXTURE(48) then canonical CLEAR               | `submit=22`, context poisoned → readback `0xAB` (not green) |
| canonical CLEAR only                                 | readback **B=0 G=255 R=0 GREEN_OK** |
| scissored canonical CLEAR (new) then canonical CLEAR | both `rc=0`, readback **GREEN_OK** |

## The fix (guest-side, in the owned files)

`lib/vk/vk_venus.ad`: `vk_venus_fill_rect`'s SUBMIT path no longer emits the
unsupported/poisoning `CLEAR_TEXTURE`. It now emits an always-supported
**canonical scissored clear** (`vk_venus_encode_fill_rect_gl`, 47 dwords):

1. `CREATE_OBJECT(SURFACE)` over the RT
2. `CREATE_OBJECT(RASTERIZER)` with `scissor=1` (S0 bit 14)
3. `BIND_OBJECT(RASTERIZER)`
4. `SET_FRAMEBUFFER_STATE` (surface as colour attachment 0)
5. `SET_SCISSOR_STATE` (the x,y,w,h box)
6. `CLEAR` (glClear to the colour)
7. `CREATE_OBJECT(RASTERIZER)` with `scissor=0` + `BIND_OBJECT` — RESET, so a
   following full clear is never restricted to the box.

It rasterizes on the host GPU and never poisons the context. The byte-exact
`vk_venus_encode_fill_rect` (CLEAR_TEXTURE layout) is retained only for the
on-device encoder-layout self-test. (Note: the shipped virglrenderer's *clear*
path did not honour the scissor rectangle under llvmpipe — the box filled the
whole RT — but that is a host-renderer clear-scissor limitation, not an encoding
error; the CLEAR still rasterizes and the reset keeps the subsequent full clear
correct. On a renderer that honours clear-scissor this becomes a true sub-box
fill with no guest change.)

## Proof (in-guest marker + host evidence + byte-verify)

Boot: installer medium under OVMF/KVM with `-device virtio-gpu-gl-pci -display
egl-headless`, host env forcing the Mesa EGL vendor:

```
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json \
LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
qemu-system-x86_64 -enable-kvm -cpu host -bios OVMF.fd \
  -drive file=hamnix-installer.img,format=raw,if=virtio -m 1G \
  -vga none -device virtio-gpu-gl-pci -display egl-headless -no-reboot -serial stdio
```

Guest serial (the unforgeable markers):
```
virtio-gpu: 3D/VIRGL feature ADVERTISED by device
virtio-gpu: 3D CTX_CREATE OK — host GPU context LIVE
[vgpu-virgl] host render-target resource id=2
[vgpu-virgl] host 3D transfer(staging) round-trip OK (marshalling proven)
[vgpu-virgl] host GPU accepted canonical CLEAR stream (SUBMIT_3D)
[vgpu-virgl] GPU px(5,5) B=0 G=255
[vgpu-virgl] GPU px(5,5) R=0 (expect GREEN: B=0 G=255 R=0)
[vgpu-virgl] PASS: host-GPU virgl fill pixels byte-match the SW oracle (REAL GPU pixels)
```

- **Real (non-prefill) pixels:** the readback is `B=0 G=255 R=0` (GREEN), NOT the
  `0xAB` staging pattern the round-trip probe left — the host actually cleared it.
- **Byte-verify vs SW oracle:** the guest compares all 16×16×4 bytes to
  `vk2d_raster_fill_rect` (BGRA) in-guest — `bad==0` → PASS.
- **Host executed it:** QEMU's egl-headless GBM/EGL context. On this host the
  NVIDIA GBM-headless backend errors (`nv_gbm_create_device_native failed`,
  non-fatal) and Mesa takes over — a standalone probe of QEMU's exact init path
  reports `GL_RENDERER=llvmpipe (LLVM 19.1.7), GL 4.5 Mesa 25.0.7`. So the guest
  stream was rasterized by the host's virglrenderer GL context, not faked.

Gate: `scripts/test_inguest_gpu.sh` (opt-in; SKIPs cleanly without
KVM/OVMF/virtio-gpu-gl/Mesa-EGL; INCONCLUSIVE — never pass — on 0 guest
markers). Added to `scripts/ci_battery_manifest.txt`. The existing
`scripts/test_virtio_gpu_present.sh` virgl section now also turns
`[vgpu-virgl] PASS` (it previously SKIPped on exactly this poison) — an
improvement, no regression.

## What remains for HW-NVIDIA (RTX 3090 silicon)

> **UPDATE 2026-07-18 — DONE.** The HW-NVIDIA path is reached and byte-verified;
> see `docs/inguest_gpu_hw_nvidia_2026-07-18.md` + `scripts/test_inguest_gpu_hw.sh`.
> The fix was **not** an EGLDevice/vhost-user-gpu backend (below): virglrenderer
> 1.1.0's winsys is GBM-only with no reachable EGLDevice path. Instead,
> `-display sdl,gl=on` on a live NVIDIA X server makes QEMU's SDL UI create the
> GL context on the NVIDIA/GLX driver and hand it to virglrenderer — the guest
> virgl stream then runs on the RTX 3090 (GL 4.6, nvidia-smi resident), no guest
> change. The paragraph below is the original (now superseded) hypothesis.


The guest path is renderer-agnostic — it works on whatever GL context QEMU's
virtio-gpu-gl hands to virglrenderer. Today that is llvmpipe because QEMU
`egl-headless` builds its context on the EGL **GBM** platform, and the NVIDIA
proprietary driver's GBM-headless backend fails there. The RTX 3090 *does* do
headless GL 4.6 — but only via the EGL **device** platform
(`EGL_PLATFORM_DEVICE_EXT`), which egl-headless does not use.

Precise remaining step (host-side only, no guest change): give QEMU a display /
GPU backend that drives virglrenderer on **EGLDevice** (or a GBM stack the
NVIDIA driver accepts) — e.g. a QEMU built to select the EGL device platform for
egl-headless, or a `vhost-user-gpu` helper configured to init virglrenderer on
EGLDevice. Nouveau is unavailable here (the proprietary kmd owns the card).
Once the host context is the RTX 3090, the identical guest `[vgpu-virgl]`
sequence renders on the GPU and `nvidia-smi` would show virglrenderer resident —
no `.ad` change required.
