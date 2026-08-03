# In-guest TRANSLUCENT (alpha-blended) fill on the RTX 3090 — 2026-07-18

**The first GPU op that BLENDS.** The multi-op frame
(`docs/inguest_gpu_multiop_2026-07-18.md`) put 4 OPAQUE op types on the RTX 3090
via CLEAR + `RESOURCE_COPY_REGION` — primitives that OVERWRITE, never composite.
This round lands the first op that **blends**: a **source-over translucent
fill** through a real **GL DRAW pipeline** (vertex + fragment TGSI shaders +
`GL_BLEND`), byte-compared in-guest to the vk2d SW oracle.

    out = src*a + dst*(1 - a)      # source-over, on the GPU

## What is new — a real DRAW pipeline (beyond CLEAR/copy)

`RESOURCE_COPY_REGION` cannot alpha-composite; a blend needs an actual draw with
the blend stage on. The new path (`lib/vk/vk_venus.ad`) encodes, over virgl:

| virgl command | role |
|---------------|------|
| `CREATE_OBJECT(SHADER)` ×2 + `BIND_SHADER` | vertex + fragment TGSI programs (host-parsed via `tgsi_text_translate` — no in-guest shader compiler) |
| `CREATE_OBJECT(BLEND)` + `BIND_OBJECT` | source-over blend CSO (rgb: `SRC_ALPHA`/`INV_SRC_ALPHA`, alpha: `ONE`/`INV_SRC_ALPHA` so dst alpha stays 1.0, matching vk2d) |
| `CREATE_OBJECT(VERTEX_ELEMENTS)` + `BIND` | one `R32G32B32A32_FLOAT` attribute |
| `SET_VERTEX_BUFFERS` | a persistent PIPE_BUFFER (virgl res id 5) holding the ±1 fullscreen quad, uploaded ONCE |
| `SET_VIEWPORT_STATE` | per-fill: re-aims the ±1 quad onto the pixel box (all scale/translate are exact `n/2` values) |
| `SET_CONSTANT_BUFFER` (fragment) | per-fill: the RGBA fill colour as float bits |
| `DRAW_VBO` | 4-vertex `TRIANGLE_STRIP` |

The two TGSI programs are tiny:

```
VERT   DCL IN[0]  DCL OUT[0],POSITION   MOV OUT[0], IN[0]        END
FRAG   DCL CONST[0]  DCL OUT[0],COLOR   MOV OUT[0], CONST[0]     END
```

Per-fill work is only viewport + colour-constant + draw; geometry (the quad) and
all CSOs are built once per frame in `vk_venus_blend_setup`.

## HONEST rounding: byte-match is ±1, not exact

GL UNORM blending computes on normalized floats and **rounds to nearest** on
store; the vk2d SW oracle does integer `(src*a + dst*(255-a)) / 255` which
**floors**. So a translucent GPU fill matches the oracle within **±1 per
channel** — a documented, expected 1-LSB difference, not byte-exact. The
self-test classifies every channel byte as exact / off-by-1 (soft) / off-by->1
(hard) and PASSes only when **hard == 0** (and the frame is non-blank). An
**opaque** fill (α=255) is still byte-exact and keeps using the CLEAR/copy path.

## Self-test + gate

`vk_gpu_virgl_blend_selftest` (`lib/vk/vk_selftest.ad`, `[vgpu-blend]` markers)
renders a 96×64 frame: opaque blue bg, an opaque red rect, then a **50%-alpha
white** rect straddling red and blue; reads back the GPU pixels and compares
(±1) to `vk2d_raster_fill_rect` + `vk2d_raster_fill_rect_alpha`. It SKIPs cleanly
on a plain-2D / dead-host-GL device (mismatch ⇒ SKIP, never a faked pixel).

Driven by the extended `scripts/test_inguest_gpu_multiop_hw.sh` on the RTX 3090
(OVMF/KVM + `-device virtio-gpu-gl-pci -display sdl,gl=on`, `DISPLAY=:0`); the
gate reports whether the translucent blend-draw byte-verified this run. Same
three host proofs as the multi-op gate (`gl_version 46`, `nvidia-smi` residency,
guest byte-compare GREEN).

## ON-DEVICE RESULT (RTX 3090, 2026-07-18) — BYTE-EXACT

Both the **sub-box** and **full-frame** translucent source-over fills rasterized
on the RTX 3090 **byte-identically** to the vk2d SW oracle — `hard(>1)=0` AND
`soft(==1)=0` (not even a 1-LSB divergence for these values), zero virglrenderer
errors:

