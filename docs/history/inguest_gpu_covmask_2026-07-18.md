# In-guest AA COVERAGE-MASK (glyph TEXT) on the RTX 3090 — 2026-07-18

**The first GPU op that SAMPLES a texture — and the biggest remaining
desktop-frame primitive.** The blend round
(`docs/inguest_gpu_blend_2026-07-18.md`) landed the first op that composites: a
constant-colour source-over fill via a real GL DRAW + `GL_BLEND`. But a real
DE/browser frame is mostly **anti-aliased TEXT**, which has a **per-pixel**
alpha, not one alpha for the whole box. This round rasterizes that on the host
GPU: an 8-bit AA **coverage mask** uploaded as an `R8_UNORM` sampler texture,
`TEX`-sampled by a fragment shader and source-over-blended over the destination.

    a_eff = ink.a * coverage(x,y)          # per-pixel, sampled on the GPU
    out   = ink.rgb*a_eff + dst*(1-a_eff)   # source-over, via the round-8 blend CSO

## What is new — a texture sampler (beyond the constant-colour draw)

The round-8 draw emitted `OUT = CONST[0]` (one colour for the whole quad). AA
text needs to read a **per-texel** coverage value. The new path
(`lib/vk/vk_venus.ad`) adds, over virgl:

| virgl command | role |
|---------------|------|
| `RESOURCE_CREATE_3D` (R8_UNORM, `VIRGL_BIND_SAMPLER_VIEW`) | the coverage texture (virgl res id **6**), 1 byte/texel |
| `RESOURCE_ATTACH_BACKING` + `CTX_ATTACH_RESOURCE` | guest backing the CPU writes the mask into |
| `TRANSFER_TO_HOST_3D` | upload the w×h mask bytes (row stride = w) to the host texture |
| `CREATE_OBJECT(SAMPLER_VIEW)` | a view over the texture, identity swizzle |
| `CREATE_OBJECT(SAMPLER_STATE)` | **NEAREST** min/mag + **CLAMP_TO_EDGE** + no-mip ⇒ byte-exact texel fetch |
| `SET_SAMPLER_VIEWS` (fragment, slot 0) | bind the view to the FS |
| `BIND_SAMPLER_STATES` (fragment, slot 0) | bind the sampler to the FS |
| new cov vertex + fragment TGSI shaders | derive uv, `TEX`-sample, multiply coverage into alpha |

Everything else — the ±1 fullscreen quad vertex buffer, the vertex-elements CSO,
the **same source-over blend CSO**, the viewport re-aim, the colour constant, the
`DRAW_VBO` — is **reused unchanged** from the blend round. `vk_venus_cov_setup`
runs after `vk_venus_blend_setup` and only swaps in the cov shaders + wires the
sampler; `vk_venus_cov_draw` is byte-for-byte the same viewport+colour+draw as
`vk_venus_blend_fill` (only the bound FS differs).

The two TGSI programs:

```
VERT  DCL IN[0]  DCL OUT[0],POSITION  DCL OUT[1],GENERIC[0]
      IMM[0] {0.5,0.5,0,0}
      MOV OUT[0], IN[0]                 # clip position passthrough
      MAD OUT[1], IN[0], IMM[0], IMM[0] # uv = pos*0.5 + 0.5   END

FRAG  DCL IN[0],GENERIC[0]  DCL OUT[0],COLOR  DCL SAMP[0]  DCL SVIEW[0],2D,FLOAT
      DCL CONST[0]  DCL TEMP[0]
      TEX  TEMP[0], IN[0], SAMP[0], 2D  # sample coverage (R channel)
      MOV  OUT[0], CONST[0]             # rgb = ink, a = ink.a
      MUL  OUT[0].w, CONST[0], TEMP[0].xxxx  # a = ink.a * coverage   END
```

The vertex shader **derives** the texcoord from clip position (u = x·0.5+0.5,
v = y·0.5+0.5), so texel (0,0) lands at the box's **top-left** — matching the
round-8 finding that this RT's readback is top-origin (`VK_VENUS_VP_YFLIP=0`).
No second vertex attribute is needed. With NEAREST + a box whose size equals the
mask size, pixel *i* centre → texcoord (i+0.5)/w → **texel i** (1:1).

