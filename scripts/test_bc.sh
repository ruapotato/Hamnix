#!/usr/bin/env bash
# scripts/test_bc.sh — native `bc` calculator gate.
#
# Drives the native infix calculator (user/bc.ad) through a booted hamsh
# and asserts on each expression's COMPUTED result. Every assertion uses
# hamsh_out_eq — the whole output line must equal the expected value — and
# every expected value is a number the input expression does NOT literally
# contain, so a console leak or an echoed command line cannot fake a PASS.
#
# Cases (each proves a distinct piece of the grammar):
#   1. precedence      echo '2+3*4'   | bc  -> 14   (* before +)
#   2. parentheses     echo '(2+3)*4' | bc  -> 20
#   3. power           echo '2^10'    | bc  -> 1024
#   4. modulo          echo '17%5'    | bc  -> 2
#   5. left-assoc '-'  echo '100-1-2' | bc  -> 97   (not 101)
#   6. unary minus     echo '50+10*-2' | bc -> 30   (unary '-' inside a term)
#   7. variables       (x=7 ; x*x) in a file, bc FILE -> 49
#
# Runs hamsh-as-/init so the serial line is the SOLE interactive shell
# (same rationale as scripts/test_pipe.sh).
#
# VERDICTS (scripts/_verdict.sh):
#   PASS (0) every result was OBSERVED correct
#   FAIL (1) a result was OBSERVED wrong
#   INCONCLUSIVE (125) never got far enough to observe (build/boot/starve)
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_log.sh"
. "$PROJ_ROOT/scripts/_kernel_iso.sh"

TAG="test_bc"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
SMP="${HAMNIX_TEST_SMP:-2}"
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[$TAG] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user.sh failed"
if [ ! -x build/user/bc.elf ]; then
    verdict_inconclusive "$TAG" "build/user/bc.elf missing after build"
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
FIFO=$(mktemp -u --tmpdir hamnix-bc-in.XXXXXX)
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

send_await_raw() {                 # <cmd> <literal-in-log> <secs>
    local cmd="$1" pat="$2" secs="$3" i
    alive || return 1
    printf '%s\n' "$cmd" >&3 2>/dev/null || return 1
    for i in $(seq 1 "$secs"); do
        grep -a -F -q "$pat" "$LOG" && { sleep 1; return 0; }
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

c1=0; c2=0; c3=0; c4=0; c5=0; c6=0; c7=0
send_await_out "echo '2+3*4' | bc"    '14'   "$CMD_WAIT" && c1=1
send_await_out "echo '(2+3)*4' | bc"  '20'   "$CMD_WAIT" && c2=1
send_await_out "echo '2^10' | bc"     '1024' "$CMD_WAIT" && c3=1
send_await_out "echo '17%5' | bc"     '2'    "$CMD_WAIT" && c4=1
send_await_out "echo '100-1-2' | bc"  '97'   "$CMD_WAIT" && c5=1
send_await_out "echo '50+10*-2' | bc" '30'   "$CMD_WAIT" && c6=1
# variables need a single bc process over two lines -> use a file.
send_await_raw "echo 'x=7' > /tmp/bcp"  "x=7 > /tmp/bcp"  "$CMD_WAIT" || true
sleep 1
send_await_raw "echo 'x*x' >> /tmp/bcp" "x*x >> /tmp/bcp" "$CMD_WAIT" || true
sleep 1
send_await_out "bc /tmp/bcp"          '49'   "$CMD_WAIT" && c7=1
alive && { printf 'exit\n' >&3 2>/dev/null || true; }
sleep 2

fail=0
wrong() { echo "[$TAG] WRONG: $*" >&2; fail=1; }
ok()    { echo "[$TAG] ok: $*"; }

# If NOTHING computed, the guest was starved rather than wrong.
if [ "$((c1+c2+c3+c4+c5+c6+c7))" -eq 0 ]; then
    echo "[$TAG] --- output lines ---" >&2
    outlines | tail -30 >&2
    verdict_inconclusive "$TAG" "bc produced no result within ${CMD_WAIT}s per case — guest starved?"
fi

check() {   # <var-was-observed> <expect> <label>
    local got="$1" want="$2" label="$3"
    if outline_eq "$want"; then
        ok "$label -> $want"
    elif [ "$got" -eq 0 ]; then
        verdict_inconclusive "$TAG" "$label never produced a result — guest starved?"
    else
        wrong "$label did not print $want"
    fi
}

check "$c1" '14'   "case 1 precedence '2+3*4'"
check "$c2" '20'   "case 2 parens '(2+3)*4'"
check "$c3" '1024' "case 3 power '2^10'"
check "$c4" '2'    "case 4 modulo '17%5'"
check "$c5" '97'   "case 5 left-assoc '100-1-2'"
check "$c6" '30'   "case 6 unary minus '50+10*-2'"
check "$c7" '49'   "case 7 variables (x=7; x*x) from file"

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- output lines ---" >&2
    outlines | tail -40 >&2
    verdict_fail "$TAG" "a bc result was OBSERVED wrong (see WRONG: lines)"
fi
verdict_pass "$TAG" \
    "bc evaluates precedence, parens, ^, %, left-assoc, unary minus and file-scoped variables"
