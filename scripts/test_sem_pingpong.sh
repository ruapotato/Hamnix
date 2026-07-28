#!/usr/bin/env bash
# scripts/test_sem_pingpong.sh — a REAL FUTEX_WAKE must be DELIVERED to a peer
# parked in the LARGE-thread-group blocking arm (task #78, the Firefox-class
# lost-wakeup).
#
# Sibling of test_futex_elided_wake.sh. That gate covers the ELIDED-wake
# contract (word mutated with NO FUTEX_WAKE -> bounded recheck must self-heal).
# THIS gate covers the complementary case: a genuine FUTEX_WAKE (glibc
# sem_post) is issued every round to a peer blocked in sem_wait, and the
# directed wake (wq_wake_slot) must actually re-dispatch that STATE_WAIT peer.
#
# The fixture (tests/u-binary/src/sem_pingpong) runs 8 workers + main + a
# watchdog (9 threads -> peer count >= FUTEX_BLOCK_THRESH=6, so every sem_wait
# takes the blocking park). main drives 400 synchronous rounds; every round is
# 8 genuine directed wakes to parked peers plus 8 return wakes. A single lost
# wake stalls a round; the in-guest watchdog prints a FAIL verdict after 40 s
# so a true hang yields a verdict line, not a silent qemu timeout.
#
# PASS criteria: "U-SEMPP: PASS".

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[test_sem_pingpong]"
ensure_ubin_or_skip test_sem_pingpong u_sem_pingpong sem_pingpong

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "$TAG (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "$TAG (2/4) Swap /init + embed u_sem_pingpong"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "$TAG (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

echo "$TAG (4/4) Boot QEMU + run u_sem_pingpong"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
    -- "u_sem_pingpong" 90 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "$TAG --- captured output ---"
cat "$LOG"
echo "$TAG --- end output ---"

if grep -F -q "U-SEMPP: PASS" "$LOG"; then
    echo "$TAG PASS (qemu rc=$rc)"
    exit 0
fi
if grep -F -q "U-SEMPP: FAIL lost wakeup" "$LOG"; then
    echo "$TAG FAIL: a directed FUTEX_WAKE was never delivered (lost wakeup)."
    exit 1
fi
echo "$TAG FAIL: no verdict line (qemu rc=$rc); fixture did not complete."
exit 1
