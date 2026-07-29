#!/usr/bin/env bash
# scripts/test_track_allocs.sh — the page allocator's allocation tracker
# (--track-allocs, mm/page_alloc.ad) on the real bare-metal kernel.
#
# WHY THIS GATE EXISTS
# ====================
# Eleven leak-hunting passes ran against the DE stress soak, and FOUR of
# them independently hand-rolled the same instrumentation from scratch —
# a byte per buddy frame recording its allocating call site, a live
# per-site histogram, callsite-attributed free counters, per-frame order
# and faulting VA. Every one of those was reverted before commit, so the
# next pass started from zero again. That instrumentation is what actually
# solved things: it localised the residual soak leak to cow_resolve_pte at
# +9.0 pg/cycle with every other site at exactly 0.00.
#
# The tracker is now a permanent, default-off feature. A permanent feature
# needs a gate, or it rots between leak hunts and the twelfth pass finds
# it broken at exactly the moment it is needed.
#
# WHAT IS ASSERTED (all in-kernel, via track_allocs_selftest() in
# sys/src/9/port/devmeminfo.ad — no shell round trip, so hamsh dropping
# its first serial command cannot flake it):
#
#   * DEFAULT-OFF IS INVISIBLE. With tracking unarmed the /proc/meminfo
#     blob contains no tracker bytes at all, and it returns to EXACTLY its
#     original length after a disarm.
#   * DEFAULT-OFF IS FREE. An allocation made while tracking is off moves
#     no counter. This is the measured half of the zero-cost claim (the
#     other half is scripts/test_native_vs_seed_kobjdiff.sh plus a soak).
#   * THE CTL PATH IS REAL. Arming happens through devmeminfo_write, the
#     same code an `echo 'track on' > /proc/meminfo` reaches, trailing
#     newline and all — and a non-`track` write is still rejected, so
#     /dev/meminfo stays read-only for everything else.
#   * ATTRIBUTION IS EXACT. A tagged alloc_pages(2) puts exactly 4 frames
#     on ITS site's live + cumulative counters and moves no other site's.
#   * THE FREE PATH IS ATTRIBUTED TOO. free_pages returns those 4 frames
#     to the histogram and books 4 frees against the same site — which is
#     what makes a per-site slope computable from two samples.
#   * UNTAGGED IS HONEST. An allocation from an untagged site is booked to
#     site 0 (UNKNOWN), not to whatever ran before it.
#   * THE CHUNKED READ STILL WORKS. /bin/cat reads /proc/meminfo 128 bytes
#     at a time and the blob is re-rendered per chunk; the whole armed
#     blob must still come out. (This is also the shape that makes an
#     O(frames) scan in _build_meminfo fatal — it would run ~20x per cat.
#     Two soak runs were lost to exactly that, which is why every counter
#     the renderer touches is an O(1) tally.)
#
# Pass marker:  [TRKALLOC] PASS
# Fail marker:  [TRKALLOC] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_TRKALLOC_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_track_allocs] (1/3) Build userland + plant /etc/trkalloc-test"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_TRACK_ALLOCS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_track_allocs] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_track_allocs] (3/3) Boot QEMU"
set +e
timeout 240s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_track_allocs] --- tracker self-test output ---"
grep -a -E "\[TRKALLOC\]" "$LOG" || true
echo "[test_track_allocs] --- end ---"

fail=0

if grep -a -F -q "[TRKALLOC] FAIL" "$LOG"; then
    echo "[test_track_allocs] FAIL: self-test reported an internal failure" >&2
    grep -a -F "[TRKALLOC] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[TRKALLOC] PASS" "$LOG"; then
    echo "[test_track_allocs] MISS: no '[TRKALLOC] PASS' banner" >&2
    # ZERO guest markers of any kind means the boot never reached the
    # self-test — INCONCLUSIVE, not a tracker regression. Say which.
    if ! grep -a -q "\[TRKALLOC\]" "$LOG"; then
        echo "[test_track_allocs] (no [TRKALLOC] line at all — the boot" \
             "never reached boot:37.trkalloc; treat as INCONCLUSIVE)" >&2
    fi
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_track_allocs] --- last 60 log lines ---"
    tail -60 "$LOG"
    echo "[test_track_allocs] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_track_allocs] PASS — allocation tracking arms, attributes," \
     "disarms, and costs nothing when off (qemu rc=$rc)"
