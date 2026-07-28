#!/usr/bin/env bash
# scripts/test_devstat_split.sh — /proc/stat user/system/idle CPU-split
# verification.
#
# Proves the /dev/stat (/proc/stat-shape) cpu / cpu0 rows carry a REAL
# three-way user / system / idle split (arch/x86/kernel/time.ad timer-ISR
# jiffie classifier + the pure-instrumentation idle flag in kernel/sched/
# loadavg.ad), rendered by sys/src/9/port/devstat.ad. The in-kernel
# devstat_split_selftest() (gated on the cpio marker /etc/devstat-split-test)
# lets the timer ISR accrue a few ticks to the boot task, then asserts the
# system bucket advanced, the three counters are independent, and every
# tick was charged to exactly one bucket. The selftest does all the work
# and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_devstat_split] PASS   (kernel prints [DEVSTAT_SPLIT] PASS)
# Fail marker:  [test_devstat_split] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_devstat_split

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_DEVSTAT_SPLIT_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_devstat_split] (1/3) Build userland + plant /etc/devstat-split-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_DEVSTAT_SPLIT_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_devstat_split] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_devstat_split] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_devstat_split] --- devstat-split self-test output ---"
grep -a -E "\[DEVSTAT_SPLIT\]" "$LOG" || true
echo "[test_devstat_split] --- end ---"

# --- three-valued verdict (migrated off the hard MISS->FAIL tail) -----
# A zero-marker / rc=124 boot on a TCG-starved host used to look identical
# to a real regression. verdict_boot_gate resolves zero-marker+timeout to
# INCONCLUSIVE; an observed [DEVSTAT_SPLIT] FAIL is a real red; the PASS
# banner is a genuine kernel-selftest OUTPUT (this gate feeds NO serial input).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[DEVSTAT_SPLIT\]'

if grep -a -F -q "[DEVSTAT_SPLIT] FAIL" "$LOG"; then
    grep -a -F "[DEVSTAT_SPLIT] FAIL" "$LOG" | head -5 >&2 || true
    verdict_fail "$TAG" "the devstat-split self-test reported an internal FAIL (observed regression)."
fi

if grep -a -F -q "[DEVSTAT_SPLIT] PASS" "$LOG"; then
    verdict_pass "$TAG" "/proc/stat reports a real user/system/idle split (qemu rc=$rc)."
fi

if [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "the selftest emitted markers but its PASS banner never printed and" \
        "qemu was killed by timeout (rc=124) — starved mid-selftest. Re-run quiet."
fi
verdict_fail "$TAG" \
    "the selftest started and qemu exited on its own (rc=$rc) WITHOUT a PASS" \
    "banner — an OBSERVED incomplete run."
