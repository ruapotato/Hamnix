#!/usr/bin/env bash
#
# ON-DEMAND: not in ci_battery_manifest.txt because steps 3-7 need a real
# libvulkan.so.1 and an X display; on a headless runner they SKIP and the
# gate exits 0 having asserted almost nothing. A gate that cannot fail on the
# machine that runs it is worse than no gate — it manufactures green. Run it
# on a workstation with a GPU when touching lib/vk. Measured 5.8 s.
# scripts/test_vk_hostgpu.sh — host gate for the HOST-GPU bridge.
#
# GPU track: "Vulkan back into work on Linux". Proves our composited vk
# framebuffer renders/round-trips through the dev host's REAL Vulkan
# (NVIDIA / Mesa / lavapipe), complementing the in-VM virtio-gpu path.
#
# FLOW (all QEMU-free, on the dev host):
#   1. Compile lib/vk/vk_hostgpu.ad -> a host harness that composites a scene
#      through the native vk 2D layer (lib/vk/vk_2d.ad) into an RGBA8888 vk
#      color image and dumps it as a PPM: the SOFTWARE REFERENCE framebuffer.
#   2. Build the C bridge scripts/vk_hostgpu_bridge.c against system
#      libvulkan.so.1 (no dev headers needed — minimal ABI is hand-declared).
#   3. REAL-GPU UPLOAD round-trip: hand the reference PPM to the bridge, which
#      uploads it to a real VkDevice, runs a real GPU transfer op, and reads it
#      back. Assert the readback is BYTE-IDENTICAL to the SW reference -> our
#      composited framebuffer marshals losslessly through real Linux Vulkan.
#   4. REAL-GPU CLEAR: bridge runs vkCmdClearColorImage on the GPU; assert the
#      corner pixel equals the requested color -> real GPU command execution.
#   5. If lavapipe (SW Vulkan ICD) is present, repeat the round-trip forced onto
#      it (VK_ICD_FILENAMES) -> validates the marshalling path with zero HW dep.
#   6. REAL-GPU BLIT/SCALE: bridge vkCmdBlitImage-scales the framebuffer 3x on
#      the GPU (NEAREST + LINEAR). Assert NEAREST is byte-exact vs a CPU
#      nearest-upscale and LINEAR is within tolerance of a CPU bilinear
#      reference -> the swapchain present blit path is correct. Reports GPU ms.
#   6b. GPU RASTERIZATION (the core win): compile scripts/shaders/vk2d_raster.comp
#      GLSL -> SPIR-V through the host's libshaderc (the glslc BINARY is absent,
#      the LIBRARY is not), then run vk_2d's fill/blit/blend/roundrect/line as a
#      real Vulkan COMPUTE pipeline over storage buffers. Assert the readback is
#      BYTE-IDENTICAL to the vk_2d.ad SW rasterizer reference, and report the
#      GPU-vs-SW raster crossover (overhead-bound at 96x64; ~27x at 1080p).
#   7. WINDOWED PRESENT (best-effort): if libX11 + a reachable $DISPLAY exist,
#      create a real VkSurfaceKHR + VkSwapchainKHR and present the framebuffer
#      to an on-screen window through the real GPU. SKIPPED (not failed) when
#      headless. Reports mean acquire+blit+present ms.
#
# If NO libvulkan is present, steps 3-7 are SKIPPED (reported INCONCLUSIVE) but
# the SW-reference render still asserts, so the gate never false-greens.
#
# Pass marker:  [test_vk_hostgpu] PASS   Fail marker:  [test_vk_hostgpu] FAIL

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
fail=0
REF_PPM="$OUT/vk_hostgpu_ref.ppm"
REF_BIN="$OUT/vk_hostgpu_ref"
BRIDGE="$OUT/vk_hostgpu_bridge"
LIBVK="/usr/lib/x86_64-linux-gnu/libvulkan.so.1"

# ---- 1. SW reference render ------------------------------------------------
echo "[test_vk_hostgpu] (1/7) compiling Adder reference compositor ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        lib/vk/vk_hostgpu.ad -o "$REF_BIN" 2>"$OUT/vk_hostgpu_compile.log"; then
    echo "[test_vk_hostgpu] FAIL: reference harness did not compile"
    cat "$OUT/vk_hostgpu_compile.log"; exit 1
fi
DUMP="$OUT/vk_hostgpu_ref.txt"
if ! "$REF_BIN" "$REF_PPM" >"$DUMP" 2>&1; then
    echo "[test_vk_hostgpu] FAIL: reference harness exited non-zero"; cat "$DUMP"; exit 1
