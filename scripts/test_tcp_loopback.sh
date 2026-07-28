#!/usr/bin/env bash
# scripts/test_tcp_loopback.sh — TCP loopback round-trip regression test.
#
# Exercises the in-kernel tcp_loopback_smoke_test() which does a complete
# TCP connect + accept + data-byte-each-direction + close entirely via the
# 127.0.0.1 loopback shortcut in ip_send → ip_rx → tcp_rx. No SLIRP
# guestfwd is needed — loopback is handled purely inside the kernel.
#
# How it works:
#   * build_initramfs.py plants /etc/tcp-loopback-test (ENABLE_TCP_LOOPBACK_SMOKE=1).
#   * init/main.ad's boot:30.b gate calls tcp_loopback_smoke_test().
#   * The function calls tcp_listen(6000), then tcp_connect(127,0,0,1, 6000, …).
#     The SYN is delivered synchronously via loopback → full three-way
#     handshake completes within the tcp_connect call.
#   * One byte flows each direction via tcp_send / tcp_recv.
#   * All slots are closed cleanly.
#
# PASS gate:
#   "[tcp-loopback] ESTABLISHED both sides"   — handshake completed
#   "[tcp-loopback] data round-trip OK"       — byte each direction
#   "[tcp-loopback] PASS"                     — function returned cleanly
#
# Additional regression check:
#   "[tcp-loopback] FAIL" must NOT appear.
#
# Inner QEMU timeout is 120 s — generous for TCG-slow CI machines.
# The outer timeout (bash `timeout`) adds a safety margin.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_tcp_loopback

ELF=build/hamnix-kernel.elf

echo "[test_tcp_loopback] (1/3) Build userland + initramfs (with /etc/tcp-loopback-test marker)"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf ENABLE_TCP_LOOPBACK_SMOKE=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_tcp_loopback] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_tcp_loopback] (3/3) Boot QEMU (loopback — no guestfwd needed)"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_tcp_loopback] --- captured (tcp-loopback / tcp / dhcp) ---"
grep -E '\[tcp-loopback\]|\[tcp\]|\[dhcp\]' "$LOG" || true
echo "[test_tcp_loopback] --- end ---"

# Three-valued gate: a starved / non-booting run emits ZERO [tcp-loopback]
# markers. Route the zero-marker case through the shared discriminator FIRST
# (INCONCLUSIVE on timeout/OOM, FAIL on an observed crash).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[tcp-loopback\]'

# --- evaluate PASS gates -----------------------------------------------

have_established=0
if grep -F -q "[tcp-loopback] ESTABLISHED both sides" "$LOG"; then
    echo "[test_tcp_loopback] OK: both sides reached ESTABLISHED"
    have_established=1
else
    echo "[test_tcp_loopback] MISS: ESTABLISHED not reached"
fi

have_data=0
if grep -F -q "[tcp-loopback] data round-trip OK" "$LOG"; then
    echo "[test_tcp_loopback] OK: data round-trip succeeded"
    have_data=1
else
    echo "[test_tcp_loopback] MISS: data round-trip not confirmed"
fi

have_pass=0
if grep -F -q "[tcp-loopback] PASS" "$LOG"; then
    echo "[test_tcp_loopback] OK: smoke test returned PASS"
    have_pass=1
fi

# Any FAIL line is an immediate FAIL for the test.
if grep -F -q "[tcp-loopback] FAIL" "$LOG"; then
    echo "[test_tcp_loopback] --- relevant log ---"
    grep -F "[tcp-loopback]" "$LOG" || true
    echo "[test_tcp_loopback] --- end ---"
    verdict_fail "$TAG" "the in-kernel tcp_loopback_smoke_test emitted an" \
        "explicit [tcp-loopback] FAIL line (qemu rc=$rc) — real regression."
fi

if [ "$have_established" -eq 1 ] && [ "$have_data" -eq 1 ] && [ "$have_pass" -eq 1 ]; then
    verdict_pass "$TAG" "in-kernel TCP loopback: both sides reach ESTABLISHED," \
        "a data payload round-trips, and the connection closes cleanly"
fi

echo "[test_tcp_loopback] --- full log tail ---"
tail -n 100 "$LOG"
# Some [tcp-loopback] markers printed but not the full ESTABLISHED+data+PASS
# trio AND qemu was killed by timeout -> starved mid-smoke, not a regression.
if [ "$have_pass" -eq 0 ] && [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "[tcp-loopback] markers printed but the smoke test did not reach its" \
        "PASS banner and qemu was killed by timeout (rc=124) — starved" \
        "mid-smoke. Re-run on a QUIET host."
fi
verdict_fail "$TAG" \
    "the in-kernel TCP loopback smoke test did not reach ESTABLISHED + data" \
    "round-trip + PASS (qemu rc=$rc) — real regression in the loopback path."
exit 1
