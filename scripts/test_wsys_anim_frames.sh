#!/usr/bin/env bash
# scripts/test_wsys_anim_frames.sh — SUSTAINED FRAME DELIVERY regression.
#
# WHY THIS GATE EXISTS
# ====================
# On 2026-07-27 the user reported four separate "it does not move" defects on
# the shipped image: the hamGame snake drew exactly ONE frame, the video player
# showed only its starting frame, and the browser repainted only occasionally.
# All of them passed the whole ~137-gate battery, because every existing gate
# measures correctness AT AN INSTANT and frame 1 was always correct. Nothing
# measured whether frame 2..N ever arrived.
#
# Root cause (sys/src/9/port/devwsys.ad): _wsys_scene_commit_damage diffed only
# the committed scene DISPLAY LIST TEXT against the previously presented one.
# An animating client delivers its pixels OUT OF BAND — via the 'I' named-image
# store or the 'B' v2 backbuffer blit — and re-commits a display list whose text
# never changes ("image frame 0 0 64 64" / "buffer 0 0 <w> <h>"). The diff saw
# an identical list, concluded "nothing changed", and returned 2 = skip the
# present entirely. Frame 1 painted; every frame after it was dropped.
#
# WHAT IS ASSERTED
# ================
# The in-kernel wsys_anim_frames_selftest() (devwsys.ad, chained into the
# boot:37 scene-DE battery) runs 30 CONSECUTIVE frames of the real animating-
# client shape and pins BOTH directions:
#
#   (a) pixels delivered out of band  -> a present EVERY one of the 30 frames.
#       This is the regression proper: on the broken build it presented 1.
#   (b) a genuinely idle window       -> STILL fast-skips all 30.
#       This is the guard against "fixing" (a) by deleting the no-change skip,
#       which would hand back the ~3.5 ms full-window repaint per input event
#       that the skip was introduced to remove.
#
# A gate that only checked (a) could be satisfied by presenting unconditionally;
# a gate that only checked (b) is what let the freeze ship. Both, over 30
# frames, is the actual contract.
#
# Pass marker:  [test_wsys_anim_frames] PASS
# Fail marker:  [test_wsys_anim_frames] FAIL

. "$(dirname "$0")/_build_lock.sh"
# _kernel_iso.sh installs build/binshim/qemu-system-x86_64, which turns a
# `-kernel <elf64>` invocation into a BIOS GRUB `-cdrom <iso>` boot (QEMU's
# built-in -kernel multiboot1 loader rejects 64-bit ELFs / "knows VBE").
. "$(dirname "$0")/_kernel_iso.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_wsys_anim_frames] (1/3) Build userland (default init)"
bash scripts/build_user.sh >/dev/null

echo "[test_wsys_anim_frames] (2/3) Build kernel with the self-test battery armed"
INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_wsys_anim_frames] (3/3) Boot QEMU and run the sustained-frame self-test"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_wsys_anim_frames] --- self-test output ---"
grep -aE "\[ANIM_FRAMES\]" "$LOG" || true
echo "[test_wsys_anim_frames] --- end ---"

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_wsys_anim_frames] FAIL: qemu exited rc=$rc" >&2
    exit 1
fi

# The self-test must have RUN. Zero markers means the boot never reached
# boot:37 (or the battery is disarmed) — that is INCONCLUSIVE, not a pass.
if ! grep -aqF "[ANIM_FRAMES]" "$LOG"; then
    echo "[test_wsys_anim_frames] FAIL: no [ANIM_FRAMES] marker — the self-test never ran" >&2
    echo "[test_wsys_anim_frames]   (boot:37 battery disarmed, or the boot did not get that far)" >&2
    exit 1
fi

if grep -aqF "[ANIM_FRAMES] FAIL" "$LOG"; then
    echo "[test_wsys_anim_frames] FAIL: frames were dropped or the idle fast-skip regressed" >&2
    grep -aF "[ANIM_FRAMES]" "$LOG" >&2
    exit 1
fi

if ! grep -aqF "[ANIM_FRAMES] PASS" "$LOG"; then
    echo "[test_wsys_anim_frames] FAIL: no PASS verdict" >&2
    exit 1
fi

echo "[test_wsys_anim_frames] PASS"
