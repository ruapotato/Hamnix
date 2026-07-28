#!/usr/bin/env bash
# scripts/test_readonly_bind.sh — task #69: kernel-enforced read-only bind.
#
# Builds tests/test_readonly_bind.ad, drops it at /bin/test_readonly_bind in
# the cpio initramfs, boots Hamnix in QEMU with hamsh as /init, and drives
# the fixture through the load-adaptive scripts/_hamsh_drive.sh (boot-ready
# marker + FEEDER_SYNC handshake + send-once). Assertions read the fixture's
# OWN `[readonly_bind] …` OUTPUT markers, never the typed input-echo.
#
# The fixture binds the SAME writable tmpfs source at TWO views — one with
# the read-only flag (MRDONLY), one without — and proves through the native
# syscall seams that:
#   * a read/stat through the read-only view WORKS;
#   * a create / write-open (O_TRUNC) / remove through it is DENIED (EROFS)
#     AND leaves the backing store unchanged;
#   * the SAME operations through the NON-read-only view all SUCCEED
#     (the control arm — proves the flag is the cause, not blanket denial).
#
# Three-valued verdict: a starved guest that never reaches the fixture is
# INCONCLUSIVE; an OBSERVED enforcement violation is a real FAIL.
#
# Pass marker: [test_readonly_bind] PASS

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_readonly_bind
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_readonly_bind.elf

echo "[test_readonly_bind] (1/4) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null

echo "[test_readonly_bind] (2/4) Build tests/test_readonly_bind.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_readonly_bind.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_readonly_bind] (3/4) Plant /init = hamsh + /bin/test_readonly_bind in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_readonly_bind] (4/4) Rebuild kernel image + boot"
mkdir -p build
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"
hamsh_send_await '/bin/test_readonly_bind' '[readonly_bind] start' "$CMD_WAIT" || true
for _ in $(seq 1 "$CMD_WAIT"); do
    grep -a -Eq '\[readonly_bind\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
    hamsh_alive || break
    sleep 1
done
hamsh_send 'exit'
sleep 2

echo "[test_readonly_bind] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_readonly_bind] --- end output ---"

verdict_boot_gate "$TAG" "$LOG" 0 '\[readonly_bind\] (start|PASS|FAIL)'

fail=0
check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_readonly_bind] OK: $label"
    else
        echo "[test_readonly_bind] MISS: $label ($marker)"
        fail=1
    fi
}

check "[readonly_bind] start"                     "fixture ran"
check "[readonly_bind] seed ok"                   "tmpfs source seeded"
check "[readonly_bind] bind ro/rw ok"             "read-only + control views bound"
check "[readonly_bind] read-through-ro ok"        "read/stat through read-only view WORKS"
check "[readonly_bind] create denied (EROFS)"     "create through read-only view DENIED"
check "[readonly_bind] create had no effect"      "denied create left backing store unchanged"
check "[readonly_bind] write denied (EROFS)"      "write-open (O_TRUNC) through read-only view DENIED"
check "[readonly_bind] write had no effect"       "denied write left the file un-truncated"
check "[readonly_bind] remove denied (EROFS)"     "remove through read-only view DENIED"
check "[readonly_bind] remove had no effect"      "denied remove left the file in place"
check "[readonly_bind] control write ok (rw view)"     "non-read-only bind still permits create"
check "[readonly_bind] control read-back ok (ro view)" "read-only view reads live data"
check "[readonly_bind] control remove ok (rw view)"    "non-read-only bind still permits remove"
check "[readonly_bind] PASS"                      "fixture reached PASS"

if grep -a -F -q "[readonly_bind] FAIL" "$LOG"; then
    echo "[test_readonly_bind] observed fixture FAIL line(s):"
    grep -a -F "[readonly_bind] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

[ "$fail" -eq 0 ] \
    || verdict_fail "$TAG" "a read-only-bind enforcement assertion was VIOLATED (see MISS:/FAIL lines)."
verdict_pass "$TAG" "kernel-enforced read-only bind verified end-to-end: reads pass, mutations EROFS, control bind writable."