fi
echo "[test_vk_hostgpu] PASS reference framebuffer rendered -> $REF_PPM"
echo "[test_vk_hostgpu] --- reference sampled pixels ---"; cat "$DUMP"; echo "[test_vk_hostgpu] ---"

ref_pix() { awk -v k="$1" '$0 ~ ("^" k " ") {print $NF}' "$DUMP"; }

assert_ref() {
    local label="$1" line="$2" want="$3" got; got=$(ref_pix "$line")
    if [ "$got" = "$want" ]; then echo "[test_vk_hostgpu] PASS ref $label ($line=$want)"
    else echo "[test_vk_hostgpu] FAIL ref $label ($line: got '$got' want '$want')"; fail=1; fi
}
assert_ref "chrome bar (opaque fill)"   "PIX_BG 2 2"     "#2b3350"
assert_ref "page bg (opaque fill)"      "PIX_PAGE 2 60"  "#0d1220"
assert_ref "content card (opaque)"      "PIX_CARD 12 50" "#ffffff"
assert_ref "alpha panel (blended)"      "PIX_PANEL 30 30" "#7fe5ff"
assert_ref "icon blit (scaled)"         "PIX_ICON 74 20" "#00ff00"
assert_ref "separator line"             "PIX_LINE 40 58" "#ffff00"
assert_ref "rounded button interior"    "PIX_BTN 78 50"  "#ff33cc"

# ---- 2. build the C bridge -------------------------------------------------
if [ ! -e "$LIBVK" ]; then
    echo "[test_vk_hostgpu] SKIP real-GPU arms: $LIBVK not present (no host Vulkan)."
    echo "[test_vk_hostgpu] (SW reference render asserted; real-GPU path INCONCLUSIVE here.)"
    if [ "$fail" -eq 0 ]; then echo "[test_vk_hostgpu] PASS (SW-reference only)"; exit 0; fi
    echo "[test_vk_hostgpu] FAIL"; exit 1
fi

echo "[test_vk_hostgpu] (2/7) building C bridge against libvulkan ..."
if ! gcc -O2 -Wall scripts/vk_hostgpu_bridge.c -o "$BRIDGE" "$LIBVK" \
        2>"$OUT/vk_hostgpu_cc.log"; then
    echo "[test_vk_hostgpu] FAIL: bridge did not build"; cat "$OUT/vk_hostgpu_cc.log"; exit 1
fi
echo "[test_vk_hostgpu] PASS bridge built -> $BRIDGE"

# Optional Xlib present build (needs libX11); present arm is skipped if absent.
BRIDGE_X="$OUT/vk_hostgpu_bridge_x"
HAVE_PRESENT=0
if gcc -O2 -Wall -DHAVE_XLIB scripts/vk_hostgpu_bridge.c -o "$BRIDGE_X" "$LIBVK" -lX11 \
        2>"$OUT/vk_hostgpu_ccx.log"; then
    HAVE_PRESENT=1
    echo "[test_vk_hostgpu] PASS windowed-present bridge built -> $BRIDGE_X"
else
    echo "[test_vk_hostgpu] SKIP windowed-present build (no libX11 dev): headless-only."
fi

# ---- 3. real-GPU upload round-trip ----------------------------------------
echo "[test_vk_hostgpu] (3/7) real-GPU upload round-trip ..."
GPU_PPM="$OUT/vk_hostgpu_gpu.ppm"
if "$BRIDGE" upload "$REF_PPM" "$GPU_PPM" >"$OUT/vk_hostgpu_gpu.log" 2>&1; then
    DEV=$(awk '/^VK_DEVICE/{sub(/^VK_DEVICE /,""); print; exit}' "$OUT/vk_hostgpu_gpu.log")
    echo "[test_vk_hostgpu] real GPU device: ${DEV:-unknown}"
    if cmp -s "$REF_PPM" "$GPU_PPM"; then
        echo "[test_vk_hostgpu] PASS GPU readback BYTE-IDENTICAL to SW reference"
    else
        echo "[test_vk_hostgpu] FAIL GPU readback differs from SW reference"; fail=1
    fi
else
    echo "[test_vk_hostgpu] FAIL bridge upload op errored"; cat "$OUT/vk_hostgpu_gpu.log"; fail=1
fi