## Reference math parity

The GPU output equals `vk2d_raster_cov_mask` (the SW oracle,
`lib/vk/vk_2d.ad`), which is itself the twin of the host bridge's `OP_COV_MASK`
(`pr_cpu_covmask` in `scripts/vk_hostgpu_bridge.c`): `a_eff = cov * ink.a / 255`
then source-over. GL UNORM blending rounds-to-nearest vs the oracle's floor, so
the documented tolerance is **±1 per channel** — but for the tested values it
came back **0 LSB off** (byte-identical).

## Self-test + gate

`vk_gpu_virgl_cov_selftest` (`lib/vk/vk_selftest.ad`, `[vgpu-cov]` markers)
renders a 96×64 frame: opaque blue bg, then a 32×16 coverage mask filled with a
deterministic **diagonal gradient** `cov = ((c+r)·255)/(MW+MH-2)` stamped in
opaque white ink at (16,16). The gradient VARIES per-pixel, so a PASS can only
come from a genuine per-texel sample — a constant-alpha fill could not reproduce
it. Reads back the GPU pixels and compares (±1) to `vk2d_raster_fill_rect` +
`vk2d_raster_cov_mask` over the SAME mask bytes. Mismatch ⇒ SKIP, blank ⇒
INCONCLUSIVE — never a faked pixel.

Driven by the extended `scripts/test_inguest_gpu_multiop_hw.sh` on the RTX 3090
(OVMF/KVM + `-device virtio-gpu-gl-pci -display sdl,gl=on`, `DISPLAY=:0`), which
now waits for and reports the `[vgpu-cov]` byte-verify alongside the multi-op and
blend proofs.

## ON-DEVICE RESULT (RTX 3090, 2026-07-18) — BYTE-EXACT

The AA coverage mask sampled + source-over-blended on the RTX 3090
**byte-identically** to the vk2d SW oracle — `hard(>1)=0` AND `soft(==1)=0` (not
even a 1-LSB divergence for these values), zero virglrenderer errors,
`gl_version 46` / `GL_RENDERER=NVIDIA`, `nvidia-smi` shows our QEMU resident:

```
[vgpu-cov]   tag=21 B=255 G=33  R=33    (low-coverage corner: mostly blue bg through the mask)
[vgpu-cov]   tag=22 B=255 G=199 R=199   (high-coverage corner: white ink dominant)
[vgpu-cov] mask diff hard(>1)=0 soft(==1)=0
[vgpu-cov] PASS: AA coverage mask sampled + source-over-blended on the RTX 3090 byte-matches the SW oracle
```

The two sample points prove real texture sampling: the per-pixel result tracks
the mask gradient exactly (low coverage ⇒ background shows through, high coverage
⇒ ink). Multi-op (4 opaque op types) and translucent-blend still byte-exact — no
regression.

### Encoding facts used (documented, cross-validated — not guessed)

No mesa/virglrenderer headers are installed on the build host (only the runtime
`libvirglrenderer1`), so the sampler enums come from `virgl_protocol.h` /
`virgl_hw.h` as documented, **cross-validated against the ids already proven
byte-exact in this file** (CLEAR=7, DRAW_VBO=8, SET_CONSTANT_BUFFER=12,
COPY_REGION=17, BIND_SHADER=31; OBJECT_BLEND=1, SHADER=4, VERTEX_ELEMENTS=5,
SURFACE=8; BIND_VERTEX_BUFFER=0x10) — the same enum sequences place the new
values consistently, and the on-device byte-exact PASS confirms them:

- **`VIRGL_BIND_SAMPLER_VIEW = 1<<3` (0x8)** — a texture bound this way backs a
  `SAMPLER_VIEW` (NOT 1<<0 DEPTH_STENCIL, NOT 1<<4 VERTEX_BUFFER; a wrong bit ⇒
  "Illegal buffer binding flags").
