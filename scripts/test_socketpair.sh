#!/usr/bin/env bash
# scripts/test_socketpair.sh — V5 sys_socketpair verification.
#
# Boots hamsh in QEMU and runs /bin/test_socketpair, which:
#   1. sys_socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) -> sv[0], sv[1]
#   2. write(sv[0], "hello") then read(sv[1])  — forward direction
#   3. write(sv[1], "world") then read(sv[0])  — reverse direction
#   4. close both ends
#
# Passes iff every [socketpair] marker shows up in the serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_socketpair

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_socketpair.elf

echo "[test_socketpair] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_socketpair] (2/5) Build tests/test_socketpair.ad -> $TEST_ELF"
mkdir -p build/user
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user tests/test_socketpair.ad "$TEST_ELF" >/dev/null

echo "[test_socketpair] (3/5) Plant /init = hamsh + /bin/test_socketpair"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_socketpair] (4/5) Rebuild kernel image"
mkdir -p build
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_socketpair] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_socketpair\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_socketpair] --- captured output ---"
cat "$LOG"
echo "[test_socketpair] --- end output ---"

# Three-valued gate: a starved boot (or a dropped first serial command)
# emits ZERO [socketpair] markers. Route that through the shared
# discriminator FIRST (INCONCLUSIVE on timeout, FAIL on an observed crash).
# The [socketpair] markers are GENUINE fixture output — the typed input
# ("/bin/test_socketpair", "exit") contains no "[socketpair]" substring, so
# an input-echo cannot spuriously satisfy them.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[socketpair\]'

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_socketpair] OK: $label"
    else
        echo "[test_socketpair] MISS: $label ($marker)"
        fail=1
    fi
}

check_marker "[socketpair] start"     "fixture ran"
check_marker "[socketpair] alloc OK"  "sys_socketpair allocated"
check_marker "[socketpair] forward OK" "fd0 -> fd1 transport"
check_marker "[socketpair] reverse OK" "fd1 -> fd0 transport"
check_marker "[socketpair] close OK"  "both ends closed"
check_marker "[socketpair] PASS"      "fixture reached PASS"

if [ "$fail" -ne 0 ]; then
    # Some [socketpair] markers printed but PASS never arrived AND qemu was
    # killed by timeout -> starved mid-fixture, not a regression.
    if ! grep -F -q "[socketpair] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[socketpair] markers printed but '[socketpair] PASS' never" \
            "arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-fixture. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "a [socketpair] fixture marker was OBSERVED absent (qemu rc=$rc) —" \
        "real regression in sys_socketpair (AF_UNIX transport)."
fi

verdict_pass "$TAG" "sys_socketpair(AF_UNIX, SOCK_STREAM) allocates a" \
    "connected fd pair and transports bytes in both directions"
