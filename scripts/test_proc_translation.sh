#!/usr/bin/env bash
# scripts/test_proc_translation.sh — M16.134 regression.
#
# Layer-2 /proc/<name> -> /dev/<name> translation. Linux ELFs opening
# /proc/cpuinfo (and the five siblings) now get the bytes the native
# /dev/cpuinfo cdev emits, with the redirect entirely inside
# linux_abi/u_syscalls.ad's _u_open / _u_openat. The native rootfs
# remains free of /proc/<name> entries.
#
# PASS markers from the fixture (defined in
# tests/u-binary/src/proc_translation/proc_translation.S):
#   - "[proc-translation] /proc/cpuinfo open OK"
#   - "[proc-translation] /dev/cpuinfo open OK"
#   - "[proc-translation] /proc/cpuinfo == /dev/cpuinfo OK"
#   - "[proc-translation] vendor line present OK"
#   - "[proc-translation] /proc/self/stat open OK"
#
# MIGRATED (test-trustworthiness sweep) off the old fixed-`sleep 3`
# feeder onto the load-adaptive scripts/_hamsh_drive.sh (boot-ready
# marker + FEEDER_SYNC handshake + send-once). Assertions read the
# fixture's OWN `[proc-translation] …` OUTPUT markers, never the typed
# `u_proc_translation` input-echo. Three-valued verdict: a starved
# guest is INCONCLUSIVE, an OBSERVED violation is a real FAIL.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_proc_translation
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/proc_translation; only SKIP on a
# real build failure.
ensure_ubin_or_skip test_proc_translation u_proc_translation proc_translation

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_proc_translation] (1/3) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_proc_translation] (2/3) Swap /init = $HAMSH_ELF + embed u_proc_translation"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_proc_translation] (3/3) Rebuild kernel image + boot"
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
hamsh_send_await 'u_proc_translation' '[proc-translation]' "$CMD_WAIT" || true
# Wait (bounded) for the fixture to reach its last OK or any FAIL line.
for _ in $(seq 1 "$CMD_WAIT"); do
    grep -a -Eq '\[proc-translation\] (/proc/self/stat open OK|.*FAIL)' "$LOG" 2>/dev/null && break
    hamsh_alive || break
    sleep 1
done
hamsh_send 'exit'
sleep 2

echo "[test_proc_translation] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_proc_translation] --- end output ---"

# Zero fixture markers -> starved guest, not a translation regression.
verdict_boot_gate "$TAG" "$LOG" 0 'Linux-ABI binary detected|\[proc-translation\]'

fail=0
check_marker() {
    local label="$1" needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_proc_translation] OK: $label"
    else
        echo "[test_proc_translation] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "U1/U2 ELF detect"      "Linux-ABI binary detected"
check_marker "/proc/cpuinfo opens"   "[proc-translation] /proc/cpuinfo open OK"
check_marker "/dev/cpuinfo opens"    "[proc-translation] /dev/cpuinfo open OK"
check_marker "byte-equality"         "[proc-translation] /proc/cpuinfo == /dev/cpuinfo OK"
check_marker "vendor line present"   "[proc-translation] vendor line present OK"
check_marker "/proc/self/stat opens" "[proc-translation] /proc/self/stat open OK"

# Surface every failure-exit path the fixture can emit.
for negmark in \
    "[proc-translation] open(/proc/cpuinfo) FAIL" \
    "[proc-translation] read(/proc/cpuinfo) FAIL" \
    "[proc-translation] open(/dev/cpuinfo) FAIL" \
    "[proc-translation] read(/dev/cpuinfo) FAIL" \
    "[proc-translation] length mismatch FAIL" \
    "[proc-translation] byte mismatch FAIL" \
    "[proc-translation] vendor line missing FAIL" \
    "[proc-translation] open(/proc/self/stat) FAIL" \
    "[proc-translation] read(/proc/self/stat) FAIL" \
    "[proc-translation] /proc/self/stat shape FAIL"
do
    if grep -a -F -q "$negmark" "$LOG"; then
        echo "[test_proc_translation] DIAG: fixture reported '$negmark'"
        fail=1
    fi
done

[ "$fail" -eq 0 ] \
    || verdict_fail "$TAG" "a /proc/cpuinfo -> /dev/cpuinfo translation assertion was VIOLATED (see MISS:/DIAG lines)."
verdict_pass "$TAG" "Layer-2 /proc/cpuinfo -> /dev/cpuinfo translation working."
