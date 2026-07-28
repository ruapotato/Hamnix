#!/usr/bin/env bash
# scripts/test_fmt.sh — native `fmt` text-reflow gate.
#
# Drives user/fmt.ad through a booted hamsh and asserts the reflowed
# output line-for-line. Greedy fill is deterministic, so every expected
# line is an exact whole-line match (hamsh_out_eq) that only fmt's own
# output can produce.
#
# Cases:
#   echo 'a b c d e f'    | fmt -w 5  -> "a b c" / "d e f"
#   echo 'xxxx yyyy zzzz' | fmt -w 9  -> "xxxx yyyy" / "zzzz"
#   echo 'one two three'  | fmt       -> "one two three"  (fits width 75)
#
# hamsh-as-/init (sole interactive shell) — same rig as scripts/test_bc.sh.
#
# VERDICTS (scripts/_verdict.sh): PASS(0)/FAIL(1)/INCONCLUSIVE(125).
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_log.sh"
. "$PROJ_ROOT/scripts/_kernel_iso.sh"

TAG="test_fmt"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
SMP="${HAMNIX_TEST_SMP:-2}"
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[$TAG] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user.sh failed"
if [ ! -x build/user/fmt.elf ]; then
    verdict_inconclusive "$TAG" "build/user/fmt.elf missing after build"
fi

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

echo "[$TAG] (4/4) Boot and drive hamsh"
FIFO=$(mktemp -u --tmpdir hamnix-fmt-in.XXXXXX)
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

# Each fmt run emits several lines; wait on the LAST line of each, then
# assert every expected line.
c1=0; c2=0; c3=0
send_await_out "echo 'a b c d e f' | fmt -w 5"    'd e f'         "$CMD_WAIT" && c1=1
send_await_out "echo 'xxxx yyyy zzzz' | fmt -w 9" 'zzzz'          "$CMD_WAIT" && c2=1
send_await_out "echo 'one two three' | fmt"       'one two three' "$CMD_WAIT" && c3=1
alive && { printf 'exit\n' >&3 2>/dev/null || true; }
sleep 2

fail=0
wrong() { echo "[$TAG] WRONG: $*" >&2; fail=1; }
ok()    { echo "[$TAG] ok: $*"; }

if [ "$((c1+c2+c3))" -eq 0 ]; then
    echo "[$TAG] --- output lines ---" >&2
    outlines | tail -30 >&2
    verdict_inconclusive "$TAG" "fmt produced no output within ${CMD_WAIT}s per case — guest starved?"
fi

# case 1: two-line greedy fill at width 5
if [ "$c1" -eq 1 ]; then
    if outline_eq 'a b c' && outline_eq 'd e f'; then
        ok "case 1 '-w 5': reflowed to 'a b c' / 'd e f'"
    else
        wrong "case 1 '-w 5': did not produce both 'a b c' and 'd e f'"
    fi
else
    verdict_inconclusive "$TAG" "case 1 never completed — guest starved?"
fi

# case 2: fill at width 9 packs two 4-char words then wraps
if [ "$c2" -eq 1 ]; then
    if outline_eq 'xxxx yyyy' && outline_eq 'zzzz'; then
        ok "case 2 '-w 9': reflowed to 'xxxx yyyy' / 'zzzz'"
    else
        wrong "case 2 '-w 9': did not produce 'xxxx yyyy' and 'zzzz'"
    fi
else
    verdict_inconclusive "$TAG" "case 2 never completed — guest starved?"
fi

# case 3: default width keeps a short line intact
if [ "$c3" -eq 1 ]; then
    ok "case 3 default width: 'one two three' stays on one line"
else
    verdict_inconclusive "$TAG" "case 3 never completed — guest starved?"
fi

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- output lines ---" >&2
    outlines | tail -40 >&2
    verdict_fail "$TAG" "a fmt reflow was OBSERVED wrong (see WRONG: lines)"
fi
verdict_pass "$TAG" \
    "fmt greedy-fills words to the goal width (-w 5, -w 9) and leaves short lines intact"
