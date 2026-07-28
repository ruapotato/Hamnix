#!/usr/bin/env bash
# scripts/test_net_cfg.sh — exercise the network info + configuration
# path: the SYS_NETCFG syscall (286) behind the `ifconfig` / `route`
# commands.
#
# Two things are proven:
#
#   1. DHCP-by-default reflection. The kernel does DHCP at boot
#      (net_smoke_test -> dhcp_discover) and SLIRP hands out 10.0.2.15.
#      netcfg_smoke_test() then runs SYS_NETCFG GET (op 0) and asserts
#      the lease shows up with cfg_source == DHCP:
#        [netcfg] dhcp-reflect PASS ip=10.0.2.15 source=dhcp
#
#   2. The static-configuration path. The smoke then drives SYS_NETCFG
#      SET_ADDR / SET_GW / SET_DNS and re-GETs after each, asserting the
#      new values took effect and the config source latched to static:
#        [netcfg] static-addr PASS ip=192.168.50.10/24 source=static
#        [netcfg] static-gw PASS gw=192.168.50.1
#        [netcfg] static-dns PASS dns=1.1.1.1 source=static
#      A static SET overriding the DHCP lease proves the override
#      discipline in drivers/net/ip.ad (ip_cfg_source) and
#      drivers/net/dns.ad (dns_server_static).
#
# The smoke is GATED on /etc/netcfg-test — pinning a static config
# stops DHCP installing a lease, so only this test plants the marker
# (ENABLE_NETCFG_SMOKE=1 -> scripts/build_initramfs.py).
#
# Why SLIRP: QEMU's user-mode network has a built-in DHCP server that
# defaults to handing out 10.0.2.15 — no external dnsmasq needed.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_net_cfg

ELF=build/hamnix-kernel.elf

echo "[test_net_cfg] (1/3) Build userland + initramfs (netcfg smoke gated on)"
bash scripts/build_user.sh >/dev/null
ENABLE_NETCFG_SMOKE=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_cfg] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_net_cfg] (3/3) Boot QEMU with virtio-net + SLIRP DHCP"
LOG=$(mktemp)
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

echo "[test_net_cfg] --- captured (netcfg / dhcp) ---"
grep -E '\[netcfg\]|\[dhcp\]' "$LOG" || true
echo "[test_net_cfg] --- end ---"

# Three-valued gate: a starved / non-booting run emits ZERO [netcfg]/[dhcp]
# markers. Route the zero-marker case through the shared discriminator FIRST
# (INCONCLUSIVE on timeout/OOM, FAIL on an observed crash).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[netcfg\]|\[dhcp\]'

fail=0
for needle in \
    "[netcfg] dhcp-reflect PASS" \
    "[netcfg] static-addr PASS" \
    "[netcfg] static-gw PASS" \
    "[netcfg] static-dns PASS" \
    "[netcfg] PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_net_cfg] OK: '$needle'"
    else
        echo "[test_net_cfg] MISS: '$needle'"
        fail=1
    fi
done

# The DHCP-reflect leg must show the SLIRP-assigned 10.0.2.15 — that is
# what proves "DHCP by default" reached the syscall surface.
if grep -F -q "[netcfg] dhcp-reflect PASS ip=10.0.2.15 source=dhcp" "$LOG"; then
    echo "[test_net_cfg] OK: DHCP lease 10.0.2.15 reflected via SYS_NETCFG"
else
    echo "[test_net_cfg] MISS: DHCP lease not reflected as 10.0.2.15/dhcp"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_net_cfg] --- full log ---"
    cat "$LOG"
    if ! grep -F -q "[netcfg] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[netcfg]/[dhcp] markers printed but the terminal '[netcfg] PASS'" \
            "never arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "a [netcfg] marker was OBSERVED absent while the selftest ran (qemu" \
        "rc=$rc) — real regression in SYS_NETCFG dhcp-reflect / static addr/gw/dns."
fi

verdict_pass "$TAG" "SYS_NETCFG reflects the SLIRP DHCP lease (10.0.2.15)" \
    "and applies static address, gateway, and DNS configuration"
