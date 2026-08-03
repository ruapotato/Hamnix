# In-guest GPU compositor: per-op SW/GPU mixing + proportional-font atlas (GPU track #182, round 11)

Verified on the **RTX 3090** (`-display sdl,gl=on` on `DISPLAY=:0`, virglrenderer
GL 4.6 core = NVIDIA, `nvidia-smi` showing the QEMU pid resident), byte-identical
(±1 UNORM for glyph coverage) to the vk2d SW oracle, via
`scripts/test_inguest_gpu_multiop_hw.sh`.

## What shipped

Round 10 auto-routed a WHOLE representative frame onto the 3090 but was
**whole-frame-or-nothing**: any router-ineligible op (a rounded rect, a
differently-sized glyph) forced the ENTIRE frame back to the CPU oracle, and the
glyph batch pinned ONE fixed R8 coverage-texture size. Real DE/browser frames
have rounded rects everywhere and proportional (varied-size) text, so they did
not accelerate. This round removes both walls.

### 1. Per-op SW/GPU mixing in one frame

`vkQueueSubmit`'s router (`lib/vk/vk_core.ad`) now routes a frame whenever it
BEGINs with a CLEAR of a B8G8R8A8 target and has ≥1 GPU-encodable op
(`_vk_frame_gpu_routable`). Within `_vk_gpu_try_frame`, each op is decided
independently (`_vk_op_gpu_encodable`):

* **GPU-encodable** (fills / opaque alpha fills / axis lines / in-bounds glyphs /
  natural-size self-blit) rasterize on the 3090 into the frame RT, exactly as
  before.
* **Ineligible** (rounded rect, translucent/scaled/cross-image blit, diagonal
  line) is CPU-composited into the SAME frame RT **in draw order**
  (`_vk_gpu_sw_composite`): read the GPU RT back into the color image, run the
  exact vk2d SW rasterizer for that one op on those pixels, then
  `TRANSFER_TO_HOST_3D` (new `virtio_gpu_3d_frame_rt_upload` /
  `vk_venus_frame_upload`) the composited pixels back into the host frame RT so
  later GPU ops draw over it.

Because each GPU op is individually byte-identical to its SW counterpart, the
readback at any point equals the SW oracle's state at that point, so the
CPU-composited op lands byte-exactly and compositing order is preserved.

Reported per-op breakdown: `vk_gpu_last_frame_ops()` (GPU) vs
`vk_gpu_last_frame_sw_ops()` (CPU-composited).

**3090 result** — mixed frame = 8 fills/line/glyph/blit ops on the GPU + 1
rounded rect CPU-composited into the same RT, `hard(>1)=0` vs an all-SW oracle
that includes the rounded rect:

```
[vgpu-mix] PASS: MIXED frame on the RTX 3090 — 8 ops GPU-rasterized,
           1 op CPU-composited (rounded rect) into the SAME RT,
           byte-matches the all-SW oracle (+/-1 UNORM)
```

### 2. Proportional-font coverage-mask resize pool

The batched glyph run previously required every cell to share one fixed R8
texture size. `virtio_gpu_3d_create_cov_tex` now **resizes** the reused coverage
texture when a later glyph's cell size differs (CTX_DETACH_RESOURCE +
RESOURCE_UNREF + `free_pages` + recreate at the new size), and
`vk_venus_glyph_run_resize` rebuilds the sampler view over the resized texture.
The blend CSO, cov vertex/fragment shaders and NEAREST sampler state are
size-independent and stay bound. Each glyph draws with its own w×h viewport over
a w×h texture — the same 1:1 texel→pixel mapping the single-cell cov draw already
byte-verifies. If the resize declines on any host, the router SW-composites that
glyph into the same RT (still byte-exact, counted).

**3090 result** — a run of 4 differently-sized cells (16×24, 24×16, 28×20,
12×12):

```
[vgpu-prop] varied-size glyph run: 4 glyphs GPU-rasterized, 0 SW-composited
[vgpu-prop] prop diff hard(>1)=0 soft(==1)=0
[vgpu-prop] PASS: 4 differently-sized glyph cells GPU-rasterized byte-exact
            via the resize-pool coverage atlas (+/-1 UNORM)
```

## Regression posture

* Router is **default-OFF** (`_vk_gpu_raster == 0`); the SW path is byte-for-byte
  unchanged. `scripts/test_vk_2d_host.sh` green.
* Existing 3090 markers all still PASS with zero regression: `[vgpu-multiop]`
  (4 op types), `[vgpu-blend]`, `[vgpu-cov]`, `[vgpu-frame]` (whole-frame,
  8 ops / 3 glyphs / 1 blit, `hard=0`).
* The frame selftest's old "ineligible op ⇒ whole-frame SW fallback" assertion is
  replaced by the per-op-mixing assertion (the whole point of the round); the
  honest counted whole-SW fallback still fires when a frame has NOTHING
  GPU-encodable or contains a 3D `VK_OP_DRAW`.

## Files

* `drivers/video/virtio_gpu.ad` — `virtio_gpu_3d_frame_rt_upload`,
  `_gpu_ctx_detach_resource`, `_gpu_resource_unref`, cov-texture resize pool.
* `lib/vk/vk_venus.ad` — `vk_venus_frame_upload`, `vk_venus_glyph_run_resize`.
* `lib/vk/vk_core.ad` — `_vk_op_gpu_encodable`, `_vk_frame_gpu_routable`,
  `_vk_gpu_sw_composite`, per-op mixing in `_vk_gpu_try_frame`, glyph resize in
  `_vk_gpu_frame_glyph_op`.
* `lib/vk/vk_selftest.ad` — `[vgpu-mix]` mixed-frame + `[vgpu-prop]`
  proportional-run byte-verifiers.
* `scripts/test_inguest_gpu_multiop_hw.sh` — surfaces the new markers.

## What remains toward driving the REAL hamUI/hambrowse frame recorder

* The frame RT / scratch RT / cov texture are cached at ONE size per boot; a real
  compositor renders many window sizes. The resize path now exists for the cov
  texture; the frame + scratch RTs still `decline` a differing size (a full
  window-sized RT pool is the next step).
* The resize pool tears down and recreates the cov texture on every size change.
  A real proportional run interleaves a handful of recurring sizes; a small LRU
  cache of per-size cov textures (or a true UV-sub-rect glyph atlas packed into
  one texture) would avoid the per-transition create/unref churn. The
  UV-sub-rect atlas needs a per-glyph uv-scale constant threaded into the cov
  vertex shader — deferred.
* The SW-composite path does a full-frame readback+upload per ineligible op. For
  frames with many rounded rects this is O(ops × frame bytes); batching
  consecutive SW ops between GPU ops into ONE readback/upload pair is a clear win.
* Wiring the actual hamUI `lib/hamscene.ad` / hambrowse `lib/htmlengine.ad` frame
  recorders' VK_OP_2D_* stream through this router (instead of the synthetic
  selftest scenes) is the remaining integration step.
