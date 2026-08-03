# In-guest MULTI-OP frame on the RTX 3090 — 2026-07-18

**Payoff extended.** After the single in-guest fill rasterized on the RTX 3090
(`docs/inguest_gpu_hw_nvidia_2026-07-18.md`), a **real multi-op frame** — the
exact `VK_OP_2D_*` stream a DE window / browser box-paint emits — now rasterizes
**end-to-end on the RTX 3090**, routed through vk_core's GPU frame router →
`lib/vk/vk_venus.ad` → `SUBMIT_3D`, and **byte-compared in-guest** to the vk2d SW
oracle. More than a single fill runs on the GPU.

## What runs on the GPU (byte-verified) — 4 op types + background clear

The frame (96×64, B8G8R8A8) exercised and byte-matched the SW oracle for:

| Op | VK op | GPU encoding |
|----|-------|--------------|
| background clear | render-pass CLEAR | full-target virgl `CLEAR` |
| solid rect ×3 (red/green/white) | `VK_OP_2D_FILL_RECT` | scratch-clear + `RESOURCE_COPY_REGION` |
| opaque translucent rect (magenta) | `VK_OP_2D_FILL_RECT_ALPHA` (α=0xFF) | scratch-clear + copy |
| axis-aligned thick line (cyan h + yellow v) | `VK_OP_2D_DRAW_LINE` | bounding rect → scratch-clear + copy |
| 1:1 opaque blit | `VK_OP_2D_BLIT` | `RESOURCE_COPY_REGION` (frame→frame) |

Guest markers (serial), same boot as the single-fill `[vgpu-virgl]` PASS:

```
[vgpu-multiop] router rasterized the multi-op frame on the host GPU (frames++)
[vgpu-multiop] PASS: multi-op frame (clear+fill_rect+fill_rect_alpha+draw_line) byte-matches the SW oracle on the host GPU
[vgpu-multiop] PASS: GPU RESOURCE_COPY_REGION (blit) byte-matches the SW oracle
[vgpu-multiop] PASS: 4 op types on the RTX 3090 (fill_rect, fill_rect_alpha, draw_line, blit)
```

Host proof (all three required, like the single-fill gate): `gl_version 46 - core
profile enabled` (llvmpipe tops out at 4.5 ⇒ NVIDIA), `nvidia-smi` shows our
`qemu-system-x86_64` resident on GPU 0, and the guest byte-compare is GREEN.
Colors use only 0/255 channels so the host float→unorm readback is EXACT.

Gate: `scripts/test_inguest_gpu_multiop_hw.sh` (added to
`scripts/ci_battery_manifest.txt`) asserts all three; SKIPs cleanly without
`$DISPLAY` / `nvidia-smi` / an NVIDIA EGLDevice. Same host recipe as the
single-fill gate: OVMF/KVM + `-device virtio-gpu-gl-pci -display sdl,gl=on` on a
live X server (`DISPLAY=:0`).

## How the router works

`vk_enable_gpu_raster()` opts in (only succeeds on a live virgl device; DEFAULT
OFF, SW stays the golden oracle). `vkQueueSubmit` then pre-scans the recorded
command buffer with `_vk_frame_gpu_eligible`: a frame is GPU-eligible only if it
targets a **B8G8R8A8** image, **clears** it, and every op is GPU-encodable
(FILL_RECT, opaque FILL_RECT_ALPHA, axis-aligned DRAW_LINE). Eligible frames run
entirely on the GPU (`_vk_gpu_try_frame`) into a frame-sized virgl RT and the
pixels are read back into the color image; **any** GPU submit/readback failure
falls the WHOLE frame back to the SW rasterizer, so it is never blank/wrong.
`vk_gpu_frames_rendered()` counts frames actually rasterized on the device, so a
caller/test can prove the GPU path (not the SW fallback) was taken.

## The KEY finding: scissored CLEAR does not clip on the shipped virglrenderer