- `VIRGL_CCMD_SET_SAMPLER_VIEWS = 10`, `VIRGL_CCMD_BIND_SAMPLER_STATES = 18`.
- `VIRGL_OBJECT_SAMPLER_VIEW = 6`, `VIRGL_OBJECT_SAMPLER_STATE = 7`.
- SAMPLER_VIEW body (6 dw): handle, res, format, (first|last layer),
  (first|last level), swizzle. SAMPLER_STATE body (9 dw): handle, S0
  (wrap/filter bits), lod_bias, min_lod, max_lod, border[4].
- The shader CREATE_OBJECT `offset` = total TGSI-text byte length (from round 8).
  The cov FS is ~60 dwords, so `venus_cmd_buf` was grown 64→100 dwords (capped by
  the device's ~100-dword / 400-byte SUBMIT_3D scratch).

## Op inventory: GPU vs SW-fallback after this round

| Op | Status |
|----|--------|
| opaque FILL_RECT / FILL_RECT_ALPHA(α=255) | **GPU** (CLEAR + copy) |
| axis-aligned DRAW_LINE | **GPU** (bounding rect) |
| opaque 1:1 BLIT | **GPU** (`RESOURCE_COPY_REGION`) |
| translucent FILL_RECT_ALPHA (α<255) | **GPU** (source-over blend DRAW, ±1) |
| **AA-glyph TEXT / coverage masks** | **GPU (this round)** — R8 sampler + TEX shader + blend, ±1 |
| rounded rect (AA corners) | **GPU-capable (this round)** — same coverage-mask path (upload the corner's per-pixel coverage) |
| translucent BLIT (scaled/α<255) | SW-fallback (needs a textured-quad DRAW sampling the source RT) |
| diagonal DRAW_LINE | SW-fallback |

Every op either byte-verifies on the GPU or stays on the vk2d SW oracle (the
golden), counted separately and never faked. The GPU-raster router stays
**opt-in, DEFAULT OFF**.

## What remains toward the full DE text frame on GPU

1. **Multi-glyph batching / mask atlas.** This round byte-verifies ONE coverage
   mask per draw at a fixed texture size (the cov texture caches its first size,
   declines a differing size — like the frame RT). A real text run is dozens of
   glyphs; the next step is a mask **atlas** (or a resize/pool) so a whole run
   uploads once and each glyph is a sub-rect `SET_SAMPLER_VIEWS` + viewport +
   draw, amortizing the per-glyph state.
2. **vk_core auto-route.** Today `vk_venus_cov_{setup,upload,draw}` is exercised
   by the self-test; the vk_core glyph/coverage op still rasterizes on the vk2d
   SW oracle. Wiring `_vk_frame_gpu_eligible` / `_vk_gpu_try_frame` to route a
   coverage op through this path (when the GPU is enabled+present) is the router
   change that puts real DE/browser text on the 3090 — kept opt-in DEFAULT OFF
   until batching lands so nothing regresses.
3. **Translucent / scaled BLIT** reuses the same sampler machinery (a textured
   quad sampling the source RT with blend on).

## Files

- `drivers/video/virtio_gpu.ad` — coverage texture (res id 6) lifecycle:
  `VIRGL_BIND_SAMPLER_VIEW`, `virtio_gpu_3d_create_cov_tex` / `_cov_tex_backing`
  / `_cov_tex_upload`.
- `lib/vk/vk_venus.ad` — sampler encoders (`_venus_encode_sampler_view`,
  `_venus_encode_sampler_state`, `_venus_encode_set_sampler_views`,
  `_venus_encode_bind_sampler_states`) + `vk_venus_cov_setup` /
  `vk_venus_cov_backing` / `vk_venus_cov_upload` / `vk_venus_cov_draw`;
  `venus_cmd_buf` grown 64→100 dwords.
- `lib/vk/vk_selftest.ad` — `vk_gpu_virgl_cov_selftest` (`[vgpu-cov]`).
- `scripts/test_inguest_gpu_multiop_hw.sh` — waits for + reports the
  coverage-mask byte-verify.
</content>
