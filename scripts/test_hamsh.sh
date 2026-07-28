#!/usr/bin/env bash
# scripts/test_hamsh.sh - end-to-end test for the M16.35 Hamnix shell.
#
# Boots a kernel whose /init is build/user/hamsh.elf, pipes a short
# sequence of commands (help → hello → exit) into QEMU's serial
# stdio, and greps the captured serial log for evidence that:
#
#   1. the hamsh banner appeared        → main() ran
#   2. the help builtin output appeared → lex + builtin dispatch
#   3. the hello child banner appeared → SYS_SPAWN + ELF load worked
#   4. the kernel halted "no live tasks" → the `exit` builtin unwound
#                                          the read-eval loop cleanly
#                                          (the rewritten shell prints
#                                          no "bye" banner)
#
# Inputs are spaced out with sleeps because the 16550 RX FIFO is only
# 16 bytes and there is no kernel-side software buffer yet (M16.34);
# letting each command drain through SYS_READ before sending the next
# avoids dropped chars. Same trick scripts/test_stdin.sh uses.
#
# VERDICT (three-valued, scripts/_verdict.sh): 0 PASS / 1 FAIL /
# 125 INCONCLUSIVE. The sleep ladder above is a HOST-TIMING contract, so a
# starved runner can miss every marker without user/hamsh.ad being wrong at
# all — that is INCONCLUSIVE, not FAIL. See the discriminator at the foot of
# the file. The manifest runs this through scripts/ci_run_gate.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh] (1/5) Build userland (incl. user/hamsh.ad)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_hamsh] (2/5) Swap /init = $HAMSH_ELF in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_hamsh] (3/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

echo "[test_hamsh] (4/5) Boot QEMU + drive shell via piped stdin"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Give the kernel ~3 s to finish all the smoke tests before the shell
# starts SYS_READ. Then send each command with a pause so the previous
# child has finished and the prompt is back.
(
    sleep 3
    printf 'help\n'
    sleep 1
    printf 'hello\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 15s qemu-system-x86_64 \
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

echo "[test_hamsh] --- captured output ---"
cat "$LOG"
echo "[test_hamsh] --- end output ---"

# --- three-valued verdict (scripts/_verdict.sh) -----------------------------
# This gate drives the shell with a fixed sleep ladder (3s / 1s / 2s / 1s)
# into a `timeout 15s` QEMU. That is a HOST-TIMING contract, not a property of
# user/hamsh.ad: on a loaded runner the guest simply has not reached the
# prompt when the sleeps elapse, the commands land in a 16-byte 16550 RX FIFO
# nobody is draining, and every needle below goes MISSing at once. It went red
# exactly that way under host load ~5-15 on 2026-07-28, alongside
# test_hamsh_heartbeat — the known `_hamsh_drive` starvation class, not a code
# fault.
#
# Reporting that as FAIL is a false red, and this gate was invoked DIRECTLY
# from the manifest (no ci_run_gate.sh wrapper), so the false red took a whole
# shard with it. Starvation is now INCONCLUSIVE and the manifest routes it
# through the wrapper, where 125 becomes a ::warning::.
#
# THE DISCRIMINATOR is qemu's own exit status, and it is precise:
#   rc == 124  timeout(1) killed a STILL-RUNNING QEMU. The command sequence
#              never completed, so a missing marker is unobserved, not
#              violated -> INCONCLUSIVE.
#   rc != 124  QEMU exited on its OWN — i.e. the `exit` builtin unwound the
#              shell and the kernel halted, the whole sequence ran. A missing
#              marker here is an OBSERVED violation -> FAIL, still red.
# A run that produced ALL its markers passes regardless of rc, so this can
# never launder a genuine regression.
. "$(dirname "$0")/_verdict.sh"
TAG=test_hamsh

# Nothing at all on the serial line => the guest never booted. verdict_boot_gate
# separates an observed crash (FAIL) from a starved/timed-out boot
# (INCONCLUSIVE) for us.
verdict_boot_gate "$TAG" "$LOG" "$rc" 'Hamnix kernel|\[hamsh\]|no live tasks'

fail=0
missing=0
missing_names=""
for needle in \
    "[hamsh] M16.35 shell ready" \
    "hamsh — the Hamnix shell." \
    "[/hello] hello from a second ELF"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_hamsh] OK: '$needle'"
    else
        echo "[test_hamsh] MISS: '$needle'"
        fail=1
        missing=$((missing + 1))
        missing_names="$missing_names${missing_names:+; }$needle"
    fi
done

# `exit` unwinds the read-eval loop cleanly: the shell (pid 1) exits,
# so the kernel halts with "no live tasks" — the new shell prints no
# "bye" banner (the old one did). This proves `exit` returned.
if grep -F -q "no live tasks" "$LOG"; then
    echo "[test_hamsh] OK: 'exit' unwound the shell cleanly"
else
    echo "[test_hamsh] MISS: shell did not exit cleanly"
    fail=1
    missing=$((missing + 1))
    missing_names="$missing_names${missing_names:+; }no live tasks"
fi

if [ "$fail" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "$missing marker(s) missing — [$missing_names] — but timeout(1)" \
            "killed a STILL-RUNNING qemu (rc=124), so the help/hello/exit" \
            "sequence never finished and those markers were never OBSERVED to" \
            "be absent, only unobserved. This is the _hamsh_drive host-timing" \
            "class (the drive script is a fixed sleep ladder into a 15s" \
            "window). Re-run on a QUIET host: check /proc/loadavg and that no" \
            "rival qemu is running."
    fi
    verdict_fail "$TAG" \
        "$missing marker(s) missing — [$missing_names] — and qemu exited on" \
        "its OWN (rc=$rc), i.e. the drive sequence ran to completion. An" \
        "OBSERVED violation."
fi

verdict_pass "$TAG" "banner, help, spawned /hello and a clean 'exit' unwind" \
    "all observed (qemu rc=$rc)"
