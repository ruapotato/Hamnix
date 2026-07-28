#!/usr/bin/env bash
# scripts/test_smp2_foreground_external.sh — the -smp 2 foreground-external wedge gate.
#
# THE BUG THIS GATE GUARDS
#
# At -smp 2, hamsh wedged after running ANY foreground external command: a
# single `/bin/echo ONE` on its own line ran and printed ONE, but the NEXT
# line (`/bin/echo TWO`) never ran — no prompt, no output, the shell was
# dead. At -smp 1 both lines always ran. Builtins never triggered it (they
# spawn no child). The trigger was: hamsh spawns a foreground external child,
# polls it via sys_waitpid_jc + sys_yield, and after the child exits the shell
# never resumes. Root cause: kernel/sched/core.ad — see the fix commit.
#
# THE ASSERTION
#
# Boot hamsh-as-/init at -smp 2 (the SOLE interactive shell, so serial input
# routing is unambiguous — same rig as test_pipe.sh), then send TWO foreground
# externals back to back. BOTH `/bin/echo` outputs must appear. The second is
# the load-bearing one: with the bug, TWO never prints because the shell is
# wedged after the first external exits. A run that never reaches the sync
# handshake / first output is INCONCLUSIVE (host too slow), never a false red.
#
# REVERT-PROOF: with the scheduler fix reverted this gate FAILs (ONE prints,
# TWO never does). That is the proof it actually exercises the wedge.

. "$(dirname "$0")/_verdict.sh"
. "$(dirname "$0")/_hamsh_log.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# Higher-half kernel boot shim (installs the -kernel<elf64> -> GRUB-ISO wrapper
# and injects -accel kvm when /dev/kvm is usable).
. "$PROJ_ROOT/scripts/_kernel_iso.sh"

TAG="test_smp2_foreground_external"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
SMP="${HAMNIX_TEST_SMP:-2}"          # the whole point of this gate
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[$TAG] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user.sh failed"
bash scripts/build_modules.sh >/dev/null 2>&1 || true

echo "[$TAG] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs.py failed"

echo "[$TAG] (3/4) Rebuild kernel image"
LOG=$(mktemp)
restore_init() {
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap restore_init EXIT

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null 2>&1 || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[$TAG] (4/4) Boot -smp $SMP and drive hamsh"
FIFO=$(mktemp -u --tmpdir hamnix-smp2fg-in.XXXXXX)
mkfifo "$FIFO"
QEMU_PID=""
restore_init() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    [ -n "${QEMU_PID:-}" ] && wait "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    rm -f "$FIFO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap restore_init EXIT

outline_eq() { hamsh_out_eq "$LOG" "$1"; }

# The binshim on PATH rewrites `-kernel <elf64>` into a GRUB `-cdrom` boot and
# injects -accel kvm when available.
qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp "$SMP" -m "${HAMNIX_VM_MEM:-2G}" \
    -nographic -no-reboot -monitor none \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
exec 3> "$FIFO"

alive() { kill -0 "$QEMU_PID" 2>/dev/null; }

# Boot readiness: hamsh's ready marker.
for i in $(seq 1 "$BOOT_WAIT"); do
    grep -a -F -q "M16.35 shell ready" "$LOG" 2>/dev/null && break
    alive || verdict_inconclusive "$TAG" "qemu exited before shell ready"
    sleep 1
done
grep -a -F -q "M16.35 shell ready" "$LOG" 2>/dev/null \
    || verdict_inconclusive "$TAG" "shell never reached ready in ${BOOT_WAIT}s"

# Sync: re-send an idempotent probe until the readline provably consumes stdin
# (the freshly-booted shell drops its first serial line).
synced=0
waited=0
while [ "$waited" -lt "$CMD_WAIT" ]; do
    alive || verdict_inconclusive "$TAG" "qemu exited during sync"
    printf 'echo FEEDER_SYNC\n' >&3 2>/dev/null || verdict_inconclusive "$TAG" "fifo write failed"
    for _ in $(seq 1 5); do
        grep -a -F -q "FEEDER_SYNC" "$LOG" 2>/dev/null && { synced=1; break; }
        alive || verdict_inconclusive "$TAG" "qemu exited during sync"
        sleep 1; waited=$((waited + 1))
        [ "$waited" -ge "$CMD_WAIT" ] && break
    done
    [ "$synced" -eq 1 ] && break
done
[ "$synced" -eq 1 ] || verdict_inconclusive "$TAG" "readline never synced in ${CMD_WAIT}s"
sleep 1

# send_await <cmd> <exact-output-line> <secs>: send ONCE, wait for the exact
# whole-line output. (Sent once — under TCG the editor echoes one char at a
# time; a resend would splice into the still-typing line.)
send_await() {
    local cmd="$1" want="$2" secs="$3" i
    alive || return 1
    printf '%s\n' "$cmd" >&3 2>/dev/null || return 1
    for i in $(seq 1 "$secs"); do
        outline_eq "$want" && { sleep 1; return 0; }
        alive || return 1
        sleep 1
    done
    return 1
}

# ── The two foreground externals, back to back ──────────────────────────────
FIRST_OK=0; SECOND_OK=0
send_await '/bin/echo SMPFG_ONE' 'SMPFG_ONE' "$CMD_WAIT" && FIRST_OK=1
# The load-bearing line: with the wedge, the shell is dead here and TWO never
# prints. It must run AFTER the first external has already exited.
if [ "$FIRST_OK" -eq 1 ]; then
    send_await '/bin/echo SMPFG_TWO' 'SMPFG_TWO' "$CMD_WAIT" && SECOND_OK=1
fi

hamsh_send() { printf '%s\n' "$1" >&3 2>/dev/null || true; }
hamsh_send 'exit'

echo "[$TAG] FIRST_OK=$FIRST_OK SECOND_OK=$SECOND_OK"

# The first external not running at all means we could not even reach the
# scenario (boot/route problem) -> inconclusive, not a false red.
[ "$FIRST_OK" -eq 1 ] || verdict_inconclusive "$TAG" \
    "first foreground external never printed (could not reach the wedge scenario)"

if [ "$SECOND_OK" -eq 1 ]; then
    verdict_pass "$TAG" "both foreground externals ran at -smp $SMP (no post-external wedge)"
else
    verdict_fail "$TAG" \
        "WEDGE: first external ran but the shell never resumed to run the second at -smp $SMP"
fi
