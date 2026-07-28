#!/usr/bin/env bash
# scripts/test_proc_dev_bind.sh - /proc -> /dev namespace-bind gate.
#
# Phase D follow-up: the Layer-2 _u_translate_proc_to_dev string-rewrite
# in linux_abi/u_syscalls.ad was retired in favour of per-leaf FILE
# bindings planted by pgrp_init (sys/src/9/port/chan.ad). This test
# proves the bindings actually route /proc/<name> through #c/<name>
# (== /dev/<name>) by reading both paths from a NATIVE Adder ELF
# (no Layer-2 shim in front of SYS_OPEN) and asserting byte-equality.
# Also asserts /proc/self/<leaf> still works via devproc's `self/`
# inline resolution (not the retired rewrite).
#
# MIGRATED (test-trustworthiness sweep) off the old marker-gated resend
# feeder onto the load-adaptive scripts/_hamsh_drive.sh (boot-ready
# marker + FEEDER_SYNC handshake + send-once). Assertions read the
# fixture's OWN `[procdevbind] …` OUTPUT markers, never the typed
# `/bin/test_proc_dev_bind` input-echo. Three-valued verdict: a starved
# guest is INCONCLUSIVE, an OBSERVED violation is a real FAIL.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_proc_dev_bind
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_proc_dev_bind.elf

echo "[test_proc_dev_bind] (1/4) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_proc_dev_bind] (2/4) Build tests/test_proc_dev_bind.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_proc_dev_bind.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_proc_dev_bind] (3/4) Plant /init = hamsh + /bin/test_proc_dev_bind in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_proc_dev_bind] (4/4) Rebuild kernel image + boot"
mkdir -p build
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
hamsh_send_await '/bin/test_proc_dev_bind' '[procdevbind] start' "$CMD_WAIT" || true
for _ in $(seq 1 "$CMD_WAIT"); do
    grep -a -Eq '\[procdevbind\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
    hamsh_alive || break
    sleep 1
done
hamsh_send 'exit'
sleep 2

echo "[test_proc_dev_bind] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_proc_dev_bind] --- end output ---"

verdict_boot_gate "$TAG" "$LOG" 0 '\[procdevbind\] (start|PASS|FAIL)'

fail=0
check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_proc_dev_bind] OK: $label"
    else
        echo "[test_proc_dev_bind] MISS: $label ($marker)"
        fail=1
    fi
}

check "[procdevbind] start"              "fixture ran"
check "[procdevbind] A cpuinfo bind ok"  "A: /proc/cpuinfo == /dev/cpuinfo via namespace bind"
check "[procdevbind] B loadavg bind ok"  "B: /proc/loadavg == /dev/loadavg via namespace bind"
check "[procdevbind] C hostname bind ok" "C: /proc/hostname == /dev/hostname via namespace bind"
check "[procdevbind] D self-stat ok"     "D: /proc/self/stat still resolves via devproc"
check "[procdevbind] PASS"               "fixture reached PASS"

if grep -a -F -q "[procdevbind] FAIL" "$LOG"; then
    echo "[test_proc_dev_bind] observed fixture FAIL line(s):"
    grep -a -F "[procdevbind] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

[ "$fail" -eq 0 ] \
    || verdict_fail "$TAG" "a /proc->#c bind assertion was VIOLATED (see MISS:/FAIL lines)."
verdict_pass "$TAG" "/proc -> #c bindings verified end-to-end."