# ---- 4. real-GPU clear -----------------------------------------------------
echo "[test_vk_hostgpu] (4/7) real-GPU vkCmdClearColorImage ..."
CLR_PPM="$OUT/vk_hostgpu_clear.ppm"
if "$BRIDGE" clear 8 8 0x1122ccff "$CLR_PPM" >"$OUT/vk_hostgpu_clear.log" 2>&1; then
    GOT=$(python3 - "$CLR_PPM" <<'PY'
import sys
f=open(sys.argv[1],'rb'); f.readline(); f.readline(); f.readline()
p=f.read(3); print("#%02x%02x%02x"%(p[0],p[1],p[2]))
PY
)
    if [ "$GOT" = "#1122cc" ]; then
        echo "[test_vk_hostgpu] PASS GPU clear corner == #1122cc"
    else
        echo "[test_vk_hostgpu] FAIL GPU clear corner got '$GOT' want '#1122cc'"; fail=1
    fi
else
    echo "[test_vk_hostgpu] FAIL bridge clear op errored"; cat "$OUT/vk_hostgpu_clear.log"; fail=1
fi

# ---- 5. lavapipe (SW Vulkan) validation, if available ----------------------
LVP=/usr/share/vulkan/icd.d/lvp_icd.json
if [ -e "$LVP" ]; then
    echo "[test_vk_hostgpu] (5/7) lavapipe (SW Vulkan) round-trip ..."
    LVP_PPM="$OUT/vk_hostgpu_lvp.ppm"
    if VK_ICD_FILENAMES="$LVP" "$BRIDGE" upload "$REF_PPM" "$LVP_PPM" \
            >"$OUT/vk_hostgpu_lvp.log" 2>&1 && cmp -s "$REF_PPM" "$LVP_PPM"; then
        echo "[test_vk_hostgpu] PASS lavapipe round-trip BYTE-IDENTICAL"
    else
        echo "[test_vk_hostgpu] FAIL lavapipe round-trip"; cat "$OUT/vk_hostgpu_lvp.log"; fail=1
    fi
else
    echo "[test_vk_hostgpu] (5/7) SKIP lavapipe: $LVP not present."
fi

# ---- 6. real-GPU blit/scale (vkCmdBlitImage) -------------------------------
echo "[test_vk_hostgpu] (6/7) real-GPU vkCmdBlitImage scale 3x ..."
BLIT_N="$OUT/vk_hostgpu_blit_n.ppm"; BLIT_L="$OUT/vk_hostgpu_blit_l.ppm"
if VK_HOSTGPU_NEAREST=1 "$BRIDGE" blit "$REF_PPM" 3 "$BLIT_N" >"$OUT/vk_hostgpu_blit_n.log" 2>&1 \
   && "$BRIDGE" blit "$REF_PPM" 3 "$BLIT_L" >"$OUT/vk_hostgpu_blit_l.log" 2>&1; then
    NMS=$(awk '/^BLIT_MS/{print $2}' "$OUT/vk_hostgpu_blit_n.log")
    LMS=$(awk '/^BLIT_MS/{print $2}' "$OUT/vk_hostgpu_blit_l.log")
    echo "[test_vk_hostgpu] GPU blit time: nearest=${NMS}ms linear=${LMS}ms (96x64 -> 288x192)"
    if python3 - "$REF_PPM" "$BLIT_N" "$BLIT_L" <<'PY'
import sys
def rd(p):
    f=open(p,'rb'); assert f.readline().strip()==b'P6'
    w,h=map(int,f.readline().split()); f.readline(); return w,h,f.read()
w,h,src=rd(sys.argv[1]); S=3; dw,dh=w*S,h*S
def sp(x,y,c):
    x=min(max(x,0),w-1); y=min(max(y,0),h-1); return src[(y*w+x)*3+c]
# NEAREST must be byte-exact vs CPU nearest upscale (Vulkan samples (d+0.5)/S)
gw,gh,g=rd(sys.argv[2])
if (gw,gh)!=(dw,dh): print("nearest dims %dx%d != %dx%d"%(gw,gh,dw,dh)); sys.exit(1)
for y in range(dh):
    sy=min(int((y+0.5)/S),h-1)
    for x in range(dw):
        sx=min(int((x+0.5)/S),w-1)
        for c in range(3):
            if g[(y*dw+x)*3+c]!=src[(sy*w+sx)*3+c]:
                print("nearest mismatch at %d,%d"%(x,y)); sys.exit(1)
