# In-guest GPU compositor: the REAL DE-compositor frame on the RTX 3090 (GPU track #182, round 12)

The culminating step of GPU track #182: route the **actual Hamnix DE compositor's
frame** — a real window scene DISPLAY LIST in the exact `/dev/wsys/<wid>/scene`
grammar that hamUI apps emit — through the `vk_core` GPU frame router onto the
RTX 3090, instead of a synthetic hand-built op stream. Byte-identical (±1 UNORM
for glyph coverage) to the vk2d SW oracle for the same op stream, via
`scripts/test_inguest_gpu_multiop_hw.sh` (`[vgpu-dew]` markers).

## The seam that was missing

Rounds 1–11 proved the router GPU-rasterizes every VK_OP_2D op type and mixes
GPU/SW per-op — but only for **synthetic** scenes: `vk_selftest.ad` hand-built
`vkCmd2D*` op streams. The **real** DE compositor never produced a
`VkCommandBuffer` at all.

`sys/src/9/port/devwsys.ad` `_wsys_rasterize_window_clip` → `_wsys_rast_line` is
the DE compositor's frame-emit path: it parses each window's scene text display
list and rasterizes every primitive **directly** into the per-window RGBA cache
with its own inner loops (`_wsys_cache_fillrect`, `_wsys_cache_roundrect`,
`_wsys_cache_draw_char_w`, …). That direct raster is a **raw framebuffer** path —
it emits no VK ops, so the GPU router had never seen a real DE frame.

The scene text itself (built by `lib/hamscene.ad`, written to
`/dev/wsys/<wid>/scene`, parsed by `_wsys_rast_line`) IS the DE frame's portable
representation. The clean seam is therefore: **translate that scene grammar into
a VK_OP_2D command buffer and submit it through the router.**

## What shipped

### `vk_scene_to_cmdbuf()` — DE scene display-list → VK_OP_2D command buffer

New in `lib/vk/vk_core.ad`. Parses the same scene grammar `_wsys_rast_line`
parses and translates each primitive into the VK op the router already
GPU-rasterizes:

| scene verb            | VK op(s)                                   | router path              |
|-----------------------|--------------------------------------------|--------------------------|
| `fill` / `rect`       | `vkCmd2DFillRect` / `…RectAlpha`           | GPU (opaque) / SW (alpha)|
| `stroke`              | 4× `vkCmd2DFillRect` (the four edges)      | GPU                      |
| `line`                | `vkCmd2DDrawLine`                          | GPU (axis) / SW (diag)   |
| `roundrect`           | `vkCmd2DFillRoundRect`                     | SW-composited into GPU RT|
| `glyphs`              | `vkCmd2DGlyph` per char, 8×16 coverage     | GPU atlas / SW-composited|
| `text` (AA prop TTF)  | tallied unencodable (8×16 font ≠ TTF)      | counted, not faked       |
| `image` / `buffer` / `clip` | tallied unencodable this round       | counted, not faked       |

Glyph coverage cells are built from the DE's **own** 8×16 console font
(`fb_font_glyph_addr()`, 255 where the bitmap bit is set, 0 elsewhere — exactly
`_wsys_cache_draw_char_w`'s semantics) packed into a caller-supplied arena. The
translator is decoupled from `fb_text` (font base is a parameter) and exposes
per-vocabulary tallies (`vk_scene_ops_fills/lines/glyphs/rrects/unenc`).

### `vk_gpu_virgl_de_selftest()` — byte-verify a REAL DE frame on the 3090

New in `lib/vk/vk_selftest.ad` (dispatched from `vk_gpu_backend_selftest`, so no
edit to `init/main.ad`; marker prefix `[vgpu-dew]`, distinct from
`vk_de_present_selftest`'s `[vgpu-de]`). It builds a representative **real DE
window scene** — a compact 96×64 Settings dialog: title bar + "Settings" title
glyphs, a "Dark" label, OK/No rounded-rect buttons with labels, a bordered
field, and a (unencodable) `image` verb — in the exact `/dev/wsys` grammar. The
window is kept under `VK_MAX_CMDS` (64) ops with an order-3 image backing, and the
test runs right after the multiop test (before the heavier blend/cov/frame tests)
so its 96×64 image pair allocates under freer slab memory. Then:

1. `vk_scene_to_cmdbuf` → two identical VK op streams (one per target image).
2. Submit with `vk_enable_gpu_raster()` ON → the 3090 rasterizes it (fills / axis
   lines / glyphs on the GPU; the two rounded rects CPU-composited into the SAME
   RT in draw order — per-op mixing).
3. Submit the same op stream with GPU raster OFF → the vk2d SW oracle.
4. `_vk_bl_diff` byte-compares the read-back GPU pixels to the SW oracle
   (`hard(>1)` must be 0; `nz>0` guards a blank readback).

Reported per-op mix: `vk_scene_ops_*` (scene vocabulary), plus the router's
`vk_gpu_last_frame_ops()` (GPU) vs `vk_gpu_last_frame_sw_ops()` (CPU-composited).

The default stays SW: `vk_enable_gpu_raster` is opt-in and refuses without a live
virgl device; the self-test disables it again immediately, so the golden SW
`vk_2d` path is untouched.

## Honesty: the exact remaining seam

This round proves the **real DE frame's op stream** GPU-rasterizes byte-identically
to `vk_2d` SW. It does NOT yet make the running `devwsys` compositor call the GPU
per present. Two pieces remain to a fully-live GPU desktop:

1. **`devwsys` → router wiring.** `_wsys_rasterize_window_clip` should build a
   `VkCommandBuffer` via `vk_scene_to_cmdbuf` and `vkQueueSubmit` it (behind the
   `vk_enable_gpu_raster` opt-in) instead of its `_wsys_cache_*` inner loops,
   reading the GPU result back into the window's RGBA cache. This is a kernel-side,
   on-device change verified by driving the booted DE, not a host byte-compare.
2. **AA proportional text.** The DE prefers the embedded DejaVu TTF face
   (`_wsys_cache_draw_str_aa`, `WSYS_UI_PX=14`) over the 8×16 bitmap when the font
   is loaded. To route `text` (not just `glyphs`) the translator must emit
   VK_OP_2D_GLYPH cells from `font_ttf`/`glyph_cov` coverage (variable w/h — the
   resize-pool atlas, already proven by `[vgpu-prop]`). Until then `text` is
   tallied unencodable and would SW-compose.

Both are documented here so the claim is precise: a REAL DE scene's op stream is
byte-verified on the 3090; the compositor's live per-present submit is the next
kernel-side step.

## Verification

`scripts/test_inguest_gpu_multiop_hw.sh` on the RTX 3090 (`-display sdl,gl=on`,
`DISPLAY=:0`, virglrenderer GL 4.6 = NVIDIA, `nvidia-smi` QEMU pid resident),
`[vgpu-dew] PASS` with `hard(>1)=0`. SKIPs cleanly headless / on a plain 2D device.
Existing `[vgpu-multiop]/[vgpu-blend]/[vgpu-cov]/[vgpu-frame]/[vgpu-mix]/[vgpu-prop]`
markers and the `test_vk_2d_host` host gate are unaffected; the router stays
default-OFF.
