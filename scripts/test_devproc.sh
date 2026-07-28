#!/usr/bin/env bash
# scripts/test_devproc.sh — regression for the Plan 9
# /proc/<pid>/<file> device family.
#
# Same pipeline shape as test_devpid.sh / test_devcons.sh:
#   1. Build all userland + L-track modules.
#   2. Build tests/test_devproc.ad -> build/user/test_devproc.elf
#      (auto-glob in scripts/build_initramfs.py lands it at
#       /bin/test_devproc inside the cpio archive).
#   3. Plant /init = hamsh so the boot lands at a shell prompt.
#   4. Rebuild the kernel image (picks up the new sys/src/9/port/
#      devproc.ad + fs/vfs.ad DEV_PROC chan dispatch).
#   5. Boot QEMU, run `/bin/test_devproc` via hamsh, then ping the
#      shell with `echo POST_PROC_OK` to confirm we didn't take the
#      console down with us.
#
# MIGRATED (test-trustworthiness sweep) off the older scripts/_qemu_drive.sh
# (prompt-gated but fixed post-command delays) onto the load-adaptive
# scripts/_hamsh_drive.sh (boot-ready marker + FEEDER_SYNC handshake +
# send-once/wait-on-effect). The /proc namespace bind and the fixture
# are sent as one `;` statement list so the bind provably lands before
# the fixture opens /proc/1/status. Assertions read the fixture's OWN
# `[test_devproc] …` OUTPUT markers, never the typed input-echo.
#
# PASS criteria match what tests/test_devproc.ad emits:
#   - "[test_devproc] start"
#   - "[test_devproc] status=<pid> <name> <state> <pml4>"
#   - "[test_devproc] cwd=/"  (or any non-empty path)
#   - "[test_devproc] bad_open_ok"
#   - "[test_devproc] PASS"
#   - POST_PROC_OK (hamsh responsive after the fixture exits)

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_devproc
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devproc.elf

echo "[test_devproc] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devproc] (2/5) Build tests/test_devproc.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devproc.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_devproc] (3/5) Plant /init = hamsh + /bin/test_devproc in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devproc] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_devproc] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

# Namespace recipe: since cc9443cc /proc is reached ONLY through the
# `bind '#p' /proc` namespace rewrite (no literal-path strcmp bypass).
# This boot plants hamsh directly as /init (no /etc/rc.boot), so the
# Pgrp starts with an EMPTY mount table — the bind below is the same
# line rc.boot applies. The bind + fixture are sent as one `;` statement
# list so the bind provably lands before the fixture opens /proc.
hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"
hamsh_send_await "bind '#p' /proc ; /bin/test_devproc" '[test_devproc] start' "$CMD_WAIT" || true
for _ in $(seq 1 "$CMD_WAIT"); do
    grep -a -Eq '\[test_devproc\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
    hamsh_alive || break
    sleep 1
done
hamsh_send_await 'echo POST_PROC_OK' 'POST_PROC_OK' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[test_devproc] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_devproc] --- end output ---"

verdict_boot_gate "$TAG" "$LOG" 0 '\[test_devproc\] (start|PASS|FAIL)'

fail=0
if grep -a -F -q "[test_devproc] start" "$LOG"; then
    echo "[test_devproc] OK: fixture ran"
else
    echo "[test_devproc] MISS: fixture banner missing"
    fail=1
fi

# Status line must include at least the pid we asked for. We don't
# pin the exact name/state/pml4 — those vary across kernel rebuilds —
# but a leading "1 " token is the minimum the test asserts.
if grep -a -E -q "\[test_devproc\] status=1 " "$LOG"; then
    echo "[test_devproc] OK: /proc/1/status returned pid-1 row"
else
    echo "[test_devproc] MISS: /proc/1/status row absent / wrong shape"
    fail=1
fi

# CWD is "/" by default for kernel-spawned user tasks. We accept any
# non-empty path that starts with '/' so a future test that changes
# CWD before the fixture runs doesn't have to update this script too.
if grep -a -E -q "\[test_devproc\] cwd=/" "$LOG"; then
    echo "[test_devproc] OK: /proc/1/cwd returned absolute path"
else
    echo "[test_devproc] MISS: /proc/1/cwd missing or empty"
    fail=1
fi

# §13: real Linux-shape /proc/<pid>/stat. The fixture asserts the
# line opens with "1 (" (field 1 = pid, field 2 = "(comm)").
if grep -a -E -q "\[test_devproc\] stat=1 \(" "$LOG"; then
    echo "[test_devproc] OK: /proc/1/stat returned Linux-shape line"
else
    echo "[test_devproc] MISS: /proc/1/stat missing / wrong shape"
    fail=1
fi

# §13: /proc/<pid>/cmdline + /proc/<pid>/maps.
if grep -a -F -q "[test_devproc] cmdline_ok" "$LOG"; then
    echo "[test_devproc] OK: /proc/1/cmdline served"
else
    echo "[test_devproc] MISS: /proc/1/cmdline failed"
    fail=1
fi
if grep -a -F -q "[test_devproc] maps_ok" "$LOG"; then
    echo "[test_devproc] OK: /proc/1/maps served"
else
    echo "[test_devproc] MISS: /proc/1/maps failed"
    fail=1
fi

if grep -a -F -q "[test_devproc] bad_open_ok" "$LOG"; then
    echo "[test_devproc] OK: open(/proc/999/status) rejected"
else
    echo "[test_devproc] MISS: /proc/999/status was NOT rejected"
    fail=1
fi

if grep -a -F -q "[test_devproc] PASS" "$LOG"; then
    echo "[test_devproc] OK: fixture reached PASS marker"
else
    echo "[test_devproc] MISS: fixture did not reach PASS"
    fail=1
fi

post_ok=0
if grep -a -F -q "POST_PROC_OK" "$LOG"; then
    echo "[test_devproc] OK: hamsh remains responsive"
    post_ok=1
else
    echo "[test_devproc] NOTE: POST_PROC_OK responsiveness sentinel not observed"
fi

[ "$fail" -eq 0 ] || verdict_fail "$TAG" "a /proc/<pid> device-family assertion was VIOLATED (see MISS: lines)."
if [ "$post_ok" -ne 1 ]; then
    verdict_inconclusive "$TAG" \
        "the /proc round-trip assertions held, but POST_PROC_OK was not seen within ${CMD_WAIT}s — cannot tell a shell wedge from a starved guest. Re-run on a quiet host."
fi
verdict_pass "$TAG" "/proc/<pid>/{status,cwd,stat,cmdline,maps} all served through the namespace bind; hamsh survived."
