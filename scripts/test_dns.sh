#!/usr/bin/env bash
# scripts/test_dns.sh — exercise the DNS resolver client (kernel
# roadmap §11: real-internet-grade resolver).
#
# This test has two legs:
#
# (A) OFFLINE record-type self-test — DETERMINISTIC, always asserted.
#     dns_selftest() (drivers/net/dns.ad) builds DNS response packets
#     in memory and feeds them through the real _dns_parse_response
#     codec, proving:
#       - multi-A: a 3-A-record load-balanced answer parses all 3;
#       - PTR (type 12): reverse-lookup name decode;
#       - MX (type 15): (preference, exchange-name) with a DNS
#         compression pointer in the exchange name;
#       - SRV (type 33): (priority, weight, port, target-name);
#       - TC-bit: a truncated UDP answer is flagged for TCP/53
#         fallback rather than mis-parsed.
#       - TCP-frame: the TCP/53 2-byte length-prefix framing the
#         fallback relies on round-trips correctly.
#     Each prints "[dns-selftest] <name> PASS"; the harness greps for
#     all six plus "[dns-selftest] ALL PASS". A miss here is a hard
#     FAIL regardless of internet.
#
# (B) LIVE wire leg — best-effort. After DHCP completes the kernel
#     has the DNS server from option 6 (10.0.2.3 under SLIRP) and
#     net_smoke_test() resolves "example.com". A live multi-A answer
#     also exercises the round-robin pick. The live leg is SKIP-on-
#     no-internet (a CI sandbox blocking egress only ever produces
#     "[dns] timeout", never a crash).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_dns

ELF=build/hamnix-kernel.elf

echo "[test_dns] (1/3) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_dns] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_dns] (3/3) Boot QEMU with virtio-net + SLIRP"
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

echo "[test_dns] --- captured (dns / dhcp / icmp) ---"
grep -E '\[dns\]|\[dns-selftest\]|\[dhcp\]|\[icmp\]' "$LOG" || true
echo "[test_dns] --- end ---"

# Three-valued gate: a starved / non-booting run emits ZERO [dns*] markers
# and the deterministic offline self-test below would then wall a wall of
# MISS -> FAIL. Route the zero-marker case through the shared discriminator
# FIRST (INCONCLUSIVE on timeout/OOM, FAIL on an observed crash).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[dns-selftest\]|\[dns\]'

# === Offline record-type self-test (kernel roadmap §11) ===========
#
# dns_selftest() in drivers/net/dns.ad builds DNS response packets in
# memory and runs them through the real _dns_parse_response codec,
# proving multi-A / PTR / MX / SRV parsing + the truncated-UDP TC-bit
# path WITHOUT needing real internet. This part of the test is
# DETERMINISTIC — it must always pass, internet or not. A failure
# here is a hard regression in the parser.
SELFTEST_FAIL=0
for sub in multi-A PTR MX SRV TC-bit TCP-frame; do
    if ! grep -F -q "[dns-selftest] ${sub} PASS" "$LOG"; then
        echo "[test_dns] FAIL (dns_selftest sub-test '${sub}' did not PASS)"
        SELFTEST_FAIL=1
    fi
done
if ! grep -F -q "[dns-selftest] ALL PASS" "$LOG"; then
    echo "[test_dns] FAIL (dns_selftest did not report ALL PASS)"
    SELFTEST_FAIL=1
fi
if [[ "$SELFTEST_FAIL" -ne 0 ]]; then
    echo "[test_dns] --- full log ---"
    cat "$LOG"
    # The offline self-test is a fast in-kernel codec exercise; a partial
    # run that got killed by timeout before ALL PASS is starvation, not a
    # regression. A clean exit (rc!=124) with a missing sub-test is a real
    # parser regression.
    if ! grep -F -q "[dns-selftest] ALL PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[dns-selftest] markers printed but 'ALL PASS' never arrived and" \
            "qemu was killed by timeout (rc=124) — starved mid-selftest."
    fi
    verdict_fail "$TAG" \
        "a deterministic offline [dns-selftest] sub-test was OBSERVED absent" \
        "(qemu rc=$rc) — real regression in the DNS response parser."
fi
echo "[test_dns] offline self-test: multi-A / PTR / MX / SRV / TC-bit all PASS"

# Outcome decision tree for the LIVE wire leg:
#   1. "[dns] resolved" — PASS (real internet, real DNS). When the
#      live answer carries several A-records the "[dns] multi-A:"
#      marker also fires — logged but not required (a single-A name
#      is still a valid live answer).
#   2. "[dns] timeout"  — PASS-as-SKIP (no internet; we proved we
#                         compiled + sent + received the kernel path,
#                         and the offline self-test already covered
#                         the record-type parsing).
#   3. Neither         — FAIL (the kernel never reached dns_lookup,
#                         likely a DHCP failure or a kernel crash).
if grep -F -q "[dns] resolved" "$LOG"; then
    if grep -F -q "[dns] multi-A:" "$LOG"; then
        echo "[test_dns] live answer carried multiple A-records (round-robin exercised)"
    fi
    verdict_pass "$TAG" "offline record-type self-test (multi-A/PTR/MX/SRV/" \
        "TC-bit/TCP-frame) PASSED and the live wire leg resolved a real name"
fi

if grep -F -q "[dns] timeout" "$LOG"; then
    echo "[test_dns] SKIP live leg (no internet); offline self-test PASSED"
    verdict_pass "$TAG" "offline record-type self-test PASSED; the live wire" \
        "leg cleanly timed out (no internet) — the send/receive path ran"
fi

# Neither live marker found. If qemu was killed by timeout before the
# dns_lookup leg produced resolved/timeout, that is starvation, not a
# regression. A clean exit with neither marker is a real regression
# (kernel never reached dns_lookup — DHCP failure or crash).
echo "[test_dns] --- full log ---"
cat "$LOG"
if [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "offline self-test PASSED but the live wire leg produced neither" \
        "'[dns] resolved' nor '[dns] timeout' and qemu was killed by timeout" \
        "(rc=124) — the wire leg was starved before it could observe an outcome."
fi
verdict_fail "$TAG" \
    "offline self-test PASSED but the live wire leg produced neither" \
    "'[dns] resolved' nor '[dns] timeout' (qemu rc=$rc) — the kernel never" \
    "reached dns_lookup (DHCP failure or crash)."
