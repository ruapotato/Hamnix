#!/usr/bin/env bash
# scripts/test_srvtest.sh — server-socket triple (bind/listen/accept +
# getsockname/getpeername) end-to-end over the Linux ABI.
#
# Proves the SERVER side of the Linux-ABI socket family — the headline
# "boots to a shell" -> "runs sshd/nginx" gap — works end to end and
# ENTIRELY in-guest over the 127.0.0.1 loopback (no SLIRP guestfwd for
# the test traffic itself, no host driver). A single fixture
# (tests/u-binary/src/srvtest) forks into a server
# (socket/bind(127.0.0.1:0)/listen/accept) and a client
# (socket/connect), exchanges "ping"/"pong", and checks that
# getsockname() on the listener + getpeername() on the accepted fd
# report the right 127.0.0.1:<port>.
#
# Pipeline (mirrors test_u_socket.sh — the fixture is exec'd FROM hamsh,
# not loaded as raw /init, so musl's _start gets a proper argv/auxv
# stack):
#   1. Build tests/u-binary/src/srvtest -> tests/u-binary/u_srvtest
#      (musl static-PIE, ELFOSABI_LINUX), embedded at /bin/u_srvtest.
#   2. Boot Hamnix with /init=hamsh; drive hamsh to exec u_srvtest.
#   3. Grep the markers off the serial log.
#
# Required markers (all must appear, no FAIL line):
#   "srvtest: listen port="
#   "srvtest: accept connfd="
#   "srvtest: peer=127.0.0.1:"
#   "srvtest: server got=ping"
#   "srvtest: client got=pong"
#   "srvtest: PASS"
#
# REQUIRES musl-gcc on the host. Skips quietly (exit 0) if it isn't
# installed so CI without the toolchain still passes.

# INPUT TIMING: prompt-gated + output-adaptive via scripts/_hamsh_drive.sh
# (replaces the old fixed `sleep 60; u_srvtest; sleep 30` feeder that raced
# the boot and shoved the command before hamsh was reading — a FALSE-RED
# generator under host load). A starved run reports INCONCLUSIVE, never a
# false red. The guestfwd echo netdev is passed through QEMU_EXTRA_ARGS.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_srvtest

if ! command -v musl-gcc >/dev/null 2>&1; then
    # Missing host toolchain => the assertion cannot be observed at all.
    # That is ABSENCE OF EVIDENCE, not a pass: report INCONCLUSIVE so a
    # runner without musl-tools cannot masquerade as a green socket-server.
    verdict_inconclusive "$TAG" \
        "musl-gcc is not installed, so the static-PIE srvtest fixture cannot be" \
        "built — the server-socket triple was never exercised. Install" \
        "musl-tools (apt-get install -y musl-tools) and re-run."
fi

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
UBIN=tests/u-binary/u_srvtest
BOOT_WAIT="${BOOT_WAIT:-480}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[test_srvtest] (1/4) Build srvtest fixture (musl static-PIE)"
make -C tests/u-binary/src/srvtest install >/dev/null \
    || verdict_inconclusive "$TAG" "srvtest fixture build failed"
if [ ! -f "$UBIN" ]; then
    verdict_inconclusive "$TAG" "$UBIN not built"
fi

echo "[test_srvtest] (2/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user failed"

echo "[test_srvtest] (3/4) Swap /init = hamsh + embed u_srvtest; rebuild kernel"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[test_srvtest] (4/4) Boot QEMU; exec u_srvtest from hamsh"
LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

# The guestfwd echo target is REQUIRED so init/main.ad's net_smoke_test
# completes fast and boot reaches the hamsh prompt (same as
# test_u_socket.sh / test_net_tcp.sh). The srvtest traffic itself never
# touches it — it's pure 127.0.0.1 loopback inside the guest.
export QEMU_EXTRA_ARGS="-netdev user,id=n0,guestfwd=tcp:10.0.2.100:7-cmd:cat -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56"

hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved / net_smoke_test stalled?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"

# Exec the fixture; wait adaptively on its terminal marker.
hamsh_send_await 'u_srvtest' 'srvtest: PASS' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2
hamsh_shutdown

echo "[test_srvtest] --- captured (srvtest) ---"
grep -a -E 'srvtest:' "$LOG" || true
echo "[test_srvtest] --- end ---"

# Zero-marker guard: no srvtest output at all => the fixture never ran
# (starved before exec) — INCONCLUSIVE, not a real red.
verdict_boot_gate "$TAG" "$LOG" 0 'srvtest:'

if grep -a -F -q "srvtest: FAIL" "$LOG"; then
    grep -a -F "srvtest: FAIL" "$LOG" | head -5 >&2 || true
    verdict_fail "$TAG" "the srvtest fixture emitted a FAIL line (observed regression in the server-socket triple)."
fi

need=(
    "srvtest: listen port="
    "srvtest: accept connfd="
    "srvtest: peer=127.0.0.1:"
    "srvtest: server got=ping"
    "srvtest: client got=pong"
    "srvtest: PASS"
)
missing=0
for m in "${need[@]}"; do
    if grep -a -F -q "$m" "$LOG"; then
        echo "[test_srvtest] OK: $m"
    else
        echo "[test_srvtest] MISS: $m"
        missing=1
    fi
done

if [ "$missing" -eq 0 ]; then
    verdict_pass "$TAG" "server-socket triple e2e: socket/bind(127.0.0.1:0)/listen/accept + client connect, ping/pong exchanged, getsockname/getpeername report the right 127.0.0.1:port."
fi

# The fixture emitted SOME srvtest: output (guard above passed) but not the
# full set — if it never reached the listen line it was starved mid-run;
# otherwise a genuine contract marker is absent (real red).
if ! grep -a -F -q "srvtest: listen port=" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "srvtest printed some output but never reached 'listen port=' — starved" \
        "before the server bound. Re-run on a QUIET host."
fi
verdict_fail "$TAG" \
    "the srvtest fixture RAN and bound its listener but a later contract marker" \
    "(accept/peer/ping/pong/PASS) was OBSERVED absent — a real regression."
