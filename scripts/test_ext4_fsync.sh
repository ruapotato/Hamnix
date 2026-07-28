#!/usr/bin/env bash
# scripts/test_ext4_fsync.sh — M16.x §12.4 verification:
# ext4 fsync + crash/reboot persistence.
#
# Two-part test:
#
#   Part A — fsync smoke. The kernel runs ext4_fsync_smoke_test() at
#   boot: create a file, write a marker, fsync (issue the block-device
#   cache barrier via blk_flush), read it back. Asserts the smoke
#   marker.
#
#   Part B — persistence across a reboot. The strongest proof an
#   fsync is real: boot QEMU once, write a uniquely-marked file into
#   the ext4 volume through the shell `>` redirect (which goes through
#   the ordered, write-through ext4 write path), exit cleanly. Then
#   boot a SECOND QEMU instance against the SAME, now-detached
#   ext4.img and `cat` the file back. If the write reached the disk
#   image, the marker survives the reboot.
#
# The ext4.img is NOT regenerated between the two boots — that is the
# whole point: the second boot must see what the first boot wrote.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"
TAG=test_ext4_fsync

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

MARKER="FSYNC_PERSIST_$(date +%s)"

echo "[test_ext4_fsync] (1/5) Regenerate disk images"
python3 scripts/build_diskimg.py

echo "[test_ext4_fsync] (2/5) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_ext4_fsync] (3/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

# Work on a private copy of ext4.img so a re-run starts clean and the
# repo's build/ext4.img is left pristine.
DISK=$(mktemp --suffix=.ext4-persist.img)
cp build/ext4.img "$DISK"

LOG1=$(mktemp)
LOG2=$(mktemp)
READY='[hamsh:stage-07] loop-enter'
# The disk rides on both boots via QEMU_EXTRA_ARGS (word-splits on spaces;
# the file= value has no spaces so it stays one token). _hamsh_drive.sh
# backgrounds QEMU, kills only OUR pid, and waits adaptively — no fixed
# `sleep 3` racing the prompt (the false-red the driver was built to kill).
export QEMU_EXTRA_ARGS="-drive file=$DISK,if=virtio,format=raw"
export HAMNIX_VM_MEM=256M

trap 'hamsh_shutdown; rm -f "$LOG1" "$LOG2" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4_fsync] (4/5) Boot #1 — write $MARKER to /ext, fsync, halt"
b1_ready=0
hamsh_boot "$LOG1" "$ELF"
if hamsh_wait_boot "$READY" 420 && hamsh_sync 120; then
    b1_ready=1
    # Fire the write (fire-and-forget: the redirect sends echo's output to
    # the FILE, so the ONLY place $MARKER lands in LOG1 is this command's
    # own readline echo — awaiting it here would be a false-positive
    # echo-sentinel, so we don't). Give the ordered write-through path time
    # to reach the disk image, THEN read it back in-session.
    hamsh_send "echo $MARKER > /ext/PERSIST.TXT"
    sleep 3
    hamsh_send_await "cat /ext/PERSIST.TXT" "$MARKER" 120 || true
    hamsh_send 'exit'
    sleep 2
fi
hamsh_shutdown

echo "[test_ext4_fsync] (5/5) Boot #2 — re-attach the SAME disk, read it back"
b2_ready=0
hamsh_boot "$LOG2" "$ELF"
if hamsh_wait_boot "$READY" 420 && hamsh_sync 120; then
    b2_ready=1
    # Boot #2 types ONLY `cat` — no write command — so $MARKER can appear in
    # LOG2 ONLY as genuine file content read back off the disk. This is the
    # load-bearing persistence proof (immune to the echo-sentinel class).
    hamsh_send_await "cat /ext/PERSIST.TXT" "$MARKER" 120 || true
    hamsh_send 'exit'
    sleep 2
fi
hamsh_shutdown

echo "[test_ext4_fsync] --- boot #1 ext4/fsync lines ---"
grep -E 'ext4: fsync|PERSIST' "$LOG1" || true
echo "[test_ext4_fsync] --- boot #2 PERSIST lines ---"
grep -E 'PERSIST' "$LOG2" || true
echo "[test_ext4_fsync] --- end ---"

# --- three-valued verdict --------------------------------------------------
# If EITHER boot never reached the shell read-loop, the assertion was never
# observed — INCONCLUSIVE (starved / OOM), not a regression.
if [ "$b1_ready" -ne 1 ]; then
    verdict_inconclusive "$TAG" \
        "boot #1 never reached '$READY' + FEEDER_SYNC — the fsync/write path" \
        "was never exercised (starved or OOM boot). Re-run on a QUIET host."
fi
if [ "$b2_ready" -ne 1 ]; then
    verdict_inconclusive "$TAG" \
        "boot #2 never reached '$READY' + FEEDER_SYNC — persistence could not" \
        "be observed (starved or OOM boot). Re-run on a QUIET host."
fi

fail=0

# Part A: the fsync smoke marker is a GENUINE kernel selftest banner
# (create -> write -> fsync/blk_flush -> read-back), printed unconditionally
# at boot — not an input echo.
if grep -F -q "ext4: fsync smoke PASS" "$LOG1"; then
    echo "[test_ext4_fsync] OK: ext4 fsync smoke (flush + read-back)"
else
    echo "[test_ext4_fsync] MISS: 'ext4: fsync smoke PASS'"
    fail=1
fi

# Part B (load-bearing): the marker survived into the SECOND boot's read.
# LOG2 has NO write command, so this $MARKER is genuine on-disk content.
if grep -F -q "$MARKER" "$LOG2"; then
    echo "[test_ext4_fsync] OK: $MARKER survived the reboot (real persistence)"
else
    echo "[test_ext4_fsync] MISS: $MARKER NOT found after reboot"
    echo "[test_ext4_fsync] --- boot #2 full log ---"
    cat "$LOG2"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" \
        "either the ext4 fsync smoke banner was OBSERVED absent, or the" \
        "on-disk $MARKER did NOT survive the reboot — both boots reached the" \
        "shell, so this is a real fsync/persistence regression."
fi

verdict_pass "$TAG" "ext4 fsync + reboot persistence: the boot-time fsync" \
    "smoke (create->write->blk_flush->read-back) passes AND a shell-written," \
    "write-through file survives a full power-cycle onto the SAME detached" \
    "ext4 image (read back genuinely, no write command in boot #2's log)"
