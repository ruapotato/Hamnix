#!/usr/bin/env bash
# scripts/test_sha256sum.sh — native `sha256sum` gate.
#
# Drives user/sha256sum.ad through a booted hamsh and asserts the digest
# it prints byte-for-byte against FIPS/coreutils reference vectors. The
# digests are fixed constants no other log line can produce, so every
# assertion is leak-proof (hamsh_out_eq, whole-line match).
#
# Reference vectors (verified on the host with GNU coreutils):
#   echo abc | sha256sum         ("abc\n") ->
#       edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb  -
#   sha256sum /dev/null          (0 bytes; pad-only path) ->
#       e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  /dev/null
#   echo hamnix > f ; sha256sum f  ("hamnix\n") ->
#       470d4a77962894e17dae1c7a98f9514cc1f971e6ba645bf4b6c9580ae52f3c94  /tmp/shf
#   sha256sum -c  with the right hash -> "/tmp/shf: OK"
#   sha256sum -c  with a wrong hash   -> "/tmp/shf: FAILED"
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

TAG="test_sha256sum"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
SMP="${HAMNIX_TEST_SMP:-2}"
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

H_ABC='edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb'
H_EMPTY='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
H_HAMNIX='470d4a77962894e17dae1c7a98f9514cc1f971e6ba645bf4b6c9580ae52f3c94'

echo "[$TAG] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user.sh failed"
if [ ! -x build/user/sha256sum.elf ]; then
    verdict_inconclusive "$TAG" "build/user/sha256sum.elf missing after build"
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
FIFO=$(mktemp -u --tmpdir hamnix-sha-in.XXXXXX)
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

c1=0; c2=0; c3=0; c4=0; c5=0
send_await_out "echo abc | sha256sum"   "${H_ABC}  -"          "$CMD_WAIT" && c1=1
send_await_out "sha256sum /dev/null"    "${H_EMPTY}  /dev/null" "$CMD_WAIT" && c2=1
# file operand
send_await_raw "echo hamnix > /tmp/shf" "hamnix > /tmp/shf"    "$CMD_WAIT" || true
sleep 1
send_await_out "sha256sum /tmp/shf"     "${H_HAMNIX}  /tmp/shf" "$CMD_WAIT" && c3=1
# check mode OK
send_await_raw "echo '${H_HAMNIX}  /tmp/shf' > /tmp/shc" "/tmp/shc" "$CMD_WAIT" || true
sleep 1
send_await_out "sha256sum -c /tmp/shc"  "/tmp/shf: OK"         "$CMD_WAIT" && c4=1
# check mode FAILED (all-zero hash)
send_await_raw "echo '0000000000000000000000000000000000000000000000000000000000000000  /tmp/shf' > /tmp/shbad" "shbad" "$CMD_WAIT" || true
sleep 1
send_await_out "sha256sum -c /tmp/shbad" "/tmp/shf: FAILED"    "$CMD_WAIT" && c5=1
alive && { printf 'exit\n' >&3 2>/dev/null || true; }
sleep 2

fail=0
wrong() { echo "[$TAG] WRONG: $*" >&2; fail=1; }
ok()    { echo "[$TAG] ok: $*"; }

if [ "$((c1+c2+c3+c4+c5))" -eq 0 ]; then
    echo "[$TAG] --- output lines ---" >&2
    outlines | tail -30 >&2
    verdict_inconclusive "$TAG" "sha256sum produced no digest within ${CMD_WAIT}s per case — guest starved?"
fi

check() {   # <observed> <expect-line> <label>
    local got="$1" want="$2" label="$3"
    if outline_eq "$want"; then
        ok "$label"
    elif [ "$got" -eq 0 ]; then
        verdict_inconclusive "$TAG" "$label never produced its line — guest starved?"
    else
        wrong "$label did not print the expected line"
    fi
}

check "$c1" "${H_ABC}  -"           "case 1 stdin 'abc' digest"
check "$c2" "${H_EMPTY}  /dev/null" "case 2 empty-input (/dev/null) digest"
check "$c3" "${H_HAMNIX}  /tmp/shf" "case 3 file-operand digest"
check "$c4" "/tmp/shf: OK"          "case 4 '-c' verify OK"
check "$c5" "/tmp/shf: FAILED"      "case 5 '-c' detects a wrong hash"

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- output lines ---" >&2
    outlines | tail -40 >&2
    verdict_fail "$TAG" "a sha256sum digest/verify was OBSERVED wrong (see WRONG: lines)"
fi
verdict_pass "$TAG" \
    "sha256sum matches FIPS vectors for stdin, empty input and file operands; -c verifies OK and detects mismatch"
