# In-guest WHOLE-FRAME auto-route + glyph batching on the RTX 3090 — 2026-07-18

**The rounds so far proved each frame PRIMITIVE byte-exact on the 3090 in
isolation; this round makes the accelerated desktop LIVE — a representative
DE/browser frame auto-routes end-to-end through the `vk_core` router onto the
GPU in ONE `vkQueueSubmit`, byte-identical to the vk2d SW oracle.** It also
batches a glyph text run onto a single reused host coverage texture instead of a
texture-create per glyph.

This is exactly the "next step" the coverage-mask round
(`docs/inguest_gpu_covmask_2026-07-18.md` §"What remains") named: (1) multi-glyph
batching and (2) `vk_core` auto-route of the coverage op.

## What is new

### 1. A glyph/coverage op in the op-stream (`VK_OP_2D_GLYPH`)

`vkCmd2DGlyph(cb, dx, dy, mw, mh, cov_ptr, ink_rgba)` records an 8-bit `mw×mh`
coverage cell at `(dx,dy)` in one ink colour — the primitive a DE/browser text
run is made of. SW-replayed via `vk2d_raster_cov_mask` (the golden oracle),
unchanged when GPU raster is off.

### 2. Whole-frame router covers glyphs + intra-frame blit

`_vk_frame_gpu_eligible` / `_vk_gpu_try_frame` (`lib/vk/vk_core.ad`) previously
routed only `FILL_RECT`, opaque `FILL_RECT_ALPHA`, and axis `DRAW_LINE`. This
round adds, to the SAME single-submit whole-frame replay:

| op | GPU encoding |
|----|--------------|
| `VK_OP_2D_GLYPH` (same-cell-size run, in-bounds) | batched R8 coverage sampler + source-over blend DRAW (±1 UNORM) |
| `VK_OP_2D_BLIT` (natural-size, source == frame image) | `RESOURCE_COPY_REGION` (intra-frame self-copy — the DE scroll/duplicate case) |

Any op the GPU can't reproduce byte-exactly — translucent fill, **diagonal**
line, **rounded rect**, a **scaled or cross-image** blit, a **mixed-cell-size**
glyph run — makes the whole frame ineligible, and it stays on the vk2d SW oracle,
**counted, never faked**. The router remains **opt-in, DEFAULT OFF**
(`vk_enable_gpu_raster`, refuses without a live virgl device).

### 3. Glyph batching — one reused texture, minimal SUBMIT_3D

`vk_venus_glyph_run_setup(cell_w, cell_h)` builds the blend pipeline + coverage
sampler **once per run**; the R8 coverage texture is created at the cell size and
**reused for every glyph** (`virtio_gpu_3d_create_cov_tex` returns its cached id
for a matching size). Each glyph is then just: write the cell's coverage into the
reused backing → `vk_venus_cov_upload` (one `TRANSFER_TO_HOST_3D`) →
`vk_venus_frame_glyph` (one `SUBMIT_3D`). A run of *N* same-sized cells costs
`3 setup + N draw` SUBMIT_3D instead of the naive `N×(create + 3 setup + draw)`.

`vk_venus_frame_glyph` **re-asserts the framebuffer to the frame surface** before
each draw: an interleaved opaque `frame_fill` binds the *scratch* surface as the
framebuffer via its CLEAR, so a bare `cov_draw` could otherwise land the glyph in
scratch. The rebind (a 4-dword `SET_FRAMEBUFFER_STATE` folded into the same
submit as viewport + colour + draw) makes glyph draws robust to any op ordering
within the frame — the router replays ops in **recorded order**, matching SW.

## Per-op GPU-vs-SW accounting

The router tallies the last GPU-routed frame's op mix, read back by the caller:

- `vk_gpu_last_frame_ops()` — total 2D ops rasterized on the GPU,
- `vk_gpu_last_frame_glyphs()` / `vk_gpu_last_frame_blits()` — of which glyphs / blits,
- `vk_gpu_last_frame_sw_ops()` — ops of the last frame that FELL BACK to SW.

In the current **whole-frame-or-nothing** model a routed frame is 100 % GPU
(`sw_ops = 0`); a frame with one ineligible op is 100 % SW (the GPU-frame counter
`vk_gpu_frames_rendered()` does not advance and `sw_ops > 0`). True **per-op**
mixing within one frame (GPU-encodable ops on the GPU, the rest SW, composited
into the same target) is the documented remaining work below.

## Self-test + gate

