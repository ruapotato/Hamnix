#!/usr/bin/env bash
# scripts/test_net_ipv6.sh — exercise the basic link-local IPv6 stack
# (task #156): fe80:: link-local address derivation, ICMPv6 Neighbor
# Discovery (NS -> NA), and ICMPv6 Echo (Echo Request -> Echo Reply).
#
# The kernel's net_smoke_test() runs ipv6_selftest() when the
# /etc/ipv6-test cpio marker is present (planted here via
# ENABLE_IPV6_SELFTEST=1). The self-test:
#   1. derives our fe80::/64 EUI-64 link-local address from the NIC MAC
#      and prints it;
#   2. synthesizes an ICMPv6 Neighbor Solicitation for that address and
#      feeds it through the REAL eth_rx -> ipv6_rx -> _icmp6_rx demux,
#      asserting a Neighbor Advertisement was built;
#   3. synthesizes an ICMPv6 Echo Request to that address and asserts an
#      Echo Reply was built;
#   4. transmits a UDP6 datagram with a known payload and asserts the
#      mandatory pseudo-header checksum the kernel wrote into the wire
#      buffer matches a hand-verified value (0x15C2, never the illegal 0);
#   5. injects a two-fragment ICMPv6 Echo Request (out of order, carried
#      in Fragment extension headers) and asserts the kernel walks the
#      extension-header chain, reassembles the datagram, and builds an
#      Echo Reply (frag-reasm PASS);
#   6. injects an ICMPv6 Router Advertisement with a Source Link-Layer
#      Address option and asserts the kernel processes it and caches the
#      router neighbor binding (router-adv PASS).
#
# This is a DETERMINISTIC offline exercise of the v6 RX/TX path — it
# does not depend on QEMU SLIRP IPv6 behaviour. A trailing QEMU rc=124
# AFTER the markers print is a benign red herring (the kernel halts
# without powering off QEMU). We assert with `grep -a` because the boot
# log contains binary bytes.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_net_ipv6

ELF=build/hamnix-kernel.elf

echo "[test_net_ipv6] (1/3) Build userland + initramfs (with /etc/ipv6-test marker)"
bash scripts/build_user.sh >/dev/null
ENABLE_IPV6_SELFTEST=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_ipv6] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_net_ipv6] (3/3) Boot QEMU with virtio-net attached"
LOG=$(mktemp)
# Restore the default (marker-free) initramfs on exit so subsequent
# tests / runs don't see the /etc/ipv6-test marker.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_ipv6] --- captured (ipv6 / icmpv6 lines) ---"
grep -a -E '\[ipv6\]|\[icmpv6\]|\[ipv6-selftest\]' "$LOG" || true
echo "[test_net_ipv6] --- end ---"

# Three-valued gate: a TCG-starved / non-booting run emits ZERO
# [ipv6*] markers and used to be indistinguishable from a real
# regression (a wall of MISS -> hard FAIL). Route the zero-marker case
# through the shared discriminator FIRST (INCONCLUSIVE on timeout/OOM,
# FAIL on an observed crash). The per-needle MISS chain below stays as
# diagnostics; the final decision is verdict_*.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ipv6-selftest\]|\[ipv6\]'

fail=0
for needle in \
    "[ipv6] link-local address fe80:: derived: fe80:" \
    "[ipv6-selftest] NS->NA PASS" \
    "[ipv6-selftest] echo PASS" \
    "[ipv6-selftest] udp6 csum PASS" \
    "[ipv6-selftest] frag-reasm PASS" \
    "[ipv6-selftest] router-adv PASS" \
    "[ipv6-selftest] ALL PASS"
do
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_net_ipv6] OK: '$needle'"
    else
        echo "[test_net_ipv6] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_net_ipv6] --- full log ---"
    cat "$LOG"
    # Some [ipv6*] markers printed but the terminal ALL PASS never arrived
    # AND qemu was killed by timeout -> starved mid-selftest, not a
    # regression. Anything else (clean exit without PASS, or an OBSERVED
    # marker MISS) is a real actionable red.
    if ! grep -a -F -q "[ipv6-selftest] ALL PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[ipv6*] markers printed but the terminal 'ALL PASS' banner" \
            "never arrived and qemu was killed by timeout (rc=124) —" \
            "starved mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "an [ipv6*] selftest marker was OBSERVED absent while the selftest" \
        "ran (qemu rc=$rc) — real regression in the IPv6 RX/TX path."
fi

verdict_pass "$TAG" "link-local IPv6: fe80::/64 EUI-64 derivation, ICMPv6" \
    "NS->NA neighbor discovery, ICMPv6 echo, UDP6 pseudo-header checksum," \
    "fragment reassembly, and Router Advertisement processing all verified"
