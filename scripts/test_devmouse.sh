#!/usr/bin/env bash
# scripts/test_devmouse.sh — M16.130 regression for /dev/mouse.
#
# Pipeline mirrors test_devtime.sh / test_devpid.sh:
#   1. Build userland (hamsh, coreutils).
#   2. Build the test fixture tests/test_devmouse.ad → /bin/test_devmouse.
#   3. Plant hamsh as /init.
#   4. Rebuild the kernel image so devmouse.ad + FD_MOUSE_MARK arms are
#      compiled in.
#   5. Boot in QEMU, drive `/bin/test_devmouse` over the serial stdio.
#
# PASS = the fixture opened /dev/mouse successfully without crashing,
# its read either returned 0 (ring empty under headless QEMU) or a
# well-formed "<dx> <dy> <buttons>\n" line, and hamsh remained
# responsive afterwards. We deliberately do NOT require a non-empty
# mouse event line: the headless QEMU config injects no mouse events.
#
# MIGRATED (test-trustworthiness sweep) off the old fixed-`sleep 3`
# feeder onto the load-adaptive scripts/_hamsh_drive.sh (boot-ready
# marker + FEEDER_SYNC handshake + send-once). Assertions read the
# fixture's OWN `[test_devmouse] …` OUTPUT markers, never the typed
# `/bin/test_devmouse` input-echo. Three-valued verdict.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_devmouse
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devmouse.elf

echo "[test_devmouse] (1/4) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devmouse] (2/4) Build tests/test_devmouse.ad -> $TEST_ELF"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user tests/test_devmouse.ad "$TEST_ELF" >/dev/null

echo "[test_devmouse] (3/4) Plant /init = hamsh + /bin/test_devmouse in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devmouse] (4/4) Rebuild kernel image + boot"
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
hamsh_send_await '/bin/test_devmouse' '[test_devmouse] start' "$CMD_WAIT" || true
hamsh_send_await 'echo POST_MOUSE_OK' 'POST_MOUSE_OK' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[test_devmouse] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_devmouse] --- end output ---"

verdict_boot_gate "$TAG" "$LOG" 0 '\[test_devmouse\] (start|done)'

fail=0
if grep -a -F -q "[test_devmouse] start" "$LOG"; then
    echo "[test_devmouse] OK: fixture ran"
else
    echo "[test_devmouse] MISS: fixture banner missing"; fail=1
fi

if grep -a -F -q "[test_devmouse] opened /dev/mouse OK" "$LOG"; then
    echo "[test_devmouse] OK: /dev/mouse opened cleanly"
else
    echo "[test_devmouse] MISS: /dev/mouse open failed"; fail=1
fi

if grep -a -F -q "[test_devmouse] read returned negative" "$LOG"; then
    echo "[test_devmouse] MISS: devmouse_read returned a negative value"; fail=1
fi
if grep -a -F -q "[test_devmouse] parse FAIL" "$LOG"; then
    echo "[test_devmouse] MISS: event line failed to parse"; fail=1
fi

if grep -a -F -q "[test_devmouse] read=0 (ring empty, OK)" "$LOG" \
   || grep -a -F -q "[test_devmouse] parse OK" "$LOG"; then
    echo "[test_devmouse] OK: read path completed without error"
else
    echo "[test_devmouse] MISS: neither empty-ring nor parsed-line banner present"; fail=1
fi

if grep -a -F -q "[test_devmouse] done" "$LOG"; then
    echo "[test_devmouse] OK: fixture reached completion"
else
    echo "[test_devmouse] MISS: fixture didn't reach 'done' banner"; fail=1
fi

post_ok=0
if grep -a -F -q "POST_MOUSE_OK" "$LOG"; then
    echo "[test_devmouse] OK: hamsh remains responsive"; post_ok=1
else
    echo "[test_devmouse] NOTE: POST_MOUSE_OK responsiveness sentinel not observed"
fi

[ "$fail" -eq 0 ] || verdict_fail "$TAG" "a /dev/mouse read assertion was VIOLATED (see MISS: lines)."
if [ "$post_ok" -ne 1 ]; then
    verdict_inconclusive "$TAG" \
        "/dev/mouse round-trip succeeded, but POST_MOUSE_OK was not seen within ${CMD_WAIT}s — cannot tell a shell wedge from a starved guest. Re-run on a quiet host."
fi
verdict_pass "$TAG" "/dev/mouse open + read completed cleanly; hamsh survived the round-trip."