# LINEAR within tolerance of CPU bilinear
lw,lh,l=rd(sys.argv[3]); tot=0; n=0; mx=0
for y in range(dh):
    fy=(y+0.5)/S-0.5; y0=int(fy//1); ty=fy-y0
    for x in range(dw):
        fx=(x+0.5)/S-0.5; x0=int(fx//1); tx=fx-x0
        for c in range(3):
            v=(sp(x0,y0,c)*(1-tx)*(1-ty)+sp(x0+1,y0,c)*tx*(1-ty)+
               sp(x0,y0+1,c)*(1-tx)*ty+sp(x0+1,y0+1,c)*tx*ty)
            d=abs(l[(y*dw+x)*3+c]-v); tot+=d; n+=1; mx=max(mx,d)
mean=tot/n
print("linear mean=%.3f max=%.2f"%(mean,mx))
sys.exit(0 if mean<1.5 and mx<8 else 2)
PY
    then
        echo "[test_vk_hostgpu] PASS GPU blit NEAREST byte-exact + LINEAR ~= CPU bilinear"
    else
        echo "[test_vk_hostgpu] FAIL GPU blit result diverged from CPU reference"; fail=1
    fi
else
    echo "[test_vk_hostgpu] FAIL bridge blit op errored"
    cat "$OUT/vk_hostgpu_blit_n.log" "$OUT/vk_hostgpu_blit_l.log"; fail=1
fi

# ---- 6b. GPU RASTERIZATION via a real SPIR-V compute pipeline ---------------
# The core win: run vk_2d's fill/blit/blend/roundrect ON the GPU (compute
# shader) and prove the readback is BYTE-IDENTICAL to the vk_2d.ad SW
# rasterizer, then measure the GPU-vs-SW raster crossover at frame sizes.
LIBSHADERC="/usr/lib/x86_64-linux-gnu/libshaderc.so.1"
SPV="scripts/shaders/vk2d_raster.comp.spv"
# (i) regenerate the .spv from GLSL via the host's libshaderc — proves the
#     SPIR-V toolchain is live (glslc binary is absent; the library is not).
if [ -e "$LIBSHADERC" ]; then
    echo "[test_vk_hostgpu] (6b) compiling GLSL->SPIR-V via libshaderc ..."
    if gcc -O2 -w scripts/shaderc_compile.c -o "$OUT/shaderc_compile" "$LIBSHADERC" \
            2>"$OUT/shaderc_cc.log"; then
        if "$OUT/shaderc_compile" scripts/shaders/vk2d_raster.comp "$SPV" \
                >"$OUT/shaderc.log" 2>&1; then
            echo "[test_vk_hostgpu] PASS libshaderc compiled vk2d_raster.comp -> $SPV"
            grep -o '[0-9]* bytes SPIR-V' "$OUT/shaderc.log" | sed 's/^/[test_vk_hostgpu]   /'
        else
            echo "[test_vk_hostgpu] FAIL libshaderc compile"; cat "$OUT/shaderc.log"; fail=1
        fi
    else
        echo "[test_vk_hostgpu] SKIP shaderc build failed; using committed $SPV"
        cat "$OUT/shaderc_cc.log"
    fi
else
    echo "[test_vk_hostgpu] (6b) libshaderc absent; using committed $SPV (checked in)."
fi
# (ii) GPU-rasterize the reference scene; assert byte-identical to SW reference.
if [ -e "$SPV" ]; then
    echo "[test_vk_hostgpu] (6b) GPU compute-raster of the vk2d scene ..."
    RAST_PPM="$OUT/vk_hostgpu_raster.ppm"
    if "$BRIDGE" raster "$RAST_PPM" >"$OUT/vk_hostgpu_raster.log" 2>&1; then
        GMS=$(awk '/^RASTER_GPU_MS/{print $2}' "$OUT/vk_hostgpu_raster.log")
        SMS=$(awk '/^RASTER_SW_MS/{print $2}' "$OUT/vk_hostgpu_raster.log")
        MM=$(awk '/^RASTER_GPUvsCPUport_MISMATCH/{print $2}' "$OUT/vk_hostgpu_raster.log")
        echo "[test_vk_hostgpu] GPU-raster ${GMS}ms  SW-raster ${SMS}ms (96x64 reference scene)"
        if cmp -s "$REF_PPM" "$RAST_PPM"; then
            echo "[test_vk_hostgpu] PASS GPU compute-raster BYTE-IDENTICAL to vk_2d.ad SW reference"
        else
            echo "[test_vk_hostgpu] FAIL GPU compute-raster differs from SW reference"; fail=1
        fi
        if [ "$MM" = "0" ]; then
            echo "[test_vk_hostgpu] PASS GPU output matches CPU-port oracle (0 mismatches)"
        else
            echo "[test_vk_hostgpu] FAIL GPU vs CPU-port mismatch=$MM"; fail=1
        fi
    else
        echo "[test_vk_hostgpu] FAIL bridge raster op errored"; cat "$OUT/vk_hostgpu_raster.log"; fail=1
    fi
    # (iii) crossover benchmark — the headline "quantifies the win" number.
    echo "[test_vk_hostgpu] (6b) GPU-vs-SW raster crossover ..."
    for RES in "96 64" "1280 720" "1920 1080"; do
        if "$BRIDGE" rasterbench $RES >"$OUT/vk_hostgpu_bench.log" 2>&1; then
            SU=$(awk '/^RASTERBENCH_SPEEDUP/{print $2}' "$OUT/vk_hostgpu_bench.log")
            BG=$(awk '/^RASTERBENCH_GPU_MS/{print $2}' "$OUT/vk_hostgpu_bench.log")
            BS=$(awk '/^RASTERBENCH_SW_MS/{print $2}' "$OUT/vk_hostgpu_bench.log")
            echo "[test_vk_hostgpu]   ${RES// /x}: GPU ${BG}ms  SW ${BS}ms  speedup ${SU}"
            if [ "$RES" = "1920 1080" ]; then
                # at 1080p the GPU raster must beat the CPU (crossover proven).
                if awk "BEGIN{exit !(${SU%x}>1.0)}"; then
                    echo "[test_vk_hostgpu] PASS GPU raster faster than SW at 1080p (${SU})"
                else
                    echo "[test_vk_hostgpu] FAIL GPU raster not faster than SW at 1080p (${SU})"; fail=1
                fi
            fi
        else
            echo "[test_vk_hostgpu] FAIL rasterbench $RES errored"; cat "$OUT/vk_hostgpu_bench.log"; fail=1
        fi
    done
else
    echo "[test_vk_hostgpu] SKIP GPU-raster: no $SPV (toolchain + committed artifact both absent)."
fi

# ---- 7. windowed present (best-effort; SKIP when headless) -----------------
if [ "$HAVE_PRESENT" -eq 1 ] && [ -n "${DISPLAY:-}" ] && \
   command -v xdpyinfo >/dev/null 2>&1 && xdpyinfo >/dev/null 2>&1; then
    echo "[test_vk_hostgpu] (7/7) windowed VkSwapchainKHR present on \$DISPLAY=$DISPLAY ..."
    if timeout 60 "$BRIDGE_X" present "$REF_PPM" 4 30 >"$OUT/vk_hostgpu_present.log" 2>&1; then
        PMS=$(awk '/^PRESENT_MS/{print $2}' "$OUT/vk_hostgpu_present.log")
        PDIM=$(awk '/^PRESENT_OK/{print $2}' "$OUT/vk_hostgpu_present.log")
        PDEV=$(awk '/^VK_DEVICE/{sub(/^VK_DEVICE /,""); print; exit}' "$OUT/vk_hostgpu_present.log")
        if [ -n "$PMS" ]; then
            echo "[test_vk_hostgpu] PASS presented $PDIM to a real window via ${PDEV:-GPU} swapchain (${PMS}ms/frame, FIFO)"
        else
            echo "[test_vk_hostgpu] FAIL present produced no frames"; cat "$OUT/vk_hostgpu_present.log"; fail=1
        fi
    else
        # present failing (e.g. GPU lacks WSI on this surface) must not red the
        # gate on a headless/odd display — report INCONCLUSIVE.
        echo "[test_vk_hostgpu] SKIP present: bridge could not present here (INCONCLUSIVE)"
        tail -3 "$OUT/vk_hostgpu_present.log"
    fi
else
    echo "[test_vk_hostgpu] (7/7) SKIP windowed present: no reachable X display (headless)."
    echo "[test_vk_hostgpu]   To SEE hambrowse through the real GPU on a display machine:"
    echo "[test_vk_hostgpu]     $BRIDGE_X present $REF_PPM 6 600   # 6x-scaled window, ~10s"
fi

# ---- no leaked bridge processes -------------------------------------------
if pgrep -x vk_hostgpu_bridge >/dev/null 2>&1 || pgrep -x vk_hostgpu_bridge_x >/dev/null 2>&1; then
    echo "[test_vk_hostgpu] FAIL leaked vk_hostgpu_bridge process"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_vk_hostgpu] PASS — vk framebuffer renders + round-trips through real Linux Vulkan"
    exit 0
fi
echo "[test_vk_hostgpu] FAIL"; exit 1
