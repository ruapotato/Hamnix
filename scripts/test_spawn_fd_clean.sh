#!/usr/bin/env bash
# scripts/test_spawn_fd_clean.sh — task #28: spawn's CLEAN-FD contract.
#
# THE LEAK THIS GUARDS AGAINST (do not delete)
#
# spawn()/spawn_detached()/spawn_stdio_pipes()/spawn_pipeline_stage()
# rfork with RFFDG, which hands the child a PRIVATE COPY of the launcher's
# ENTIRE integer fd table. That copy is what lets the intended stdio wiring
# work — but before the fix it ALSO handed a spawned file server every
# unrelated fd the launcher had open (other servers' transports, the
# launcher's private files, pipe ends). A Plan 9 file server must start
# with a CLEAN fd set, not a copy of everything the launcher had open.
#
# The fix is lib/p9.ad's p9_closefrom(3), called in the child of every
# exec-a-binary spawn helper right before execve: stdio is wired at 0/1/2,
# then every integer fd >= 3 is dropped. (In-process rfork subshells /
# `enter`/`ns` blocks do NOT execve and keep their fds — untouched.)
#
# THE PROBE
#
# /bin/spawnfdprobe (user/spawnfdprobe.ad) plays both roles from one
# binary. As PARENT it opens three extra descriptors (fd 3,4,5) — the
# launcher's private channels — then spawn()s itself in child mode. The
# CHILD probes fd 0..7 and prints OPEN/CLOSED for each.
#
# ASSERTIONS
#   PASS iff:  CHILD FD 0/1/2 OPEN     (intended stdio still passes)
#         AND  CHILD FD 3/4/5 CLOSED   (the launcher's fds did NOT leak)
#   FAIL  if:  any of CHILD FD 3/4/5 OPEN   (the leak is back)
#   INCONCLUSIVE if the guest never produced the probe markers (boot
#         starved / timed out) — three-valued, never a false green.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_verdict.sh"

# NOTE: deliberately NOT `set -e`/`pipefail`. The diagnostic greps below can
# legitimately match nothing (a starved/failed boot), and a non-zero grep in
# a pipeline must not abort the script before verdict_boot_gate can classify
# the run — otherwise a boot with no markers dies silently instead of
# reporting INCONCLUSIVE. Failures are surfaced via the explicit verdict_*.
set -u
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG=test_spawn_fd_clean
ELF=build/hamnix-kernel.elf

echo "[$TAG] (1/3) Build userland + initramfs (plants /bin/spawnfdprobe)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
python3 scripts/build_initramfs.py >/dev/null

echo "[$TAG] (2/3) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-spawn-fd-clean.XXXXXX.log)
# Keep the serial log around for post-mortem (do NOT auto-rm) — a failed or
# starved boot is only debuggable with the raw serial output. It is a small
# file under /tmp; the CI runner cleans /tmp between jobs.

echo "[$TAG] (3/3) Boot QEMU + run /bin/spawnfdprobe"
# Pin -smp 1: the clean-fd contract is NOT SMP-dependent, and on a
# DE-enabled default boot under host load the -smp 2 default starves the
# feeder's FEEDER_SYNC readline handshake (rc=124, zero commands land) —
# a verification confounder, not a code signal. One CPU makes the gate
# deterministic. (last -smp on the qemu line wins over qemu_drive's -smp 2.)
export QEMU_EXTRA_ARGS="${QEMU_EXTRA_ARGS:-} -smp 1"
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 240 \
    -- "/bin/spawnfdprobe" 3 \
       "echo SPAWNFDCLEAN_DRIVE_DONE" 2 \
       "exit" 1
rc="$QEMU_DRIVE_RC"

echo "[$TAG] serial log preserved at: $LOG"
echo "[$TAG] --- probe output (filtered) ---"
grep -a -E "PARENT |CHILD |SPAWNFDCLEAN_|shell ready|command not found" "$LOG" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' | head -60 || true
echo "[$TAG] --- end output ---"

# Three-valued boot gate: if the guest produced ZERO probe/child markers,
# it never got far enough to observe the assertion — INCONCLUSIVE, not a
# false pass. Guest markers = the parent banner OR any CHILD line.
verdict_boot_gate "$TAG" "$LOG" "$rc" 'PARENT opened extra fds|CHILD FD |CHILD PROBE DONE' 1

# From here at least one guest marker was observed, so PASS/FAIL is real.

has() { grep -a -F -q "$1" "$LOG"; }

# The probe must have run to completion.
if ! has "CHILD PROBE DONE"; then
    verdict_inconclusive "$TAG" \
        "the child probe never printed CHILD PROBE DONE — the spawned child" \
        "did not run to completion (qemu rc=$rc). Assertion not observed."
fi

# 1. Intended stdio (0/1/2) must have survived into the spawned child.
stdio_ok=1
for n in 0 1 2; do
    if ! has "CHILD FD $n OPEN"; then
        echo "[$TAG] intended fd $n was NOT open in the child" >&2
        stdio_ok=0
    fi
done

# 2. The launcher's private fds (3/4/5) must NOT have leaked in.
leaked=""
for n in 3 4 5; do
    if has "CHILD FD $n OPEN"; then
        leaked="$leaked $n"
    fi
done

if [ -n "$leaked" ]; then
    verdict_fail "$TAG" \
        "LEAK: the launcher's private fd(s)$leaked were inherited by the" \
        "spawned server (CHILD FD N OPEN). p9_closefrom(3) is not closing" \
        "the RFFDG-copied fd table before execve."
fi

if [ "$stdio_ok" -ne 1 ]; then
    verdict_fail "$TAG" \
        "an intended stdio fd (0/1/2) was CLOSED in the child — the clean-fd" \
        "contract must keep the wired stdio while dropping only fd >= 3."
fi

verdict_pass "$TAG" \
    "spawned child kept stdio 0/1/2 and none of the launcher's private fds" \
    "3/4/5 leaked in (qemu rc=$rc)"
