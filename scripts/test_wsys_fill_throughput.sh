#!/usr/bin/env bash
# scripts/test_wsys_fill_throughput.sh — SUSTAINED RASTERIZER THROUGHPUT.
#
# WHY THIS GATE EXISTS
# ====================
# On 2026-07-27 the user reported, for the second time across two images,
# that the 2048 game runs at about 3 fps. It passed the whole ~137-gate
# battery, because every existing compositor gate asks "did the right pixels
# end up on screen?" and none asks "how long did that take?". A scene commit
# is SYNCHRONOUS inside the client's write() — devwsys re-rasterizes the
# window and presents before the write returns — so rasterizer time IS the
# client's frame time, and nothing measured it.
#
# Root cause (sys/src/9/port/devwsys.ad): _wsys_cache_fillrect looped over
# the rect calling _wsys_cache_putpixel once per pixel. That is six signed
# comparisons, a 64-bit multiply and a call for EVERY pixel, and `fill` is
# what a scene is mostly made of — one 2048 animation frame paints ~360k
# filled pixels (the 360x470 background, the 334x334 board, 16 tiles). The
# present-path profiler (`perf 1` on /dev/wsys/ctl, added with the fix)
# measured 21.4 ms of a 33.1 ms present inside the rasterizer.
#
# WHAT IS ASSERTED
# ================
# The in-kernel wsys_fill_throughput_selftest() (devwsys.ad, chained into
# the boot:37 scene-DE battery) runs WSYS_FILL_TPUT_FRAMES consecutive
# full-window fills at 2048's real 360x470 geometry and REPORTS ns/frame and
# px/ms — the number a human A/Bs.
#
# The pass/fail assertion is deliberately NOT an absolute px/ms threshold.
# This battery runs under KVM on a fast dev host and under TCG in CI, an
# order of magnitude apart, so any constant would be either toothless on one
# or flaky on the other. What the fix established is a STRUCTURAL invariant
# with a machine-independent signature: the clip rect and cache bounds are
# loop-invariant and are now intersected ONCE, before the loop — therefore a
# fill lying ENTIRELY OUTSIDE the clip rect costs O(1). Under the old
# per-pixel gate it cost O(area): the loop ran over every pixel regardless
# and only the store was skipped.
#
# So the self-test times the same-sized fill twice, in-bounds and
# clipped-out, and requires the clipped-out one to be at least 8x cheaper.
# A pure ratio, one machine, one boot: it cannot drift with host speed, and
# it cannot be satisfied by making everything uniformly slow.
#
# Pass marker:  [test_wsys_fill_throughput] PASS
# Fail marker:  [test_wsys_fill_throughput] FAIL

. "$(dirname "$0")/_build_lock.sh"
# _kernel_iso.sh installs build/binshim/qemu-system-x86_64, which turns a
# `-kernel <elf64>` invocation into a BIOS GRUB `-cdrom <iso>` boot (QEMU's
# built-in -kernel multiboot1 loader rejects 64-bit ELFs).
. "$(dirname "$0")/_kernel_iso.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_wsys_fill_throughput] (1/3) Build userland (default init)"
bash scripts/build_user.sh >/dev/null

echo "[test_wsys_fill_throughput] (2/3) Build kernel with the self-test battery armed"
INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_wsys_fill_throughput] (3/3) Boot QEMU and run the throughput self-test"
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

echo "[test_wsys_fill_throughput] --- self-test output ---"
grep -aE "\[FILL_TPUT\]" "$LOG" || true
echo "[test_wsys_fill_throughput] --- end ---"

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_wsys_fill_throughput] FAIL: qemu exited rc=$rc" >&2
    exit 1
fi

# The self-test must have RUN. Zero markers means the boot never reached
# boot:37 (or the battery is disarmed) — INCONCLUSIVE, not a pass.
if ! grep -aqF "[FILL_TPUT]" "$LOG"; then
    echo "[test_wsys_fill_throughput] FAIL: no [FILL_TPUT] marker — the self-test never ran" >&2
    echo "[test_wsys_fill_throughput]   (boot:37 battery disarmed, or the boot did not get that far)" >&2
    exit 1
fi

if grep -aqF "[FILL_TPUT] FAIL" "$LOG"; then
    echo "[test_wsys_fill_throughput] FAIL: the per-pixel clip gate is back inside the fill loop" >&2
    grep -aF "[FILL_TPUT]" "$LOG" >&2
    exit 1
fi

if ! grep -aqF "[FILL_TPUT] PASS" "$LOG"; then
    echo "[test_wsys_fill_throughput] FAIL: no PASS verdict" >&2
    exit 1
fi

echo "[test_wsys_fill_throughput] PASS"