```
[vgpu-blend]   tag=1 B=128 G=128 R=255   (white a=0.5 over RED  — source-over exact)
[vgpu-blend]   tag=9 B=255 G=128 R=128   (white a=0.5 over BLUE — source-over exact)
[vgpu-blend] box diff hard(>1)=0 soft(==1)=0
[vgpu-blend] full-frame diff hard(>1)=0 soft(==1)=0
[vgpu-blend] PASS: sub-box + full-frame translucent source-over fills on the RTX 3090 byte-match the SW oracle
```

Two encoding findings nailed on-device (both are the kind only hardware reveals):
- **`VIRGL_BIND_VERTEX_BUFFER = 1<<4` (0x10)**, NOT the gallium `PIPE_BIND` 1<<0
  — 0x1 is `DEPTH_STENCIL` and virglrenderer rejects it for a buffer
  (`Illegal buffer binding flags 0x1`).
- **The shader CREATE_OBJECT `offset` field carries the total TGSI-text byte
  length** for a single (non-continuation) packet, not 0 — a 0 yields
  `Invalid expected token count` and the shader create fails `EINVAL`.
- **Viewport is TOP-origin** for this RT's readback: a guest box `(y..y+h)` maps
  directly to window rows `(y..y+h)` (`VK_VENUS_VP_YFLIP=0`), verified by the
  byte-exact sub-box placement.

## Op inventory: GPU vs SW-fallback after this round

| Op | Status |
|----|--------|
| opaque FILL_RECT / FILL_RECT_ALPHA(α=255) | **GPU** (CLEAR + copy) |
| axis-aligned DRAW_LINE | **GPU** (bounding rect) |
| opaque 1:1 BLIT | **GPU** (`RESOURCE_COPY_REGION`) |
| **translucent FILL_RECT_ALPHA (α<255)** | **GPU (this round)** — source-over blend DRAW, ±1 |
| translucent BLIT (scaled/α<255) | SW-fallback (needs a textured-quad DRAW sampling the source) |
| AA-glyph text / coverage masks | SW-fallback (needs a sampler + coverage texture — see below) |
| rounded rect (AA corners) | SW-fallback (per-pixel coverage) |
| diagonal DRAW_LINE | SW-fallback |

Every op either byte-verifies on the GPU or stays on the vk2d SW oracle (the
golden), counted separately and never faked. The GPU-raster router stays
**opt-in, DEFAULT OFF**.

## What remains toward the full DE frame on GPU

1. **Coverage-mask / AA text** (the other big SW-fallback): upload the vk2d
   8-bit coverage mask as an `R8_UNORM` texture, add a `SAMPLER_VIEW` +
   `SAMPLER_STATE` + `SET_SAMPLER_VIEWS`/`BIND_SAMPLER_STATES`, and a fragment
   shader `TEX`-sampling coverage and multiplying `color*coverage` before the
   same source-over blend. The blend + DRAW spine landed here is the
   prerequisite; the missing piece is the sampler + coverage upload. This ports
   the `OP_COV_MASK` concept already proven on the HOST bridge to the in-guest
   virgl path.
2. **Translucent / scaled BLIT**: a textured-quad DRAW sampling the source RT
   (same sampler machinery as coverage) with blend on.
3. **Router auto-routing**: teach `_vk_frame_gpu_eligible` /`_vk_gpu_try_frame`
   to route translucent `FILL_RECT_ALPHA` to `vk_venus_blend_{setup,fill}`
   instead of declining the frame (today the blend path is exercised by the
   self-test; the router still treats α<255 as SW-only so nothing regresses).

## Files

- `lib/vk/vk_venus.ad` — draw-pipeline encoders (`_venus_encode_shader`,
  `_venus_encode_blend`, `_venus_encode_vertex_elements`,
  `_venus_encode_viewport`, `_venus_encode_set_frag_color`,
  `_venus_encode_draw_quad`) + `_f32_half_bits` (EXTERN-free int→float) +
  high-level `vk_venus_blend_setup` / `vk_venus_blend_fill`.
- `drivers/video/virtio_gpu.ad` — vertex buffer resource (res id 5) lifecycle
  (`virtio_gpu_3d_create_vbuf` / `_vbuf_backing` / `_vbuf_upload`).
- `lib/vk/vk_selftest.ad` — `vk_gpu_virgl_blend_selftest` (`[vgpu-blend]`).
- `scripts/test_inguest_gpu_multiop_hw.sh` — extended to report the blend-draw
  byte-verify.
</content>
</invoke>
