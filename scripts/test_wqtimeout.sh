#!/usr/bin/env bash
# scripts/test_wqtimeout.sh — native bounded-wait hrtimer-timeout verification.
#
# Proves the fix that moved the native bounded wait (wq_wait_commit_timeout,
# used by devfd / 9p_client / net backstops) OFF its jiffies-poll deadline
# and ONTO a real ns-resolution hrtimer:
#
#   The OLD code returned WQ_TIMEOUT only once `get_jiffies() >= deadline`,
#   i.e. only while the 100 Hz LAPIC tick kept advancing jiffies during the
#   idle hlt. That dependency FAILS in two real regimes — NO_HZ idle (the
#   tick is deliberately STOPPED) and early boot (the tick ISR is not yet
#   armed) — where jiffies is FROZEN and the bounded wait degenerates into
#   an UNBOUNDED one, wedging the backstop.
#
#   The NEW code arms an hrtimer for the deadline. hrtimers expire off the
#   monotonic clocksource (TSC/HPET ns), which never stops, and reprogram
#   the clockevent one-shot to wake even a fully tickless CPU. On fire, the
#   ISR callback force-wakes the exact sleeper with a TIMEOUT marker.
#
# The in-kernel wq_timeout_hrtimer_selftest() (kernel/sched/core.ad, gated on
# the cpio marker /etc/wqtimeout-test) fabricates a STATE_WAIT sleeper, arms
# the PRODUCTION timeout hrtimer for 2 ms, then — with CPU interrupts OFF so
# the periodic tick never runs and get_jiffies() stays FROZEN — busy-waits
# past the deadline on the free-running clocksource and runs the expiry pass.
# It asserts the sleeper was force-woken (STATE_READY) with wait_timedout==1
# AND that jiffies did NOT advance across the probe — a wake the old
# jiffies-poll deadline could NEVER produce with jiffies frozen.
#
# Revert-sensitive: revert the hrtimer arm / the _wq_timeout_hrtimer_cb
# callback and the marker never appears (link error or the sleeper never
# wakes) — the gate goes red.
#
# Pass marker:  [test_wqtimeout] PASS   (kernel prints [wqtimeout] PASS)
# Fail marker:  [test_wqtimeout] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_WQTIMEOUT_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_wqtimeout] (1/3) Build userland + plant /etc/wqtimeout-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_WQTIMEOUT_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_wqtimeout] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_wqtimeout] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_wqtimeout] --- bounded-wait timeout self-test output ---"
grep -a -E "\[wqtimeout\]|\[boot:37.wqtimeout\]" "$LOG" || true
echo "[test_wqtimeout] --- end ---"

fail=0

if grep -a -F -q "[wqtimeout] FAIL" "$LOG"; then
    echo "[test_wqtimeout] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[wqtimeout] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[wqtimeout] PASS" "$LOG"; then
    echo "[test_wqtimeout] MISS: self-test PASS banner (expected '[wqtimeout] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_wqtimeout] --- full log ---"
    cat "$LOG"
    echo "[test_wqtimeout] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_wqtimeout] PASS — native bounded wait times out on the ns clocksource" \
     "with jiffies frozen (hrtimer-backed deadline; qemu rc=$rc)"
