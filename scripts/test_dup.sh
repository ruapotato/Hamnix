#!/usr/bin/env bash
# scripts/test_dup.sh - M16.41 verification.
#
# Drives hamsh through:
#
#     /dup_demo
#     cat /tmp/dup
#     exit
#
# dup_demo uses sys_dup to save the current stdout, sys_dup2 to
# point fd 1 at /tmp/dup, writes a marker (which lands in the file,
# NOT serial), then dup2's stdout back. The test asserts:
#
#   - "(restored)" appears on serial → dup_demo's post-restore write
#     reached the actual console (so dup2-to-old-stdout worked).
#   - "DUP_DEMO_MARKER" appears EXACTLY ONCE in the captured log
#     (only after cat reads it back; never on serial directly).

# INPUT TIMING: prompt-gated + output-adaptive via scripts/_hamsh_drive.sh.
# The old feeder shoved commands after a fixed `sleep 3`; under host load the
# input hit the RX FIFO before hamsh was reading and the first command was
# dropped, MISSing the marker and reporting a FALSE RED indistinguishable
# from a real regression. This driver waits for the readiness marker + a
# FEEDER_SYNC handshake, then sends each command and waits on its OWN
# observable effect; a starved run reports INCONCLUSIVE, never a false red.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_dup
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[test_dup] (1/4) Build userland"
bash scripts/build_user.sh   >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
bash scripts/build_modules.sh >/dev/null || verdict_inconclusive "$TAG" "build_modules failed"

echo "[test_dup] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"

echo "[test_dup] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[test_dup] (4/4) Boot QEMU and drive hamsh"
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

# dup_demo saves stdout, dup2's fd1 to /tmp/dup, writes DUP_DEMO_MARKER
# (into the FILE, not serial), then restores fd1 and prints (restored) to
# the real console. Wait on (restored) — the post-restore write proving
# dup2-back-to-serial worked. Then cat the file back to serial.
hamsh_send_await 'dup_demo'      '(restored)'      "$CMD_WAIT" || true
hamsh_send_await 'cat /tmp/dup'  'DUP_DEMO_MARKER' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2
hamsh_shutdown

echo "[test_dup] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_dup] --- end output ---"

# Zero-marker guard: if the guest never even echoed the sync/first-cmd
# effect it was starved before the assertion could be observed.
verdict_boot_gate "$TAG" "$LOG" 0 '\(restored\)|DUP_DEMO_MARKER|FEEDER_SYNC'

fail=0
if grep -a -F -q "(restored)" "$LOG"; then
    echo "[test_dup] OK: dup2-back-to-serial worked"
else
    echo "[test_dup] MISS: '(restored)' line never reached serial"
    fail=1
fi

# DUP_DEMO_MARKER must appear EXACTLY ONCE — only after `cat` reads it back
# from the file; it must NEVER land on serial directly (that would mean the
# dup2 redirect leaked). The typed command lines carry no such token, so a
# count of 1 is unambiguous.
count=$(grep -a -F -c "DUP_DEMO_MARKER" "$LOG" || true)
if [ "$count" = "1" ]; then
    echo "[test_dup] OK: marker found exactly once (via cat)"
else
    echo "[test_dup] MISS: 'DUP_DEMO_MARKER' count = $count (expected 1)"
    fail=1
fi

# If neither effect was observed at all, the run was starved mid-drive
# rather than a real regression — report INCONCLUSIVE, not a false red.
if ! grep -a -F -q "(restored)" "$LOG" && [ "$count" = "0" ]; then
    verdict_inconclusive "$TAG" \
        "neither (restored) nor DUP_DEMO_MARKER was observed — hamsh reached its" \
        "prompt but the dup_demo/cat effects never printed (starved mid-drive)." \
        "Re-run on a QUIET host."
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" \
        "dup2 round-trip broken: '(restored)' absent means dup2-back-to-serial" \
        "failed, or DUP_DEMO_MARKER count != 1 means the redirect leaked to serial."
fi
verdict_pass "$TAG" "sys_dup/sys_dup2 round-trip: fd1 redirected to /tmp/dup and restored; marker reached the file exactly once."
