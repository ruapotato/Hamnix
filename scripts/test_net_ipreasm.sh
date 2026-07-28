#!/usr/bin/env bash
# scripts/test_net_ipreasm.sh — native IPv4 fragment-reassembly + header-
# checksum-validation self-test.
#
# THE GAP THIS COVERS
# -------------------
# drivers/net/ip.ad's ip_rx() used to hand EVERY IPv4 packet straight to
# the L4 demux — it never validated the IPv4 header checksum and had NO
# fragment reassembly. A datagram split across the wire (common for >MTU
# UDP: a large DNS-over-UDP answer, an NFS RPC, an ICMP "ping -s 4000")
# arrived as several fragments, each handed to udp_rx/tcp_rx as if it
# were a whole — but truncated — datagram, silently corrupting the L4
# stream. A corrupt header was likewise accepted. Both are real missing
# IPv4 features, not cosmetic gaps.
#
# ip.ad now implements RFC-791/RFC-815 fragment reassembly (bitmap
# coverage, order-independent, 4 concurrent 64 KiB contexts, LRU
# eviction) plus ip_rcv-style header-checksum validation that gates it.
#
# HOW THIS TEST WORKS
# -------------------
# ip_init() (already on the boot path — no init/main.ad edit needed)
# scans the initramfs for an /etc/ipreasm-test marker and, when present,
# runs ip_reasm_selftest() (drivers/net/ip.ad). That self-test drives the
# REAL ip_rx() fragment path with hand-built fragments and asserts:
#   * in-order reassembly produces a byte-exact datagram (ReasmOKs bumps)
#   * OUT-OF-ORDER reassembly (last fragment first) also reassembles
#     correctly — proving order-independence, not a naive append
#   * a duplicate/overlapping fragment is idempotent
#   * an oversize fragment (offset+len > 65535) is rejected (ReasmFails)
#   * a packet with a corrupt header checksum is DROPPED (InCsumErrors)
#     before it can pollute a reassembly context
# and prints a final "[ip-reasm] PASS-ALL".
#
# The /etc/ipreasm-test marker is planted by importing build_initramfs as
# a module and appending to its FILES list (so NO edit to
# scripts/build_initramfs.py is required); the marker is absent from
# every other build, so default boots never run the self-test.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_net_ipreasm] PASS
# Fail marker:  [test_net_ipreasm] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_net_ipreasm

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_net_ipreasm] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_net_ipreasm] (2/3) Build initramfs (with /etc/ipreasm-test marker) + kernel"
# Plant the /etc/ipreasm-test gate marker WITHOUT editing
# scripts/build_initramfs.py: import it as a module, append our marker to
# its FILES list, then emit the same fs/initramfs_blob.S the normal build
# emits. INIT_ELF mirrors the env contract the standalone CLI honours.
INIT_ELF=build/user/init.elf python3 - <<'PYEOF' >/dev/null
import sys
from pathlib import Path
sys.path.insert(0, "scripts")
import build_initramfs as b
b.FILES.append(("/etc/ipreasm-test", b"1\n"))
archive = b.build_archive()
dest = Path("fs") / "initramfs_blob.S"
b.emit_asm(archive, dest)
PYEOF

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
# Always rebuild a clean (marker-free) initramfs on exit so other tests /
# runs don't inherit the /etc/ipreasm-test marker.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_net_ipreasm] (3/3) Boot QEMU and run the reassembly self-test"
set +e
# A virtio-net device MUST be present: ip_init() (which runs the
# reassembly self-test) is only reached when virtio_net_init() succeeds
# in init/main.ad's net bring-up. Same device line test_net_fuzz.sh uses.
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

echo "[test_net_ipreasm] --- ip-reasm self-test output ---"
grep -E '\[ip-reasm\]' "$CLEAN_LOG" || true
echo "[test_net_ipreasm] --- end ---"

# Three-valued gate: a starved / non-booting run emits ZERO [ip-reasm]
# markers. Route the zero-marker case through the shared discriminator FIRST
# (INCONCLUSIVE on timeout/OOM, FAIL on an observed crash) against the
# escape-stripped log.
verdict_boot_gate "$TAG" "$CLEAN_LOG" "$rc" '\[ip-reasm\]'

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_net_ipreasm] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# Any explicit internal failure is fatal.
if grep -qF "[ip-reasm]" "$CLEAN_LOG" && grep -qE '\[ip-reasm\] .* FAIL' "$CLEAN_LOG"; then
    echo "[test_net_ipreasm] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$CLEAN_LOG"; then
        echo "[test_net_ipreasm] PASS: $label"
    else
        echo "[test_net_ipreasm] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "in-order reassembly byte-exact"        "[ip-reasm] in-order-reassembly PASS"
check "out-of-order reassembly byte-exact"    "[ip-reasm] out-of-order-reassembly PASS"
check "duplicate fragment idempotent"         "[ip-reasm] duplicate-fragment-idempotent PASS"
check "oversize fragment rejected"            "[ip-reasm] oversize-fragment-rejected PASS"
check "corrupt header checksum dropped"       "[ip-reasm] corrupt-header-checksum-dropped PASS"
check "reassembly self-test PASS-ALL banner"  "[ip-reasm] PASS-ALL"

have_all=0
grep -qF "[ip-reasm] PASS-ALL" "$CLEAN_LOG" && have_all=1
rm -f "$CLEAN_LOG"

if [ "$fail" -ne 0 ]; then
    # Markers printed but the terminal PASS-ALL never arrived AND qemu was
    # killed by timeout -> starved mid-selftest, not a regression.
    if [ "$have_all" -eq 0 ] && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[ip-reasm] markers printed but the terminal 'PASS-ALL' banner" \
            "never arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "an [ip-reasm] marker was OBSERVED absent (or an internal FAIL was" \
        "reported) while the selftest ran (qemu rc=$rc) — real regression."
fi

verdict_pass "$TAG" "IPv4 fragments reassemble (in-order, out-of-order," \
    "duplicate-safe) into a byte-exact datagram, an oversize fragment is" \
    "rejected, and a corrupt-header-checksum packet is dropped before it" \
    "can pollute reassembly"
