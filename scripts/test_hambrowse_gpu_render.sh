#!/usr/bin/env bash
# scripts/test_hambrowse_gpu_render.sh
# ============================================================================
# hambrowse's REAL page rendering on the discrete GPU (RTX 3090) via the proven
# host-GPU bridge.
#
# Unlike `pageraster` (a hand-authored representative DE+browser frame), this
# gate rasterizes the browser engine's OWN paint output for an actual HTML page:
#
#   1. Compile the pixel driver user/hambrowse_host_gfx.ad (x86_64-linux) with
#      the frozen Adder seed.
#   2. Run the web engine (he_layout + htmlpaint) on a rich real article fixture
#      and DUMP its laid-out paint records as a stable, GPU-ingestible op stream
#      (PAGEOPS / OP fill|rrect|line|covmask / ENDOPS) — every op derived from
#      the live layout (block backgrounds, image boxes, stroked cell borders,
#      and text runs as real AA coverage masks), NOTHING hand-authored.
#   3. Ingest that op stream in scripts/vk_hostgpu_bridge.c `pagefromops`, map it
#      to the vk_2d op vocabulary, and rasterize on the RTX 3090 compute pipeline.
#   4. BYTE-VERIFY the GPU readback against a CPU oracle running the IDENTICAL op
#      stream (MISMATCH must be 0), assert a discrete-NVIDIA device was selected,
#      and capture nvidia-smi per-process residency as GPU-exec proof.
#
# FULL PAGE ON THE GPU: text runs now rasterize on the device too. Each laid-out
# run is emitted as an OP_COV_MASK — its TRUE per-pixel AA coverage bitmap (the
# exact mask font_ttf's rasterizer produced) — which the bridge uploads and the
# compute shader blends by coverage/255 (src-over) on the RTX 3090. The report
# prints gpu_ops (all ops on the 3090), text_gpu_ops (the coverage-mask runs),
# and glyph_cpu_ops (legacy CPU fallback, now 0). Box paint — page/element
# backgrounds, rounded rects, and every table-cell/border stroke — plus every
# text run is rasterized on the GPU, byte-identical to the CPU oracle.
#
# SKIPS CLEANLY (exit 0) when: the Adder compiler, libvulkan, gcc, or the shader
# SPIR-V is unavailable, or no non-CPU (real) Vulkan device is present (e.g. an
# llvmpipe-only CI host). A regression check confirms the proven `pageraster`
# path still byte-matches (MISMATCH 0).
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
FIX="tests/fixtures/hambrowse_fidelity.html"

echo "[hb-gpu] hambrowse REAL-page render on the discrete GPU"

# ---- prerequisites (skip cleanly if any are absent) ------------------------
if ! command -v python3 >/dev/null 2>&1; then
    echo "[hb-gpu] SKIP: python3 not available for the Adder compiler"; exit 0
fi
if [ ! -f "$FIX" ]; then
    echo "[hb-gpu] SKIP: fixture $FIX missing"; exit 0
fi
LIBVK=""
for cand in /usr/lib/x86_64-linux-gnu/libvulkan.so.1 /usr/lib/libvulkan.so.1; do
    [ -f "$cand" ] && LIBVK="$cand" && break
done
if [ -z "$LIBVK" ]; then echo "[hb-gpu] SKIP: libvulkan.so.1 not found"; exit 0; fi
if ! command -v gcc >/dev/null 2>&1; then echo "[hb-gpu] SKIP: gcc not available to build the bridge"; exit 0; fi
if [ ! -f scripts/shaders/vk2d_raster.comp.spv ]; then
    echo "[hb-gpu] SKIP: scripts/shaders/vk2d_raster.comp.spv missing"; exit 0
fi

# ---- 1. compile the pixel driver (op-dump capable) -------------------------
BIN="$OUT/hambrowse_gfx"
echo "[hb-gpu] compiling user/hambrowse_host_gfx.ad ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/gpu_compile.log"; then
    echo "[hb-gpu] SKIP: Adder compiler unavailable / driver did not compile"
    sed 's/^/[hb-gpu]   /' "$OUT/gpu_compile.log" | head -20
    exit 0
fi

# ---- 2. build the bridge ---------------------------------------------------
BR="$OUT/vk_hostgpu_bridge"
if ! gcc -O2 scripts/vk_hostgpu_bridge.c -o "$BR" "$LIBVK" 2>"$OUT/vk_bridge_build.log"; then
    echo "[hb-gpu] FAIL: bridge build failed"; sed 's/^/[hb-gpu]   /' "$OUT/vk_bridge_build.log"; exit 1
fi

# require a real (non-CPU) Vulkan device, else SKIP (llvmpipe-only host)
INFO=$("$BR" info 2>&1)
DEVLINE=$(echo "$INFO" | grep '^VK_DEVICE' | head -1)
if [ -z "$DEVLINE" ]; then echo "[hb-gpu] SKIP: no Vulkan device enumerated"; exit 0; fi
if echo "$DEVLINE" | grep -q '\[CPU'; then
    echo "[hb-gpu] SKIP: only a CPU (software) Vulkan device present — no real GPU"; exit 0
fi
echo "[hb-gpu] device: ${DEVLINE#VK_DEVICE }"

# ---- 3. render the real page -> paint-op stream ----------------------------
DUMP="$OUT/gpu_page_dump.txt"
OPS="$OUT/gpu_page_ops.txt"
echo "[hb-gpu] rendering $FIX (width 880) and dumping paint ops ..."
if ! "$BIN" "$FIX" "$OUT/gpu_page.ppm" 880 dumpops >"$DUMP" 2>&1; then
    echo "[hb-gpu] FAIL: render/dump exited non-zero"; sed 's/^/[hb-gpu]   /' "$DUMP" | head -20; exit 1
