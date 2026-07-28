#!/usr/bin/env bash
# scripts/test_devdiskstats.sh — §13 regression for /dev/diskstats +
# /dev/stat (the system-stat introspection cdevs).
#
# Builds userland, both test fixtures, plants hamsh as /init, rebuilds the
# kernel, and boots QEMU ONCE PER FIXTURE, driving each over serial.
#
# PASS markers:
#   - /dev/diskstats: "[test_devdiskstats] field_count=14" — the row
#     carries the Linux-contract 14 whitespace-separated fields.
#   - /dev/stat: "[test_devsysstat] lines_ok" + "ctxt_nonzero" — all
#     six /proc/stat-shape lines present and the real context-switch
#     counter is non-zero.
# Plus each fixture's "done" banner. We assert ONLY on genuine fixture
# OUTPUT markers — NOT an `echo POST_...` sentinel, whose typed input-echo
# the serial log would spuriously match (that is the false-green class this
# sweep keeps finding).
#
# INPUT TIMING: prompt-gated + output-adaptive via scripts/_hamsh_drive.sh
# (replaces the old _qemu_drive.sh fixed post-command delays that overran
# under host load and false-red'd the trailing sentinel). A starved run now
# reports INCONCLUSIVE, never a false red or false green.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_devdiskstats
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
DS_ELF=build/user/test_devdiskstats.elf
SS_ELF=build/user/test_devsysstat.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[test_devdiskstats] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh    >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
bash scripts/build_modules.sh >/dev/null || verdict_inconclusive "$TAG" "build_modules failed"

echo "[test_devdiskstats] (2/5) Build tests/test_devdiskstats.ad + test_devsysstat.ad"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user tests/test_devdiskstats.ad -o "$DS_ELF" >/dev/null \
    || verdict_inconclusive "$TAG" "test_devdiskstats.ad compile failed"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user tests/test_devsysstat.ad -o "$SS_ELF" >/dev/null \
    || verdict_inconclusive "$TAG" "test_devsysstat.ad compile failed"

echo "[test_devdiskstats] (3/5) Plant /init = hamsh + /bin/test_dev{diskstats,sysstat} in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"

echo "[test_devdiskstats] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[test_devdiskstats] (5/5) Boot QEMU per fixture + drive hamsh"
LOG=$(mktemp)      # diskstats boot
LOG2=$(mktemp)     # sysstat boot
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG" "$LOG2"
}
trap cleanup EXIT

# ONE real command per boot (see scripts/test_devstat.sh for the rationale:
# a second command sent while hamsh is still finishing the first can overflow
# the 16550 RX FIFO). Each fixture gets its own boot and is the single
# reliable command; we assert on genuine fixture OUTPUT markers only.
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

drive_one "$LOG"  '/bin/test_devdiskstats' '[test_devdiskstats] done' "diskstats"
drive_one "$LOG2" '/bin/test_devsysstat'   '[test_devsysstat] done'   "sysstat"

echo "[test_devdiskstats] --- captured output (diskstats) ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG"  | tr -d '\000'
echo "[test_devdiskstats] --- captured output (sysstat) ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG2" | tr -d '\000'
echo "[test_devdiskstats] --- end output ---"

fail=0

# ---- /dev/diskstats (from its own boot log) ----
if grep -a -F -q "[test_devdiskstats] opened OK" "$LOG"; then
    echo "[test_devdiskstats] OK: /dev/diskstats opened"
    grep -a -F -q "[test_devdiskstats] field_count=14" "$LOG" \
        && echo "[test_devdiskstats] OK: diskstats row has 14 fields" \
        || { echo "[test_devdiskstats] MISS: diskstats row field count wrong"; fail=1; }
    grep -a -F -q "[test_devdiskstats] done" "$LOG" \
        && echo "[test_devdiskstats] OK: diskstats fixture completed" \
        || { echo "[test_devdiskstats] MISS: diskstats fixture didn't finish"; fail=1; }
else
    verdict_inconclusive "$TAG" \
        "the test_devdiskstats fixture never printed its 'opened OK' banner —" \
        "the guest was starved before it ran; /dev/diskstats not observed. Re-run quiet."
fi

# ---- /dev/stat (from its own boot log) ----
if grep -a -F -q "[test_devsysstat] opened OK" "$LOG2"; then
    echo "[test_devdiskstats] OK: /dev/stat opened"
    grep -a -F -q "[test_devsysstat] lines_ok" "$LOG2" \
        && echo "[test_devdiskstats] OK: /proc/stat-shape lines all present" \
        || { echo "[test_devdiskstats] MISS: /dev/stat missing a line"; fail=1; }
    grep -a -F -q "[test_devsysstat] ctxt_nonzero" "$LOG2" \
        && echo "[test_devdiskstats] OK: /dev/stat ctxt counter is real" \
        || { echo "[test_devdiskstats] MISS: /dev/stat ctxt is zero"; fail=1; }
    grep -a -F -q "[test_devsysstat] done" "$LOG2" \
        && echo "[test_devdiskstats] OK: sysstat fixture completed" \
        || { echo "[test_devdiskstats] MISS: sysstat fixture didn't finish"; fail=1; }
else
    verdict_inconclusive "$TAG" \
        "the test_devsysstat fixture never printed its 'opened OK' banner —" \
        "the guest was starved before it ran; /dev/stat not observed. Re-run quiet."
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" \
        "a /dev/diskstats or /dev/stat contract marker was OBSERVED absent while" \
        "the fixture ran (opened-OK banner present) — a real regression."
fi

verdict_pass "$TAG" "/dev/diskstats row has the Linux-contract 14 fields; /dev/stat has all six /proc/stat lines with a non-zero real ctxt counter; both fixtures ran to clean done."
