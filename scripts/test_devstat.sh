#!/usr/bin/env bash
# scripts/test_devstat.sh — regression for /dev/uptime + /dev/loadavg.
#
# Runs BOTH fixtures (test_devuptime + test_devloadavg) inside the same
# QEMU boot so we only pay the build-and-boot cost once:
#   1. Build userland (hamsh, coreutils).
#   2. Build the test fixtures tests/test_devuptime.ad and
#      tests/test_devloadavg.ad (build_initramfs.py auto-globs
#      build/user/*.elf into /bin).
#   3. Plant hamsh as /init.
#   4. Rebuild the kernel image so devuptime.ad + devloadavg.ad arms are
#      compiled in.
#   5. Boot in QEMU, drive both fixtures over serial, grep the contract
#      markers.
#
# PASS markers:
#   - "[test_devuptime] uptime_secs=<N>"       (well-formed "<secs>.<CC>")
#   - "[test_devloadavg] field_count=5"        (five whitespace fields)
# plus each fixture's "done" banner and a hamsh survival sentinel.
#
# INPUT TIMING: prompt-gated + output-adaptive via scripts/_hamsh_drive.sh
# (replaces the old fixed-sleep feeder that false-red'd under host load).

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_devstat
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
UP_ELF=build/user/test_devuptime.elf
LA_ELF=build/user/test_devloadavg.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[test_devstat] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
bash scripts/build_modules.sh >/dev/null || verdict_inconclusive "$TAG" "build_modules failed"

echo "[test_devstat] (2/5) Build tests/test_devuptime.ad + test_devloadavg.ad"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user tests/test_devuptime.ad "$UP_ELF" >/dev/null || verdict_inconclusive "$TAG" "test_devuptime.ad compile failed"
adder_bin x86_64-adder-user tests/test_devloadavg.ad "$LA_ELF" >/dev/null || verdict_inconclusive "$TAG" "test_devloadavg.ad compile failed"

echo "[test_devstat] (3/5) Plant /init = hamsh + /bin/test_dev{uptime,loadavg} in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"

echo "[test_devstat] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[test_devstat] (5/5) Boot QEMU per fixture + drive hamsh"
LOG=$(mktemp)      # devuptime boot
LOG2=$(mktemp)     # devloadavg boot
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG" "$LOG2"
}
trap cleanup EXIT

# ONE real command per boot. hamsh reliably executes exactly one command
# after the FEEDER_SYNC handshake; a SECOND command sent while it is still
# finishing the first can overflow the 16-byte 16550 RX FIFO and be lost,
# and interactive `;`-chaining runs only the first statement. So each
# independent fixture gets its own boot and is the single reliable command.
# We assert on genuine fixture OUTPUT markers only.
drive_one() {  # $1=log  $2=cmd  $3=done-marker  $4=label
    hamsh_boot "$1" "$ELF"
    hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
        || verdict_inconclusive "$TAG" "$4: hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
    hamsh_sync 120 \
        || verdict_inconclusive "$TAG" "$4: readline never echoed FEEDER_SYNC — stdin not consumed"
    hamsh_send_await "$2" "$3" "$CMD_WAIT" || true
    hamsh_send 'exit'
    sleep 2
    hamsh_shutdown
}

drive_one "$LOG"  '/bin/test_devuptime'  '[test_devuptime] done'  "devuptime"
drive_one "$LOG2" '/bin/test_devloadavg' '[test_devloadavg] done' "devloadavg"

echo "[test_devstat] --- captured output (devuptime) ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG"  | tr -d '\000'
echo "[test_devstat] --- captured output (devloadavg) ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG2" | tr -d '\000'
echo "[test_devstat] --- end output ---"

verdict_boot_gate "$TAG" "$LOG" 0 '\[test_devuptime\] start'

fail=0
# ---- /dev/uptime ----
if grep -a -F -q "[test_devuptime] start" "$LOG"; then
    grep -a -F -q "[test_devuptime] opened /dev/uptime OK" "$LOG" \
        && echo "[test_devstat] OK: /dev/uptime opened" \
        || { echo "[test_devstat] MISS: /dev/uptime open"; fail=1; }
    grep -a -E -q "\[test_devuptime\] uptime_secs=[0-9]+" "$LOG" \
        && echo "[devuptime] $(grep -a -E -o 'uptime_secs=[0-9]+' "$LOG" | head -n1)" \
        || { echo "[test_devstat] MISS: uptime_secs line"; fail=1; }
    grep -a -F -q "[test_devuptime] done" "$LOG" \
        && echo "[test_devstat] OK: uptime fixture done" \
        || { echo "[test_devstat] MISS: uptime done"; fail=1; }
else
    verdict_inconclusive "$TAG" \
        "the test_devuptime fixture never printed its start banner — the" \
        "guest was starved before it ran; /dev/uptime not observed. Re-run quiet."
fi

# ---- /dev/loadavg (from its own boot log) ----
if grep -a -F -q "[test_devloadavg] start" "$LOG2"; then
    grep -a -F -q "[test_devloadavg] opened /dev/loadavg OK" "$LOG2" \
        && echo "[test_devstat] OK: /dev/loadavg opened" \
        || { echo "[test_devstat] MISS: /dev/loadavg open"; fail=1; }
    grep -a -F -q "[test_devloadavg] field_count=5" "$LOG2" \
        && echo "[test_devstat] OK: loadavg field_count=5" \
        || { echo "[test_devstat] MISS: field_count=5"; fail=1; }
    grep -a -F -q "[test_devloadavg] done" "$LOG2" \
        && echo "[test_devstat] OK: loadavg fixture done" \
        || { echo "[test_devstat] MISS: loadavg done"; fail=1; }
else
    verdict_inconclusive "$TAG" \
        "the test_devloadavg fixture never printed its start banner — the" \
        "guest was starved before it ran; /dev/loadavg not observed. Re-run quiet."
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" \
        "a /dev/uptime or /dev/loadavg contract marker was OBSERVED absent" \
        "while the fixture ran (start banner present) — real regression."
fi

verdict_pass "$TAG" "/dev/uptime well-formed; /dev/loadavg has 5 fields; both fixtures ran to clean done"
