#!/usr/bin/env bash
# scripts/test_glib_selfwake.sh — a worker thread's write to the GLib main-
# context WAKEUP fd (eventfd, or the self-pipe fallback) must WAKE the main
# thread parked in poll()/ppoll()/epoll_wait() on that fd.
#
# WHY: the Firefox/Wayland deep-track repeatedly hypothesised a "GLib
# cross-thread self-wake gap" — a worker signals the main-context wakeup fd
# but the main thread never wakes → the GLib main loop never advances (Firefox
# never issues get_xdg_surface). foot + Qt already MAP windows on the native
# compositor, which argues the primitive works; this gate PROVES it on the
# wire and guards against regression. It is the intra-process complement to
# test_sem_pingpong.sh (a directed FUTEX_WAKE to a parked peer) and
# test_futex_elided_wake.sh (an elided wake -> bounded recheck): here the wake
# travels through the poll/epoll READINESS edge on an eventfd/pipe, not futex.
#
# The fixture (tests/u-binary/src/glib_selfwake) runs 1 signaler + 10 idle
# siblings + main + a watchdog (Firefox-class thread group) and drives 4
# transport x wait-syscall combinations GLib/Gecko use, cross-thread, 120
# rounds each:
#   1. eventfd  + poll(-1)        GLib default main-loop wait
#   2. eventfd  + ppoll(NULL)     glibc g_poll's preferred syscall
#   3. eventfd  + epoll_wait(-1)  Gecko libevent / base::MessagePump
#   4. self-pipe + poll(-1)       GLib's pre-eventfd fallback
# A single lost cross-thread wake stalls a round; the in-guest watchdog prints
# a FAIL verdict after 40 s so a true hang yields a verdict line, not a silent
# qemu timeout.
#
# PASS criteria: "U-GLIBWAKE: PASS".

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[test_glib_selfwake]"
ensure_ubin_or_skip test_glib_selfwake u_glib_selfwake glib_selfwake

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "$TAG (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "$TAG (2/4) Swap /init + embed u_glib_selfwake"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "$TAG (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

echo "$TAG (4/4) Boot QEMU + run u_glib_selfwake"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
    -- "u_glib_selfwake" 90 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "$TAG --- captured output ---"
cat "$LOG"
echo "$TAG --- end output ---"

if grep -F -q "U-GLIBWAKE: PASS" "$LOG"; then
    echo "$TAG PASS (qemu rc=$rc)"
    exit 0
fi
if grep -F -q "U-GLIBWAKE: FAIL" "$LOG"; then
    echo "$TAG FAIL: a cross-thread eventfd/pipe self-wake was never delivered."
    exit 1
fi
echo "$TAG FAIL: no verdict line (qemu rc=$rc); fixture did not complete."
exit 1