`vk_gpu_virgl_frame_selftest` (`lib/vk/vk_selftest.ad`, `[vgpu-frame]` markers)
records a 96×64 representative frame — blue clear, three opaque fills, a
horizontal axis line, a **3-cell batched glyph text run** (32×16 cells, each a
distinct per-pixel-varying AA ramp so a PASS can only come from real per-texel
sampling AND the cells genuinely differ), and an **intra-frame opaque blit** —
(the 96×64 frame + 32×16 cells match the multiop/cov selftests so the
boot-global cached frame RT + reused coverage texture agree — see remaining #2)
submits it once with GPU raster ON (router engages, `frames_rendered()`
advances), then renders the SAME scene with the vk2d SW oracle and byte-compares
(`hard(>1)` must be 0; glyph pixels may be ±1 UNORM). A SECOND frame that adds a
rounded rect then proves the **counted SW fallback**: the whole frame stays on
the oracle, the GPU-frame counter does not advance, `sw_ops > 0`.

Driven by `scripts/test_inguest_gpu_multiop_hw.sh` on the RTX 3090 (OVMF/KVM +
`-device virtio-gpu-gl-pci -display sdl,gl=on`, `DISPLAY=:0`), which now waits for
and reports the `[vgpu-frame]` byte-verify alongside the multi-op / blend / cov
proofs. Zero guest markers ⇒ INCONCLUSIVE; blank readback ⇒ INCONCLUSIVE; a
pixel mismatch ⇒ SKIP — never a faked pass.

## ON-DEVICE RESULT (RTX 3090, 2026-07-18) — BYTE-EXACT

The representative frame auto-routed **entirely** onto the RTX 3090 in one
`vkQueueSubmit` and read back **byte-identical** to the vk2d SW oracle —
`hard(>1)=0` AND `soft(==1)=0` (not even a 1-LSB divergence), `gl_version 46` /
`GL_RENDERER=NVIDIA`, `nvidia-smi` shows our QEMU resident. Multi-op / blend /
coverage still byte-exact — **zero regression**.

```
[vgpu-frame] router GPU-rasterized the frame: 8 ops (3 glyphs)
[vgpu-frame]   + 1 intra-frame blit(s), 0 SW-fallback ops (whole frame on the GPU)
[vgpu-frame] frame diff hard(>1)=0 soft(==1)=0
[vgpu-frame] router-ineligible op (rounded rect): whole frame stayed SW, 9 ops on the oracle (counted)
[vgpu-frame] PASS: representative DE/browser frame (fills + 3-glyph text run + blit) auto-routed onto the RTX 3090 byte-matches the SW oracle (+/-1 UNORM; 0 LSB-off)
[vgpu-frame] PASS: counted SW fallback confirmed (ineligible op keeps the whole frame on the oracle)
```

**GPU-vs-SW op mix for the real frame:** 8 ops on the GPU (3 opaque fills +
1 axis line + **3 batched glyphs** + 1 intra-frame blit), **0 SW-fallback**. The
counted-fallback frame (add a rounded rect) put all **9** ops on the CPU oracle
and the GPU-frame counter did not advance — the honest, never-faked fallback.

## What remains toward the fully-live GPU DE compositor

1. **True per-op SW mixing within one frame.** Today an ineligible op (rounded
   rect, translucent fill, diagonal line, scaled/cross-image blit) forces the
   WHOLE frame to SW. A live compositor wants the GPU-encodable ops on the GPU
   and only the residue on the CPU, composited into the same target — which needs
   the SW ops to write into the GPU RT (upload/interleave) or the GPU ops to land
   in the CPU image region-by-region. The all-or-nothing model is the honest
   current limit.
2. **Mask ATLAS with per-glyph sub-rect sampling.** Batching here reuses one
   texture at a FIXED cell size (same-size run). A proportional font needs
   varying cell sizes or a wide atlas texture with a per-glyph `SET_SAMPLER_VIEWS`
   sub-rect / uv-offset — a resize/atlas pool in `virtio_gpu_3d_create_cov_tex`
   (which today caches its first size and declines a differing one).
3. **Rounded rect on GPU** via the same coverage path (upload the AA corner
   coverage), removing it from the SW-fallback list.
4. **Translucent / scaled BLIT** via a textured-quad DRAW sampling the source RT
   with blend on (reuses the sampler machinery).
5. **Drive it from the real DE/browser compositor**, not a self-test scene — wire
   the hamUI/hambrowse frame recorder to emit `VK_OP_2D_GLYPH` for text and opt
   into `vk_enable_gpu_raster` on a measured-faster target.

## Files

- `lib/vk/vk_core.ad` — `VK_OP_2D_GLYPH` + `vkCmd2DGlyph`, SW replay
  `_vk_replay_2d_glyph`; router: `_vk_op_blit_gpu_ok`, glyph/blit branches in
  `_vk_frame_gpu_eligible` / `_vk_gpu_try_frame`, `_vk_gpu_frame_glyph_op`,
  per-op counters + accessors, `_vk_count_2d_ops`.
- `lib/vk/vk_venus.ad` — `vk_venus_glyph_run_setup`, `vk_venus_frame_glyph`
  (framebuffer-rebind + draw).
- `lib/vk/vk_selftest.ad` — `vk_gpu_virgl_frame_selftest` (`[vgpu-frame]`).
- `scripts/test_inguest_gpu_multiop_hw.sh` — waits for + reports the whole-frame
  byte-verify.
</content>
</invoke>