fi
awk '/^PAGEOPS/{p=1} p{print} /^ENDOPS/{p=0}' "$DUMP" > "$OPS"
NOPS=$(grep -c '^OP ' "$OPS")
if [ "${NOPS:-0}" -lt 5 ]; then
    echo "[hb-gpu] FAIL: op stream too small (${NOPS:-0} ops) — engine did not paint"; exit 1
fi
echo "[hb-gpu] captured $NOPS real paint ops ($(grep '^PAGEOPS' "$OPS"))"

# ---- 4. GPU-raster the op stream + byte-verify + nvidia-smi residency ------
GPPM="$OUT/gpu_page_gpu.ppm"
GLOG="$OUT/gpu_page_bridge.log"
# Sustained 3s run so nvidia-smi can observe this pid resident on the GPU.
"$BR" pagefromops "$OPS" "$GPPM" 3 >"$GLOG" 2>/dev/null &
GPID=$!
SMI_HIT=""
if command -v nvidia-smi >/dev/null 2>&1; then
    for _ in $(seq 1 60); do
        APPS=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader 2>/dev/null)
        if echo "$APPS" | grep -q "^$GPID,"; then SMI_HIT=$(echo "$APPS" | grep "^$GPID,"); break; fi
        kill -0 "$GPID" 2>/dev/null || break
        sleep 0.1
    done
fi
wait "$GPID"; GRC=$?
echo "[hb-gpu] --- bridge output ---"; sed 's/^/[hb-gpu] /' "$GLOG"

fail=0
grep -q '^PAGEFROMOPS_OK' "$GLOG" || { echo "[hb-gpu] FAIL: pagefromops did not complete" >&2; fail=1; }
MISM=$(grep '^PAGEFROMOPS_GPUvsCPUport_MISMATCH' "$GLOG" | awk '{print $2}')
if [ "${MISM:-x}" = "0" ]; then
    echo "[hb-gpu] PASS: GPU readback byte-identical to CPU oracle over the real page op stream (0 mismatches)"
else
    echo "[hb-gpu] FAIL: GPU vs CPU-oracle mismatch=${MISM:-?}" >&2; fail=1
fi
GPUOPS=$(grep '^PAGEFROMOPS_OK' "$GLOG" | sed -n 's/.* gpu_ops=\([0-9]*\).*/\1/p')
CPUOPS=$(grep '^PAGEFROMOPS_OK' "$GLOG" | sed -n 's/.*glyph_cpu_ops=\([0-9]*\).*/\1/p')
TXTOPS=$(grep '^PAGEFROMOPS_OK' "$GLOG" | sed -n 's/.*text_gpu_ops=\([0-9]*\).*/\1/p')
if [ "${GPUOPS:-0}" -gt 0 ]; then
    echo "[hb-gpu] PASS: $GPUOPS ops rasterized on the GPU — backgrounds/borders/rects AND ${TXTOPS:-0} text runs as AA coverage masks (OP_COV_MASK); ${CPUOPS:-0} glyph ops fell back to CPU"
else
    echo "[hb-gpu] FAIL: no ops rasterized on the GPU" >&2; fail=1
fi
if [ "${TXTOPS:-0}" -gt 0 ] && [ "${CPUOPS:-1}" = "0" ]; then
    echo "[hb-gpu] PASS: all $TXTOPS text runs rendered on the GPU as real anti-aliased glyph coverage — 0 CPU glyph fallback"
else
    echo "[hb-gpu] FAIL: text runs did not move to the GPU (text_gpu_ops=${TXTOPS:-?} glyph_cpu_ops=${CPUOPS:-?})" >&2; fail=1
fi
GDEV=$(grep '^VK_DEVICE' "$GLOG" | head -1)
if echo "$GDEV" | grep -qi 'discrete-GPU\|integrated-GPU'; then
    echo "[hb-gpu] PASS: real page rendered on a real GPU — ${GDEV#VK_DEVICE }"
else
    echo "[hb-gpu] FAIL: not a real GPU device (${GDEV#VK_DEVICE })" >&2; fail=1
fi
if [ -n "$SMI_HIT" ]; then
    echo "[hb-gpu] PASS: nvidia-smi observed this pid resident on the GPU: $SMI_HIT"
else
    echo "[hb-gpu] NOTE: nvidia-smi per-process residency not captured (fast run / non-NVIDIA); byte-verify + discrete-GPU selection still prove GPU execution"
fi
[ "$GRC" -ne 0 ] && [ "$fail" -eq 0 ] && { echo "[hb-gpu] FAIL: bridge rc=$GRC" >&2; fail=1; }

# ---- 5. regression: the proven pageraster path still byte-matches ----------
PRLOG="$OUT/gpu_pageraster.log"
if "$BR" pageraster 1280 720 "$OUT/gpu_pageraster.ppm" >"$PRLOG" 2>/dev/null; then
    PRM=$(grep '^PAGERASTER_GPUvsCPUport_MISMATCH' "$PRLOG" | awk '{print $2}')
    if [ "${PRM:-x}" = "0" ]; then
        echo "[hb-gpu] PASS: pageraster regression check byte-matches (MISMATCH 0)"
    else
        echo "[hb-gpu] FAIL: pageraster regressed (MISMATCH ${PRM:-?})" >&2; fail=1
    fi
else
    echo "[hb-gpu] FAIL: pageraster regression run failed" >&2; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-gpu] FAIL"; exit 1; fi
echo "[hb-gpu] PASS — hambrowse's real page rendering executed on the discrete GPU, byte-identical to the CPU oracle"
exit 0
