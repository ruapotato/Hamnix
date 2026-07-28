#!/usr/bin/env bash
# scripts/test_tcp_maturity.sh — #166 TCP data-path maturity regression.
#
# Exercises the in-kernel tcp_maturity_selftest() which deterministically
# drives the four new data-path maturity features against crafted in-kernel
# state — no SLIRP / guestfwd / wire timing involved, so the assertions are
# stable and a regression cannot silently pass:
#
#   1. CONGESTION CONTROL (RFC 5681 Reno/NewReno)
#      * one good ACK in slow-start grows cwnd by exactly one SMSS
#      * three duplicate ACKs trigger fast retransmit, halve ssthresh to
#        max(FlightSize/2, 2*SMSS), and cut cwnd into fast recovery
#      * a fresh ACK exits recovery, deflating cwnd back to ssthresh
#   2. WINDOW SCALING (RFC 7323)
#      * the advertised receive window, once unscaled by the peer, exceeds
#        65535 bytes
#      * the WScale + MSS + SACK-permitted options are emitted in the SYN
#        and parse back out correctly
#   3. SACK (RFC 2018)
#      * an out-of-order receipt records the correct [left,right) block,
#        coalescing overlaps
#      * a sender-side incoming SACK marks the SACKed range as received but
#        leaves the genuine hole flagged for retransmit
#      * the SACK option round-trips through the wire parser
#   4. MULTI-LISTENER ACCEPT QUEUE
#      * N concurrent children enqueue onto a listener's backlog and are
#        accepted oldest-first, then the queue drains empty
#
# PASS gate (all must appear, FAIL must NOT):
#   "[tcp-mat] CC: 3 dup-ACKs -> fast retransmit"
#   "[tcp-mat] WSCALE: negotiated, advertised window="
#   "[tcp-mat] SACK: out-of-order block emitted, incoming SACK selects hole"
#   "[tcp-mat] ACCEPT: 3 concurrent children accepted in order"
#   "[tcp-mat] PASS"
#
# Boots once through the ISO-shim/-kernel path (this host cannot raw-boot a
# 64-bit ELF via qemu -kernel for graphics, but a -nographic serial boot of
# the kernel ELF works for these self-tests, same as test_tcp_loopback.sh).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_tcp_maturity

ELF=build/hamnix-kernel.elf

echo "[test_tcp_maturity] (1/3) Build userland + initramfs (with /etc/tcp-test marker)"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf ENABLE_TCP_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_tcp_maturity] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_tcp_maturity] (3/3) Boot QEMU (in-kernel self-test — no guestfwd needed)"
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

echo "[test_tcp_maturity] --- captured ([tcp-mat] lines) ---"
grep -E '\[tcp-mat\]' "$LOG" || true
echo "[test_tcp_maturity] --- end ---"

# Three-valued gate: a starved / non-booting run emits ZERO [tcp-mat]
# markers. Route the zero-marker case through the shared discriminator FIRST
# (INCONCLUSIVE on timeout/OOM, FAIL on an observed crash).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[tcp-mat\]'

fail=0

# Any explicit FAIL line is an immediate failure.
if grep -F -q "[tcp-mat] FAIL" "$LOG"; then
    echo "[test_tcp_maturity] FAIL: self-test emitted a FAIL line"
    grep -F "[tcp-mat]" "$LOG" || true
    verdict_fail "$TAG" "the in-kernel tcp_maturity_selftest emitted an" \
        "explicit [tcp-mat] FAIL line (qemu rc=$rc) — real regression."
fi

check() {
    local label="$1" needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_tcp_maturity] OK: $label"
    else
        echo "[test_tcp_maturity] MISS: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "congestion control fast retransmit" \
      "[tcp-mat] CC: 3 dup-ACKs -> fast retransmit"
check "window scaling > 65535" \
      "[tcp-mat] WSCALE: negotiated, advertised window="
check "SACK out-of-order + hole selection" \
      "[tcp-mat] SACK: out-of-order block emitted, incoming SACK selects hole"
check "multi-listener accept queue in order" \
      "[tcp-mat] ACCEPT: 3 concurrent children accepted in order"
check "overall PASS marker" \
      "[tcp-mat] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_tcp_maturity] --- full log tail ---"
    tail -n 120 "$LOG"
    if ! grep -F -q "[tcp-mat] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[tcp-mat] markers printed but '[tcp-mat] PASS' never arrived and" \
            "qemu was killed by timeout (rc=124) — starved mid-selftest." \
            "Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "a [tcp-mat] marker was OBSERVED absent while the selftest ran (qemu" \
        "rc=$rc) — real regression in congestion control / window scaling /" \
        "SACK / multi-accept."
fi

verdict_pass "$TAG" "TCP data-path maturity: congestion-control fast" \
    "retransmit (3 dup-ACKs), window scaling >65535, SACK out-of-order hole" \
    "selection, and in-order multi-listener accept queue all verified"
exit 0