The obvious "solid sub-rect = scissored `CLEAR`" encoding is **byte-correct** vs
mesa/virglrenderer sources — rasterizer scissor bit **14** (`ebit(scissor,14)`),
`VIRGL_OBJ_RS_SIZE=9`, `SET_SCISSOR_STATE` `(minx|miny<<16),(maxx|maxy<<16)`,
`CLEAR` size 8 — yet **on this host it does not clip**: every fill clears the
whole render target, so only the last color survives (on-device: every sampled
pixel was the last op's color). Verified against the shipped decoder: `CREATE
RASTERIZER(scissor=1)` → `BIND` copies `rs_state = *object` → `SET_SCISSOR` →
`CLEAR`; `vrend_clear` calls `vrend_update_scissor_state` which should
`glEnable(GL_SCISSOR_TEST)`. Empirically the clip does not take effect on the
Debian-shipped virglrenderer + NVIDIA GL path.

**Robust replacement (what shipped):** every solid rect is a **full CLEAR** of a
same-format SCRATCH render target to the color, followed by a
**`RESOURCE_COPY_REGION`** (`glCopyImageSubData`) of its `(0,0,w,h)` box into
`(x,y)` of the frame RT. This uses only primitives proven on this host — the
full CLEAR (the single-fill GREEN path) and a GPU box copy — and is
pixel-identical to `vk2d_raster_fill_rect` for a clamped opaque rect. Axis-
aligned thick lines map to their exact bounding rectangle (a horizontal/vertical
`t×t`-brush Bresenham sweep covers exactly `[min,max]+t × t`), so DRAW_LINE reuses
the same fill. The 1:1 opaque BLIT is a direct `RESOURCE_COPY_REGION`.

## Honest scope — what is still SW-fallback (not yet GPU-encoded)

- **Translucent `FILL_RECT_ALPHA`** (α<255): needs a real blend pipeline (a
  blend-state object + a quad DRAW with a fragment shader), not a CLEAR/copy.
- **`FILL_ROUNDRECT`**: anti-aliased corners need per-pixel coverage (a shader or
  a coverage-mask upload), not a solid copy.
- **Diagonal `DRAW_LINE`**: a rotated line is not a single axis rect.
- **General scaled/blended `BLIT`**: only the opaque 1:1 copy is GPU-encoded.

These stay on the vk2d SW rasterizer (the golden oracle), counted separately and
never faked. A frame containing any of them is INELIGIBLE and runs fully on SW.

## Toward the full DE-compositor-on-GPU

Next steps: (1) a **blend-state + solid-color quad DRAW** to cover translucent
fills and general blits (unlocks scrims/overlays and scaled sprites); (2) a
**coverage-mask** path (upload the vk2d cov-mask to a texture, sample it) for
rounded rects and AA text/glyphs; (3) per-image RT binding + batched readback so
the router auto-routes **arbitrary** DE/browser frames (today it engages only for
fully-eligible BGRA frames); (4) a virgl **resource-resize** (UNREF+recreate) so
the frame/scratch RTs follow window resizes instead of conservatively declining.

## Files

- `lib/vk/vk_venus.ad` — frame encoders (`vk_venus_encode_frame_setup`,
  `_venus_put_fb_clear`, `vk_venus_encode_rect_fill`,
  `vk_venus_encode_copy_region`) + high-level `vk_venus_frame_{create_rt,begin,
  fill,blit,readback,backing}`.
- `lib/vk/vk_core.ad` — GPU frame router (`_vk_frame_gpu_eligible`,
  `_vk_gpu_try_frame`, `_vk_gpu_fill_clamped`, `_vk_gpu_frame_line`),
  `vk_gpu_frames_rendered`, `vk_image_mem_base`.
- `drivers/video/virtio_gpu.ad` — frame RT (res 3) + scratch RT (res 4)
  lifecycle (`virtio_gpu_3d_create_frame_rt` / `_create_scratch_rt` /
  `_frame_rt_readback` / `_frame_rt_backing`).
- `lib/vk/vk_selftest.ad` — `vk_gpu_virgl_multiop_selftest` (`[vgpu-multiop]`).
- `scripts/test_inguest_gpu_multiop_hw.sh` — the RTX-3090 gate.
