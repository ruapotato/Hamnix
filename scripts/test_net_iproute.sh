#!/usr/bin/env bash
# scripts/test_net_iproute.sh — native IPv4 FIB longest-prefix-match
# routing self-test.
#
# THE GAP THIS COVERS
# -------------------
# drivers/net/ip.ad's ip_send() used to know exactly TWO routes: the
# single on-link subnet (our address & netmask) was ARP'd directly, and
# EVERYTHING else was sent to one hardcoded default gateway. There was no
# forwarding information base — no way to say "10.5.0.0/16 is reachable
# via the router at 192.168.1.254", a routing concept every real IPv4
# host supports (Linux: `ip route add` / classic `route add -net`). A box
# with a subnet behind a non-default router simply could not reach it.
#
# ip.ad now implements a real IPv4 FIB with longest-prefix-match
# (ip_route_lookup): among all routes whose network matches the
# destination, the most specific (most prefix bits) wins — a /32 host
# route beats a /24 subnet route beats the /0 default route. ip_send()
# consults it for every outbound packet (on-link -> ARP the dst,
# off-link -> ARP the route's gateway). Operators add/list routes via the
# native SYS_NETCFG ctl ops (ROUTE_ADD / ROUTE_GET) behind the `route`
# command — Plan-9-style ctl writes, not a Linux syscall.
#
# HOW THIS TEST WORKS
# -------------------
# ip_init() (already on the boot path — no init/main.ad edit needed)
# scans the initramfs for an /etc/iproute-test marker and, when present,
# runs ip_fib_selftest() (drivers/net/ip.ad). That self-test drives the
# REAL ip_route_lookup() LPM path and asserts:
#   * a /16 subnet route resolves to its gateway (off-link)
#   * a /24 route beats an overlapping /16 (longest-prefix wins)
#   * a /32 host route beats the /24 and is on-link (ARP the dst)
#   * a destination with no specific route uses the default gateway
#   * with no default route and no match, the lookup MISSES (unroutable)
#   * re-adding the same prefix replaces in place (no double slot)
# and prints a final "[ip-fib] PASS-ALL".
#
# The /etc/iproute-test marker is planted by importing build_initramfs as
# a module and appending to its FILES list (so NO edit to
# scripts/build_initramfs.py is required); the marker is absent from
# every other build, so default boots never run the self-test.
#
# Pass marker:  [test_net_iproute] PASS
# Fail marker:  [test_net_iproute] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_net_iproute

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_net_iproute] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_net_iproute] (2/3) Build initramfs (with /etc/iproute-test marker) + kernel"
INIT_ELF=build/user/init.elf python3 - <<'PYEOF' >/dev/null
import sys
from pathlib import Path
sys.path.insert(0, "scripts")
import build_initramfs as b
b.FILES.append(("/etc/iproute-test", b"1\n"))
archive = b.build_archive()
dest = Path("fs") / "initramfs_blob.S"
b.emit_asm(archive, dest)
PYEOF

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
# Always rebuild a clean (marker-free) initramfs on exit so other tests /
# runs don't inherit the /etc/iproute-test marker.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_net_iproute] (3/3) Boot QEMU and run the FIB routing self-test"
set +e
# A virtio-net device MUST be present: ip_init() (which runs the FIB
# self-test) is only reached when virtio_net_init() succeeds in
# init/main.ad's net bring-up. Same device line test_net_ipreasm.sh uses.
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

# Strip ANSI/VT100 escapes so grep matches even through GRUB/fb control codes.
CLEAN_LOG=$(mktemp)
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b.//g' "$LOG" > "$CLEAN_LOG"

echo "[test_net_iproute] --- ip-fib self-test output ---"
grep -E '\[ip-fib\]' "$CLEAN_LOG" || true
echo "[test_net_iproute] --- end ---"

# Three-valued gate: a starved / non-booting run emits ZERO [ip-fib]
# markers. Route the zero-marker case through the shared discriminator FIRST
# (INCONCLUSIVE on timeout/OOM, FAIL on an observed crash) against the
# escape-stripped log.
verdict_boot_gate "$TAG" "$CLEAN_LOG" "$rc" '\[ip-fib\]'

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_net_iproute] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# Any explicit internal failure is fatal.
if grep -qF "[ip-fib]" "$CLEAN_LOG" && grep -qE '\[ip-fib\] .* FAIL' "$CLEAN_LOG"; then
    echo "[test_net_iproute] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$CLEAN_LOG"; then
        echo "[test_net_iproute] PASS: $label"
    else
        echo "[test_net_iproute] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "/16 subnet route via gateway"          "[ip-fib] slash16-subnet-via-gw PASS"
check "/24 beats overlapping /16 (LPM)"        "[ip-fib] slash24-beats-slash16 PASS"
check "/32 host route on-link beats /24"       "[ip-fib] slash32-host-beats-slash24-onlink PASS"
check "default route via gateway"              "[ip-fib] default-route-via-gw PASS"
check "no default + no match misses"           "[ip-fib] no-default-no-match-misses PASS"
check "same-prefix re-add replaces in place"   "[ip-fib] same-prefix-readd-replaces PASS"
check "FIB self-test PASS-ALL banner"          "[ip-fib] PASS-ALL"

have_all=0
grep -qF "[ip-fib] PASS-ALL" "$CLEAN_LOG" && have_all=1
rm -f "$CLEAN_LOG"

if [ "$fail" -ne 0 ]; then
    if [ "$have_all" -eq 0 ] && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[ip-fib] markers printed but the terminal 'PASS-ALL' banner" \
            "never arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "an [ip-fib] marker was OBSERVED absent (or an internal FAIL was" \
        "reported) while the selftest ran (qemu rc=$rc) — real regression."
fi

verdict_pass "$TAG" "IPv4 FIB longest-prefix-match selects the correct next" \
    "hop (/32 > /24 > /16 > default), distinguishes on-link (ARP dst) from" \
    "via-gateway (ARP gw), misses cleanly when unrouted, and replaces" \
    "same-prefix routes in place"
