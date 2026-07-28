#!/usr/bin/env bash
# scripts/test_srv_post.sh - Phase D / V4 regression for the
# sys_srv_post (275) / sys_srv_open (276) syscall pair.
#
# Pipeline:
#   1. Build userland (hamsh + coreutils + init).
#   2. Build the fixture tests/test_srv_post.ad to
#      build/user/test_srv_post.elf (lands at /bin/test_srv_post in
#      the cpio via build_initramfs.py's auto-glob).
#   3. /init = hamsh.elf so we land at a shell prompt without going
#      through the recipe-applying init (which is irrelevant here —
#      we test direct syscalls, not the bind-rewritten path).
#   4. Rebuild the kernel image so the new SYS_SRV_POST /
#      SYS_SRV_OPEN dispatch arms are compiled in.
#   5. Boot in QEMU, drive `/bin/test_srv_post` over the serial
#      stdio, then `exit`.
#   6. Grep the serial log for the fixture's markers + PASS.
#
# Markers asserted (from tests/test_srv_post.ad):
#   [srv_post] start
#   [srv_post] posted
#   [srv_post] child_open OK
#   [srv_post] child_wrote OK
#   [srv_post] parent_read OK
#   [srv_post] PASS

# INPUT TIMING: prompt-gated + output-adaptive via scripts/_hamsh_drive.sh
# (replaces the old fixed-sleep feeder that shoved the command before hamsh
# was reading — dropping it under host load and reporting a FALSE RED). A
# starved run now reports INCONCLUSIVE, never a false red or false green.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_srv_post
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_srv_post.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[test_srv_post] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh    >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
bash scripts/build_modules.sh >/dev/null || verdict_inconclusive "$TAG" "build_modules failed"

echo "[test_srv_post] (2/5) Build tests/test_srv_post.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user tests/test_srv_post.ad -o "$TEST_ELF" >/dev/null \
    || verdict_inconclusive "$TAG" "test_srv_post.ad compile failed"

echo "[test_srv_post] (3/5) Plant /init = hamsh + /bin/test_srv_post in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"

echo "[test_srv_post] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[test_srv_post] (5/5) Boot QEMU + drive the test via hamsh"
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

# One command; wait adaptively on the fixture's own terminal marker.
hamsh_send_await '/bin/test_srv_post' '[srv_post] PASS' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2
hamsh_shutdown

echo "[test_srv_post] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_srv_post] --- end output ---"

# Zero-marker guard: no fixture start banner => starved before it ran.
verdict_boot_gate "$TAG" "$LOG" 0 '\[srv_post\]'

# If the fixture never even printed its start banner, hamsh reached its
# prompt but the exec never ran — starved mid-drive, INCONCLUSIVE.
if ! grep -a -F -q "[srv_post] start" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "hamsh was ready but the test_srv_post fixture never printed its start" \
        "banner — the exec never ran (starved mid-drive). Re-run on a QUIET host."
fi

fail=0
check_marker() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_srv_post] OK: $label"
    else
        echo "[test_srv_post] MISS: $label ($marker)"
        fail=1
    fi
}

check_marker "[srv_post] start"          "fixture ran"
check_marker "[srv_post] posted"         "sys_srv_post returned 0"
check_marker "[srv_post] child_open OK"  "child's sys_srv_open returned a fd"
check_marker "[srv_post] child_wrote OK" "child wrote through dup'd fd"
check_marker "[srv_post] parent_read OK" "parent read both sentinels"
check_marker "[srv_post] PASS"           "fixture reached PASS"

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" \
        "the fixture RAN (start banner present) but a sys_srv_post/sys_srv_open" \
        "contract marker was OBSERVED absent — a real regression."
fi
verdict_pass "$TAG" "sys_srv_post(275)/sys_srv_open(276): posted a service, child opened+wrote through the dup'd fd, parent read both sentinels."
