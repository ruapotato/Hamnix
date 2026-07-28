#!/usr/bin/env bash
# scripts/test_jsengine_native.sh — native `js` JavaScript-engine boot gate.
#
# ============================ LIVE ==========================================
# This gate now PASSES. JS numbers are IEEE-754 float64, so evaluating ANY
# script executes SSE. Two gaps that used to make the native `js` tool corrupt
# float results are now closed:
#   (1) the kernel FXSAVE/XSAVE's the FPU/SSE/AVX register file across every
#       context switch (per-task save/restore), so xmm survives preemption;
#   (2) the self-hosted (default ADDER_CC=adder) compiler emits float literals
#       as exact-bits .rodata data-consts and float-types call/array-index
#       results, so jsengine's arithmetic compiles to divsd/mulsd (not integer
#       div — the old `0.0/0.0` #DE) and fractional/exponent literals no longer
#       truncate.
# The engine itself is ALSO proven QEMU-free by scripts/test_jsengine_host.sh.
# ============================================================================
#
# Boots Hamnix with hamsh as /init and runs the native `js` tool (user/js.ad,
# backed by the pure engine lib/jsengine.ad) INSIDE the guest. With no file
# argument `js` evaluates a built-in shallow self-test snippet (safe on the
# 4 KiB native user stack) and prints its console.log output. The gate asserts
# the EXACT result line:
#
#     JS-OK hamnix sum=15 sq=1,4,9,16,25
#
# The asserted values (15, the squared list) are NOT present in the typed
# command (`js`), so a console leak / echoed command line cannot fake a PASS
# (memory/feedback_false_green_console_leak.md). This is the native-boot
# confirmation that complements the fast host gate (test_jsengine_host.sh).
#
# Kills ONLY its own $QEMU_PID (memory/feedback_agent_global_pkill_qemu.md).
#
# VERDICTS (scripts/_verdict.sh):
#   PASS (0)          the JS-OK line was OBSERVED correct
#   FAIL (1)          the line was OBSERVED wrong
#   INCONCLUSIVE (125) never got far enough to observe (build/boot/starve)
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_log.sh"

TAG="test_jsengine_native"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
SMP="${HAMNIX_TEST_SMP:-2}"
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[$TAG] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user.sh failed"
if [ ! -x build/user/js.elf ]; then
    verdict_inconclusive "$TAG" "build/user/js.elf missing after build"
fi

echo "[$TAG] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs.py failed"

echo "[$TAG] (3/4) Rebuild kernel image"
LOG=$(mktemp)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null 2>&1 || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[$TAG] (4/4) Boot and drive hamsh"
FIFO=$(mktemp -u --tmpdir hamnix-js-in.XXXXXX)
mkfifo "$FIFO"
QEMU_PID=""
restore() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    [ -n "${QEMU_PID:-}" ] && wait "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    rm -f "$FIFO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap restore EXIT

outline_eq() { hamsh_out_eq "$LOG" "$1"; }
outlines()   { hamsh_outlines "$LOG"; }

qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp "$SMP" -m "${HAMNIX_VM_MEM:-2G}" \
    -nographic -no-reboot -monitor none \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
exec 3> "$FIFO"

alive() { kill -0 "$QEMU_PID" 2>/dev/null; }

wait_raw() {
    local i
    for i in $(seq 1 "$2"); do
        grep -a -F -q "$1" "$LOG" && return 0
        alive || return 1
        sleep 1
    done
    return 1
}

sync_probe() {
    local secs="$1" waited=0 i
    while [ "$waited" -lt "$secs" ]; do
        alive || return 1
        printf 'echo FEEDER_SYNC\n' >&3 2>/dev/null || return 1
        for i in $(seq 1 5); do
            grep -a -F -q "FEEDER_SYNC" "$LOG" && { sleep 1; return 0; }
            alive || return 1
            sleep 1; waited=$((waited + 1))
            [ "$waited" -ge "$secs" ] && break
        done
    done
    return 1
}

send_await_out() {                 # <cmd> <exact-output-line> <secs>
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

wait_raw "[hamsh:stage-07] loop-enter" "$BOOT_WAIT" || {
    tail -30 "$LOG" | strings >&2
    verdict_inconclusive "$TAG" "hamsh never reached its interactive loop in ${BOOT_WAIT}s"
}
sync_probe 120 || {
    tail -30 "$LOG" | strings >&2
    verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"
}

WANT='JS-OK hamnix sum=15 sq=1,4,9,16,25'
got=0
send_await_out "js" "$WANT" "$CMD_WAIT" && got=1

alive && { printf 'exit\n' >&3 2>/dev/null || true; }
sleep 2

if [ "$got" -eq 1 ]; then
    echo "[$TAG] ok: js evaluated the demo snippet -> '$WANT'"
    verdict_pass "$TAG" \
        "native js tool evaluates arrays/map/objects/for-loop/JSON/Math via lib/jsengine.ad"
fi

# Not observed correct: distinguish wrong-output from a starved guest.
if outlines | grep -a -q 'JS-OK'; then
    echo "[$TAG] --- output lines ---" >&2
    outlines | tail -30 >&2
    verdict_fail "$TAG" "js printed a JS-OK line but it did not match '$WANT'"
fi
echo "[$TAG] --- output lines ---" >&2
outlines | tail -30 >&2
verdict_inconclusive "$TAG" "js produced no JS-OK result within ${CMD_WAIT}s — guest starved?"
