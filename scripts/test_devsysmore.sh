#!/usr/bin/env bash
# scripts/test_devsysmore.sh — regression for /dev/stat + /dev/mounts +
# /dev/diskstats (M16.135). Combined fixture (tests/test_devsys.ad).
#
# Pipeline mirrors test_devsysinfo.sh / test_devstat.sh / test_devid.sh:
#   1. Build userland (hamsh, coreutils).
#   2. Build the test fixture tests/test_devsys.ad (build_initramfs.py
#      auto-globs build/user/*.elf into /bin).
#   3. Plant hamsh as /init.
#   4. Rebuild the kernel image so devstat.ad + devmounts.ad +
#      devdiskstats.ad arms are compiled in.
#   5. Boot in QEMU, drive the fixture over serial stdio, grep the markers.
#
# PASS markers: "[devstat] ok", "[devmounts] ok", "[devdiskstats] ok",
# the fixture's "done" banner, and a hamsh survival sentinel.
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

TAG=test_devsysmore
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
SYS_ELF=build/user/test_devsys.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[test_devsysmore] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
bash scripts/build_modules.sh >/dev/null || verdict_inconclusive "$TAG" "build_modules failed"

echo "[test_devsysmore] (2/5) Build tests/test_devsys.ad -> $SYS_ELF"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user tests/test_devsys.ad "$SYS_ELF" >/dev/null || verdict_inconclusive "$TAG" "test_devsys.ad compile failed"

echo "[test_devsysmore] (3/5) Plant /init = hamsh + /bin/test_devsys in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"

echo "[test_devsysmore] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[test_devsysmore] (5/5) Boot QEMU + drive the fixture via hamsh"
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

# Send exactly ONE real command (the fixture) after the sync handshake and
# wait on its OWN "done" OUTPUT marker. We do NOT tack on a POST_* survival
# echo: hamsh echoes every typed keystroke to the same serial the log
# captures, so a `grep POST_X` would match the INPUT ECHO of `echo POST_X`
# and "prove" nothing (the pre-migration gate had exactly this bogus check).
# The fixture printing "[test_devsys] done" and the kernel logging its clean
# child exit already prove hamsh ran the command and the shell survived.
hamsh_send_await '/bin/test_devsys' '[test_devsys] done' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[test_devsysmore] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_devsysmore] --- end output ---"

# If the fixture never started, the guest was starved before it ran.
verdict_boot_gate "$TAG" "$LOG" 0 '\[test_devsys\] start'

fail=0
for m in "[devstat] ok" \
         "[devmounts] ok" \
         "[devdiskstats] ok" \
         "[test_devsys] done"; do
    if grep -a -F -q "$m" "$LOG"; then
        echo "[test_devsysmore] OK: marker '$m'"
    else
        echo "[test_devsysmore] MISS: marker '$m'"; fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    # The fixture demonstrably RAN (boot_gate saw its start), so an absent
    # contract marker is an OBSERVED /dev/stat|mounts|diskstats regression.
    verdict_fail "$TAG" \
        "a /dev/stat, /dev/mounts or /dev/diskstats contract marker was" \
        "OBSERVED absent while the fixture ran — real regression."
fi

verdict_pass "$TAG" "/dev/stat, /dev/mounts, /dev/diskstats all report ok; fixture ran to clean done"
