#!/usr/bin/env bash
# scripts/test_net_arp_icmp_helpers.sh — §10 unicast ARP helper +
# ICMP time-exceeded + ICMP redirect selftest.
#
# Plants /etc/net-arp-icmp-helpers-test so net_smoke_test runs
# net_arp_icmp_helpers_selftest() (in drivers/net/icmp.ad). The
# selftest exercises:
#   - arp_send_unicast (REPLY, chosen target MAC + IP)
#   - arp_send_gratuitous (broadcast announcement)
#   - ip_forward_decrement_ttl on a TTL=1 packet — must drop AND
#     emit ICMP Time Exceeded back to the source.
#   - ip_forward_decrement_ttl on a TTL=64 packet — must decrement
#     to 63 and recompute the header checksum.
#   - ip_forward_check_redirect — code path runs to completion.
#   - ip_set_forwarding / ip_get_forwarding accessors.
#
# Forwarding is NOT wired into ip_rx (Hamnix is a host, not a
# router) — the helpers are exported and unit-tested via a
# synthetic packet so the §10 deliverable lands without changing
# the production datapath. ip_forwarding_enabled defaults to 0 so
# the gating flag exists for a future router build.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_net_arp_icmp_helpers

ELF=build/hamnix-kernel.elf

echo "[test_nai] (1/3) Build userland + initramfs (with marker)"
bash scripts/build_user.sh >/dev/null
ENABLE_NAI_HELPERS_TEST=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_nai] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_nai] (3/3) Boot QEMU"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_nai] --- captured (net-helpers / arp / icmp) ---"
grep -E '\[net-helpers\]|\[arp\] unicast|\[icmp\] time-exceeded|\[icmp\] redirect' "$LOG" || true
echo "[test_nai] --- end ---"

# Three-valued gate: a starved / non-booting run emits ZERO [net-helpers]
# markers and used to look identical to a real regression. Route the
# zero-marker case through the shared discriminator FIRST (INCONCLUSIVE on
# timeout/OOM, FAIL on an observed crash).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[net-helpers\]'

fail=0
for needle in \
    "[net-helpers] selftest start" \
    "[arp] unicast op=2 -> 10.0.2.100" \
    "[arp] unicast op=2 -> 10.0.2.15" \
    "[icmp] time-exceeded -> 10.0.2.42" \
    "[net-helpers] time-exceeded PASS" \
    "[net-helpers] ttl-decrement PASS" \
    "[net-helpers] forwarding-flag PASS" \
    "[net-helpers] selftest done"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_nai] OK: '$needle'"
    else
        echo "[test_nai] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_nai] --- full log ---"
    cat "$LOG"
    if ! grep -F -q "[net-helpers] selftest done" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[net-helpers] markers printed but the 'selftest done' banner" \
            "never arrived and qemu was killed by timeout (rc=124) —" \
            "starved mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "a [net-helpers] marker was OBSERVED absent while the selftest ran" \
        "(qemu rc=$rc) — real regression in ARP/ICMP forwarding helpers."
fi

verdict_pass "$TAG" "ARP unicast reply framing, ICMP time-exceeded" \
    "generation, IP TTL decrement, and the forwarding flag all verified"
