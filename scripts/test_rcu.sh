#!/usr/bin/env bash
# scripts/test_rcu.sh — RCU grace-period engine regression test.
#
# Boots Hamnix under QEMU with the /etc/rcu-test marker planted and asserts the
# kernel RCU engine (kernel/rcu/rcu.ad) behaves correctly via the in-kernel
# self-test rcu_selftest() (kernel/rcu/rcu_selftest.ad):
#
#   T1  A call_rcu callback is DEFERRED while a reader holds rcu_read_lock —
#       even across an attempted grace period — and runs once the reader
#       unlocks and a GP elapses.
#   T2  synchronize_rcu advances a full grace period (completed-GP count rises).
#   T3  rcu_barrier drains all outstanding callbacks.
#   T4  The task-list RCU traversal (task_lookup_by_pid) is correct under an
#       add / RCU-deferred-remove stress loop: live pids resolve, removed slots
#       are not published FREE before their grace period, removed pids stop
#       resolving, and after a GP every removed slot is RCU-freed.
#
# The kernel self-test emits explicit "[rcu] PASS:" / "[rcu] FAIL:" lines; this
# script greps for them.
#
# Gating: the self-test is gated behind /etc/rcu-test (planted only when
# ENABLE_RCU_TEST=1) at init/main.ad boot:37.rcu, so normal boots never run it.
# The self-test is pure in-RAM (no disk, no extra device) so it passes on TCG
# and does NOT require /dev/kvm. TCG boots are slow, so the timeout is generous.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_rcu] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_rcu] (2/3) Build kernel with /etc/rcu-test marker"
ENABLE_RCU_TEST=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_rcu] (3/3) Boot QEMU and check RCU self-test"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
timeout 480s qemu-system-x86_64 \
    -kernel "$ELF" \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_rcu] --- captured output ([rcu]-relevant lines) ---"
grep -E "\[rcu\]" "$LOG" || true
echo "[test_rcu] --- end ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_rcu] PASS: $label"
    else
        echo "[test_rcu] FAIL: $label  (expected: '$needle')" >&2
        fail=1
    fi
}

check_marker "self-test ran" "[rcu] self-test start"

# T1: reader defers a callback across a GP, then it fires after unlock.
check_marker "callback deferred while reader in critical section" \
    "[rcu] PASS: callback deferred while reader in critical section"
check_marker "callback ran after rcu_read_unlock + grace period" \
    "[rcu] PASS: callback ran after rcu_read_unlock + grace period"

# T2: synchronize_rcu advances a grace period.
check_marker "synchronize_rcu advanced a grace period" \
    "[rcu] PASS: synchronize_rcu advanced GP"

# T3: rcu_barrier drains.
check_marker "rcu_barrier drained outstanding callback" \
    "[rcu] PASS: rcu_barrier drained outstanding callback"

# T4: task-list RCU traversal under add/remove stress.
check_marker "live pids resolve under RCU reader" \
    "[rcu] PASS: all"
check_marker "removed slots deferred (not FREE pre-GP)" \
    "[rcu] PASS: removed slots deferred (not FREE pre-GP)"
check_marker "slots RCU-freed after grace period" \
    "[rcu] PASS:"
check_marker "interleaved add/remove stress consistent" \
    "[rcu] PASS: interleaved add/remove stress consistent"

# Overall verdict.
check_marker "overall self-test PASS" "[rcu] PASS: RCU self-test complete"

# Hard fail if any FAIL line was emitted by the kernel self-test.
if grep -qE "\[rcu\] FAIL" "$LOG"; then
    echo "[test_rcu] FAIL: kernel emitted a [rcu] FAIL line" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_rcu] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_rcu] PASS — read-side deferral, synchronize_rcu GP advance, rcu_barrier drain, and RCU task-list traversal under add/remove stress all green"
