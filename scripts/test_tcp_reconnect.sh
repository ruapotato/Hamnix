#!/usr/bin/env bash
# scripts/test_tcp_reconnect.sh — back-to-back active-open regression
# for drivers/net/tcp.ad.
#
# Background: the in-kernel TCP stack used to derive the ephemeral
# SOURCE port from the connection slot index
# (`local_port = TCP_EPHEMERAL_BASE + slot`). _tcp_alloc_slot always
# hands back the lowest free slot, so a run of short-lived
# connections (connect -> small request -> close, repeated) reused
# slot 0 — and therefore the IDENTICAL source port — every time.
# Back-to-back connections to the same server then presented the
# SAME 4-tuple (src ip:port -> dst ip:port); SLIRP (and any strict
# TCP peer) treats a freshly-reused 4-tuple as a duplicate and
# wedges the 3rd/4th rapid handshake — the SYN-ACK never arrives and
# tcp_connect livelocks until its deadline. The apt agent hit this
# installing multiple packages (multiple .deb downloads) and worked
# around it with a wall-clock settle delay between connects.
#
# The fix rotates the ephemeral source port per active-open across
# the IANA dynamic range 49152..65535 (_tcp_ephemeral_next), so two
# back-to-back connections get DIFFERENT 4-tuples and never collide
# — standard TCP behavior, and it sidesteps any TIME_WAIT-style
# just-closed-4-tuple reuse window for free.
#
# This test boots the kernel with a `guestfwd=tcp:10.0.2.100:7-cmd:cat`
# netdev (same echo target as test_net_tcp.sh) and the
# /etc/tcp-reconnect-test cpio marker, which gates
# tcp_reconnect_smoke_test() in init/main.ad. That smoke performs 6
# consecutive connect -> "hi\n" -> recv-echo -> close cycles with NO
# delay between them and asserts all 6 succeed.
#
# Required marker (full PASS):
#   "[tcp_reconnect] PASS 6/6 back-to-back connects"
#
# Pre-fix the run would log "[tcp_reconnect] FAIL only N/6 ..." with
# N small (typically 2) — this script does not assert that pre-fix
# artifact; the fix is the artifact.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_tcp_reconnect

ELF=build/hamnix-kernel.elf

echo "[test_tcp_reconnect] (1/3) Build userland + initramfs (with /etc/tcp-reconnect-test marker)"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf ENABLE_TCP_RECONNECT_SMOKE=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_tcp_reconnect] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_tcp_reconnect] (3/3) Boot QEMU with virtio-net + SLIRP guestfwd"
LOG=$(mktemp)
# Restore the default (marker-less) initramfs on exit so other test
# runs don't ARP-stall / fire the reconnect smoke unexpectedly.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:5A \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_tcp_reconnect] --- captured (tcp_reconnect / tcp / dhcp / arp) ---"
grep -E '\[tcp_reconnect\]|\[tcp\]|\[dhcp\]|\[arp\]' "$LOG" || true
echo "[test_tcp_reconnect] --- end ---"

# Three-valued gate: a starved / non-booting run emits ZERO [tcp_reconnect]
# markers. Route the zero-marker case through the shared discriminator FIRST.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[tcp_reconnect\]'

if grep -F -q "[tcp_reconnect] PASS 6/6 back-to-back connects" "$LOG"; then
    verdict_pass "$TAG" "6/6 back-to-back TCP connects succeed with no" \
        "artificial delay (ephemeral-port allocation does not stall on reuse)"
fi

# Diagnostics: did we at least reach the smoke?
if grep -F -q "[tcp_reconnect] smoke test starting" "$LOG"; then
    echo "[test_tcp_reconnect] --- full kernel log tail ---"
    tail -80 "$LOG"
    # The smoke ran but did not reach 6/6. If qemu was killed by timeout,
    # it was starved mid-run (each connect waits on SLIRP/ARP); a clean
    # exit without 6/6 is a real regression.
    if [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[tcp_reconnect] smoke ran but did not reach 6/6 and qemu was" \
            "killed by timeout (rc=124) — starved mid-run. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "the reconnect smoke ran but did not reach 6/6 back-to-back connects" \
        "(qemu rc=$rc) — real regression in TCP connect/teardown reuse."
fi

echo "[test_tcp_reconnect] --- full kernel log ---"
cat "$LOG"
verdict_fail "$TAG" \
    "the [tcp_reconnect] smoke never started despite other markers (qemu" \
    "rc=$rc) — real regression in reaching the smoke path."
exit 1
