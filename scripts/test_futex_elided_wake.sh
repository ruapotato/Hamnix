#!/usr/bin/env bash
# scripts/test_futex_elided_wake.sh — LARGE-thread-group FUTEX_WAIT park must
# be BOUNDED, not infinite.
#
# Hamnix's FUTEX_WAIT selects its wait strategy on thread-group size
# (linux_abi/u_syscalls.ad, FUTEX_BLOCK_THRESH): small groups poll-yield and
# re-read *uaddr constantly; large groups take a blocking park whose contract
# is "re-check *uaddr every FUTEX_PARK_TICKS jiffies, so a lost or ELIDED
# FUTEX_WAKE costs one recheck interval, never the process's life".
#
# That contract was violated: wq_wait_commit_timeout's deadline is only ever
# evaluated by the parked task's own loop, and _pick_next never selects a
# STATE_WAIT task — so the moment any other task was runnable the park became
# INFINITE. glibc/musl/cairo/pango routinely mutate a futex word WITHOUT a
# FUTEX_WAKE (the wake is elided when no waiter is registered), so a heavily
# threaded client (Firefox: 12-42 threads) deadlocked on startup while
# foot/weston (2-4 threads, poll-yield arm) never did.
#
# The fixture (tests/u-binary/src/futex_elided_wake) makes that deterministic:
# 8 sched_yield() spinners keep the box runnable, one thread parks in an
# untimed FUTEX_WAIT, and main mutates the word with NO FUTEX_WAKE. The parker
# must return within 6 s. This test FAILS if the bounded-park watchdog
# (_futex_sweep_expired) is removed.
#
# PASS criteria: "U-FUTEX: PASS".

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[test_futex_elided_wake]"
ensure_ubin_or_skip test_futex_elided_wake u_futex_elided_wake futex_elided_wake

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "$TAG (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "$TAG (2/4) Swap /init + embed u_futex_elided_wake"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "$TAG (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

echo "$TAG (4/4) Boot QEMU + run u_futex_elided_wake"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
    -- "u_futex_elided_wake" 45 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "$TAG --- captured output ---"
cat "$LOG"
echo "$TAG --- end output ---"

if grep -F -q "U-FUTEX: PASS" "$LOG"; then
    echo "$TAG PASS (qemu rc=$rc)"
    exit 0
fi
if grep -F -q "U-FUTEX: FAIL parker still parked" "$LOG"; then
    echo "$TAG FAIL: the bounded FUTEX_WAIT park is INFINITE on a busy box."
    exit 1
fi
echo "$TAG FAIL: no verdict line (qemu rc=$rc); fixture did not complete."
exit 1
