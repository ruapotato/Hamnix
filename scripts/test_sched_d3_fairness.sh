#!/usr/bin/env bash
# scripts/test_sched_d3_fairness.sh — the "D3" fork-storm starvation gate.
#
# THE BUG (memory: project_enter_linux_slow_is_d3 / docs/qa_buglist_2026-07-01.md
# "D3"): on -smp 2 a freshly-forked FOREGROUND task (`enter linux <cmd>`, or any
# native spawn) made ZERO progress for 30-60 s whenever it was issued DURING the
# runlevel-5 DE bring-up's fork+exec app-launch storm — it recovered only once
# the storm settled. It is pure scheduler STARVATION, not latency.
#
# ROOT CAUSE (kernel/sched/core.ad): task vruntime is charged ONLY on a 100 Hz
# timer tick. A storm child that fork+exec's, runs for less than one tick, and
# exits accrues ZERO vruntime — it lives and dies pinned at the runqueue
# minimum. New tasks were seeded to sched_min_vruntime() (the RAW current
# minimum), so every fresh storm child re-arrived AT that pinned-low minimum. A
# foreground task that ran even a single tick is ABOVE the minimum, and
# _pick_next() (smallest-vruntime-wins) never selects it while the storm keeps
# injecting min-vruntime churners.
#
# THE FIX: a MONOTONIC vruntime floor (Linux cfs_rq->min_vruntime) + seed a new
# task at floor + a one-slice penalty (place_entity initial=1) so a fresh child
# arrives AT OR BEHIND the running set instead of undercutting an incumbent.
#
# WHAT THIS GATE CHECKS: the in-kernel sched_d3_fairness_selftest (rides the
# /etc/sched-fair marker) runs on the BSP boot task under -smp 2 and asserts:
#   (1) the vruntime floor is monotonic, and
#   (2) a freshly-created task (real create path) is seeded at floor+penalty,
#       NOT the raw runqueue minimum — the exact anti-undercut invariant.
# Reverting either placement site back to sched_min_vruntime() flips (2) to
# FAIL, so this gate is revert-proof.
#
# PASS marker: [test_sched_d3] PASS   FAIL marker: [test_sched_d3] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
SMP="${SMP:-2}"

echo "[test_sched_d3] (1/3) build userland"
bash scripts/build_user.sh >/dev/null

echo "[test_sched_d3] (2/3) build kernel + initramfs with /etc/sched-fair marker"
INIT_ELF=build/user/init.elf ENABLE_SCHED_FAIR=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_sched_d3] (3/3) boot -smp $SMP and run the fork-storm fairness self-test"
LOG=$(mktemp)
# Restore the plain initramfs on exit; never leave an orphaned qemu.
QPID=""
cleanup() {
    [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
    rm -f "$LOG"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

set +e
timeout 150s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp "$SMP" \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1 &
QPID=$!
wait "$QPID"
rc=$?
QPID=""
set -e

echo "[test_sched_d3] --- self-test output ---"
grep -aE "\[sched_d3\]" "$LOG" || true
echo "[test_sched_d3] --- end ---"

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_sched_d3] FAIL: qemu exited rc=$rc" >&2
    exit 1
fi

fail=0
need() {
    if grep -aqF "$1" "$LOG"; then
        echo "[test_sched_d3] PASS: $2"
    else
        echo "[test_sched_d3] FAIL: missing '$1' ($2)" >&2
        fail=1
    fi
}
need "[sched_d3] PASS: vruntime floor is monotonic" "monotonic vruntime floor"
need "[sched_d3] PASS: fresh task seeded at floor+penalty" "fork placement penalty (anti-undercut)"

if grep -aqF "[sched_d3] FAIL" "$LOG"; then
    echo "[test_sched_d3] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_sched_d3] FAIL"
    exit 1
fi
echo "[test_sched_d3] PASS — fork-storm cannot starve a running task on -smp $SMP"
