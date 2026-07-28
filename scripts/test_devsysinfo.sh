#!/usr/bin/env bash
# scripts/test_devsysinfo.sh — regression for /dev/cpuinfo + /dev/meminfo.
#
# Runs BOTH fixtures (test_devcpuinfo + test_devmeminfo) inside the same
# QEMU boot so we only pay the build-and-boot cost once:
#   1. Build userland (hamsh, coreutils).
#   2. Build tests/test_devcpuinfo.ad + tests/test_devmeminfo.ad.
#   3. Plant hamsh as /init.
#   4. Rebuild the kernel image.
#   5. Boot in QEMU, drive both fixtures over serial, grep the markers.
#
# PASS markers:
#   - "[test_devcpuinfo] vendor=<GenuineIntel|AuthenticAMD>"
#   - "[test_devmeminfo] MemTotal=<digits> kB"
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

TAG=test_devsysinfo
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
CPU_ELF=build/user/test_devcpuinfo.elf
MEM_ELF=build/user/test_devmeminfo.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[test_devsysinfo] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
bash scripts/build_modules.sh >/dev/null || verdict_inconclusive "$TAG" "build_modules failed"

echo "[test_devsysinfo] (2/5) Build tests/test_devcpuinfo.ad + test_devmeminfo.ad"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user tests/test_devcpuinfo.ad "$CPU_ELF" >/dev/null || verdict_inconclusive "$TAG" "test_devcpuinfo.ad compile failed"
adder_bin x86_64-adder-user tests/test_devmeminfo.ad "$MEM_ELF" >/dev/null || verdict_inconclusive "$TAG" "test_devmeminfo.ad compile failed"

echo "[test_devsysinfo] (3/5) Plant /init = hamsh + /bin/test_dev{cpuinfo,meminfo} in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"

echo "[test_devsysinfo] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[test_devsysinfo] (5/5) Boot QEMU per fixture + drive hamsh"
LOG=$(mktemp)      # devcpuinfo boot
LOG2=$(mktemp)     # devmeminfo boot
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

drive_one "$LOG"  '/bin/test_devcpuinfo' '[test_devcpuinfo] done' "devcpuinfo"
drive_one "$LOG2" '/bin/test_devmeminfo' '[test_devmeminfo] done' "devmeminfo"

echo "[test_devsysinfo] --- captured output (devcpuinfo) ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG"  | tr -d '\000'
echo "[test_devsysinfo] --- captured output (devmeminfo) ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG2" | tr -d '\000'
echo "[test_devsysinfo] --- end output ---"

verdict_boot_gate "$TAG" "$LOG" 0 '\[test_devcpuinfo\] start'

fail=0
# ---- /dev/cpuinfo ----
if grep -a -F -q "[test_devcpuinfo] start" "$LOG"; then
    grep -a -F -q "[test_devcpuinfo] opened /dev/cpuinfo OK" "$LOG" \
        && echo "[test_devsysinfo] OK: /dev/cpuinfo opened" \
        || { echo "[test_devsysinfo] MISS: /dev/cpuinfo open"; fail=1; }
    grep -a -E -q "\[test_devcpuinfo\] vendor=(GenuineIntel|AuthenticAMD)" "$LOG" \
        && echo "[devcpuinfo] vendor=$(grep -a -E -o 'vendor=(GenuineIntel|AuthenticAMD)' "$LOG" | head -n1 | cut -d= -f2)" \
        || { echo "[test_devsysinfo] MISS: vendor= line absent/unrecognised"; fail=1; }
    grep -a -F -q "[test_devcpuinfo] processor_line OK" "$LOG" \
        && echo "[test_devsysinfo] OK: /proc/cpuinfo Linux processor stanza present" \
        || { echo "[test_devsysinfo] MISS: cpuinfo processor line"; fail=1; }
    grep -a -F -q "[test_devcpuinfo] model_name OK" "$LOG" \
        && echo "[test_devsysinfo] OK: /proc/cpuinfo Linux model name present" \
        || { echo "[test_devsysinfo] MISS: cpuinfo model name"; fail=1; }
    grep -a -F -q "[test_devcpuinfo] done" "$LOG" \
        && echo "[test_devsysinfo] OK: cpuinfo fixture done" \
        || { echo "[test_devsysinfo] MISS: cpuinfo done"; fail=1; }
else
    verdict_inconclusive "$TAG" \
        "the test_devcpuinfo fixture never printed its start banner — the" \
        "guest was starved before it ran; /dev/cpuinfo not observed. Re-run quiet."
fi

# ---- /dev/meminfo (from its own boot log) ----
if grep -a -F -q "[test_devmeminfo] start" "$LOG2"; then
    grep -a -F -q "[test_devmeminfo] opened /dev/meminfo OK" "$LOG2" \
        && echo "[test_devsysinfo] OK: /dev/meminfo opened" \
        || { echo "[test_devsysinfo] MISS: /dev/meminfo open"; fail=1; }
    grep -a -E -q "\[test_devmeminfo\] MemTotal=[0-9]+ kB" "$LOG2" \
        && echo "[devmeminfo] $(grep -a -E -o 'MemTotal=[0-9]+ kB' "$LOG2" | head -n1)" \
        || { echo "[test_devsysinfo] MISS: MemTotal=<digits> kB line absent"; fail=1; }
    grep -a -F -q "[test_devmeminfo] MemAvailable OK" "$LOG2" \
        && echo "[test_devsysinfo] OK: /proc/meminfo MemAvailable present (free 'available')" \
        || { echo "[test_devsysinfo] MISS: meminfo MemAvailable"; fail=1; }
    grep -a -F -q "[test_devmeminfo] Buffers OK" "$LOG2" \
        && echo "[test_devsysinfo] OK: /proc/meminfo Buffers present (free 'buff/cache')" \
        || { echo "[test_devsysinfo] MISS: meminfo Buffers"; fail=1; }
    grep -a -F -q "[test_devmeminfo] Cached OK" "$LOG2" \
        && echo "[test_devsysinfo] OK: /proc/meminfo Cached present (free 'buff/cache')" \
        || { echo "[test_devsysinfo] MISS: meminfo Cached"; fail=1; }
    grep -a -F -q "[test_devmeminfo] done" "$LOG2" \
        && echo "[test_devsysinfo] OK: meminfo fixture done" \
        || { echo "[test_devsysinfo] MISS: meminfo done"; fail=1; }
else
    verdict_inconclusive "$TAG" \
        "the test_devmeminfo fixture never printed its start banner — the" \
        "guest was starved before it ran; /dev/meminfo not observed. Re-run quiet."
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" \
        "a /dev/cpuinfo or /dev/meminfo contract marker was OBSERVED absent" \
        "while the fixture ran (start banner present) — real regression."
fi

verdict_pass "$TAG" "/dev/cpuinfo vendor recognised; /dev/meminfo MemTotal present; both fixtures ran to clean done"
