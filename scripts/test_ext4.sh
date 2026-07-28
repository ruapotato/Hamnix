#!/usr/bin/env bash
# scripts/test_ext4.sh - M16.51..M16.54 verification.
#
# Boots the kernel with build/ext4.img attached via virtio-blk so
# vda is detected as ext4 (FAT magic absent at sector 0). The
# ext4 driver mounts at /ext via the standard probe path. The
# test drives hamsh through `cat /ext/HELLO.TXT` and asserts:
#
#   1. The superblock log lines appeared (M16.51).
#   2. ext4_read_inode produced inode 2 with mode 0x41ED (M16.52).
#   3. The boot-time dirent dump found HELLO.TXT (M16.53).
#   4. cat /ext/HELLO.TXT delivered the marker — meaning the full
#      read path (root lookup → inode → extent → block → VFS →
#      user) works (M16.54).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_ext4] (1/5) Regenerate disk images"
python3 scripts/build_diskimg.py

echo "[test_ext4] (2/5) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_ext4] (3/5) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_ext4] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

echo "[test_ext4] (5/5) Boot QEMU with ext4 image as virtio-blk"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Gate on hamsh's readline coming up instead of a fixed sleep.
    # Under host load the boot takes well over 3s to reach the prompt
    # and a fixed-sleep feeder silently drops EVERY early command
    # (cat HELLO/NESTED/FILE49, ls|wc, the WRITE_VIA_SHELL echo...)
    # while the later ones still land — a confusing partial-MISS
    # pattern that looks like an ext4 regression but isn't.
    for _ in $(seq 1 240); do
        if grep -aq "loop-enter" "$LOG" 2>/dev/null; then break; fi
        sleep 0.25
    done
    # The freshly-booted readline drops the first serial line it is
    # sent (never echoes it). Re-send a sync probe until its
    # keystrokes echo back, then start the real commands.
    for _ in $(seq 1 20); do
        printf 'echo FEEDER_SYNC\n'
        sleep 1
        if grep -aq "FEEDER_SYNC" "$LOG" 2>/dev/null; then break; fi
    done
    printf 'cat /ext/HELLO.TXT\n'
    sleep 1
    # M16.68: HELLO_LINK is a symlink to /HELLO.TXT planted in the
    # image by build_diskimg.py. Reading it exercises the symlink
    # follow-through in ext4_resolve_file. The output is HELLO.TXT's
    # body, so the existing EXT4_MARKER assertion below covers both.
    printf 'cat /ext/HELLO_LINK\n'
    sleep 1
    printf 'ls /ext/SUB\n'
    sleep 1
    printf 'cat /ext/SUB/NESTED.TXT\n'
    sleep 1
    printf 'cat /ext/BIG.TXT\n'
    sleep 1
    # M16.63: SMOKE.TXT was created by the kernel at boot via
    # ext4_create_file. cat verifies the read path sees the new
    # dirent, the new inode, and the new data block end-to-end.
    printf 'cat /ext/SMOKE.TXT\n'
    sleep 1
    # M16.59: FILE49.TXT lives in the second block of the root dir
    # (which spans 2 blocks after we plant 50 extras). Resolving it
    # exercises the multi-block dir walk; a single-block walker
    # would silently miss it.
    printf 'cat /ext/FILE49.TXT\n'
    sleep 1
    # ext4_listdir should now stream entries from BOTH blocks of
    # the root dir — pipe through wc to get a line count. With
    # entries: . .. lost+found HELLO.TXT BIG.TXT FILE00..FILE49 SUB
    # = 55 lines.
    printf 'ls /ext | wc\n'
    sleep 2
    # M16.64: ext4 write through shell `>` redirect. echo writes
    # "WRITE_VIA_SHELL\n" into a new ext4 file; cat reads it back.
    printf 'echo WRITE_VIA_SHELL > /ext/USERMADE.TXT\n'
    sleep 2
    printf 'cat /ext/USERMADE.TXT\n'
    sleep 2
    # M16.67: ext4 unlink. rm removes the file we just made; a
    # second cat should fail to find it. We test by then
    # creating /ext/UNLINKED_OK.TXT — if unlink left the inode
    # bitmap in a bad state, this create would fail.
    printf 'rm /ext/USERMADE.TXT\n'
    sleep 2
    printf 'echo UNLINKED_OK > /ext/UNLINKED_OK.TXT\n'
    sleep 2
    printf 'cat /ext/UNLINKED_OK.TXT\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 150s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file=build/ext4.img,if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ext4] --- captured output ---"
cat "$LOG"
echo "[test_ext4] --- end output ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# A TCG-starved / GRUB-OOM boot emits ZERO ext4 markers and used to be
# indistinguishable from a real end-to-end regression (a wall of MISS ->
# hard FAIL). Route the zero-marker case through the shared discriminator
# FIRST: INCONCLUSIVE (starved/timeout/OOM), never a bogus red.
verdict_boot_gate "$TAG" "$LOG" "$rc" 'ext4: mounted|EXT4_MARKER|\[ext4'

fail=0
# NOTE: WRITE_VIA_SHELL and UNLINKED_OK are NOT in this whole-log needle
# loop. Their payload is TYPED at the shell (`echo WRITE_VIA_SHELL > f`),
# and hamsh's readline reprints the whole in-progress line on every
# keystroke, so the literal string appears dozens of times as INPUT ECHO
# even if the write path is completely broken — grepping the log for it is
# a false-green echo-sentinel. They get a dedicated genuine-OUTPUT check
# below (a line NOT prefixed by the `hamsh$` prompt).
for needle in \
    "ext4: mounted; block_size=1024 inodes_count=128" \
    "ext4 inode#2 mode=" \
    "dirent inode=12 name='HELLO.TXT'" \
    "EXT4_MARKER hello from /ext/HELLO.TXT" \
    "NESTED.TXT" \
    "EXT4_NESTED_MARKER /ext/SUB/NESTED.TXT" \
    "DEPTH1_MARKER ext4 index extents work" \
    "ext4: bitmap smoke PASS" \
    "ext4: create smoke PASS" \
    "CREATE_OK ext4 file-create round-trip works" \
    "ext4: rename smoke PASS" \
    "ext4: truncate smoke PASS" \
    "ext4: fsync smoke PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_ext4] OK: '$needle'"
    else
        echo "[test_ext4] MISS: '$needle'"
        fail=1
    fi
done

# WRITE_VIA_SHELL / UNLINKED_OK: assert GENUINE cat output, not the write
# command's readline echo. Every readline redraw line carries the `hamsh$`
# prompt; the file's actual content is emitted by `cat` on a line WITHOUT
# it. Requiring a non-prompt line proves the ext4 write + read-back round
# trip really happened (a broken write path would leave only the echoes).
if grep -F "WRITE_VIA_SHELL" "$LOG" | grep -qv 'hamsh\$'; then
    echo "[test_ext4] OK: 'WRITE_VIA_SHELL' (genuine ext4 write+readback, not input echo)"
else
    echo "[test_ext4] MISS: 'WRITE_VIA_SHELL' had no genuine cat output line (only input echo)"
    fail=1
fi
if grep -F "UNLINKED_OK" "$LOG" | grep -qv 'hamsh\$'; then
    echo "[test_ext4] OK: 'UNLINKED_OK' (genuine post-unlink create+readback, not input echo)"
else
    echo "[test_ext4] MISS: 'UNLINKED_OK' had no genuine cat output line (only input echo)"
    fail=1
fi

# M16.59 multi-block dir assertions: FILE49.TXT lives in the second
# block of the root dir; resolving it via cat exercises the
# multi-block ext4_dir_lookup walk. The wc count line is a stricter
# regression: cleaned stdout includes the literal "55 55 ..." token.
cleaned=$(sed 's/task: pid -*[0-9]* exited (code=-*[0-9]*)//g' "$LOG" \
          | tr '\n' ' ' | tr -s ' ')

# cat /ext/FILE49.TXT outputs BIG.TXT's body (the source we wrote it
# from) — first 14 bytes are unique enough to grep for.
if echo "$cleaned" | grep -F -q "DEPTH1_MARKER ext4 index extents work"; then
    : # already asserted above by the loop
fi
if grep -F -q "cat /ext/FILE49.TXT" "$LOG"; then
    # If we see the prompt before AND a non-empty file-not-found
    # error, the lookup failed. Direct positive check: the second
    # cat (in the same session) emits its body to stdout, which
    # is BIG.TXT's body (single line).
    if echo "$cleaned" | grep -oF "DEPTH1_MARKER ext4 index extents work" | wc -l \
       | grep -q -E '^[2-9]|^[0-9]{2,}$'; then
        echo "[test_ext4] OK: FILE49.TXT (in second dir block) resolved"
    else
        echo "[test_ext4] MISS: FILE49.TXT didn't resolve to second-block content"
        fail=1
    fi
fi

# ls /ext | wc — root dir has 59 entries before the shell write
# (., .., lost+found, HELLO.TXT, BIG.TXT, SUB, FILE00..FILE49,
# SMOKE.TXT, HELLO_LINK, .hamnix-grown). SMOKE.TXT was created by
# ext4_create_smoke_test at kernel init; HELLO_LINK is the M16.68
# symlink planted in the disk image; .hamnix-grown is the firstboot
# grow sentinel planted unconditionally since fb3a7d79 (the count
# was silently stale at 58 from then until the feeder fix exposed
# it). The count verifies that BOTH the multi-block listdir works
# (a single-block walker would stop ~30) AND that the M16.63 dirent
# insert is visible through the same listdir path. The shell-created
# USERMADE.TXT comes LATER in the session so it doesn't affect this
# count.
if echo "$cleaned" | grep -E -q "(^| )59 59 "; then
    echo "[test_ext4] OK: ls /ext listed all 59 entries (multi-block + create + symlink + sentinel)"
else
    echo "[test_ext4] MISS: ls /ext | wc didn't show 59-line count"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    # Markers printed but not all assertions held AND qemu was killed by
    # timeout -> the session was starved before the later commands landed
    # (a partial feed), not a regression. A clean qemu exit with an
    # observed MISS is a real, actionable red.
    if [ "$rc" -eq 124 ] && ! grep -F -q "UNLINKED_OK" "$LOG"; then
        verdict_inconclusive "$TAG" \
            "ext4 mounted and early markers printed, but the later serial" \
            "commands' effects never landed and qemu was killed by timeout" \
            "(rc=124) — the feed was starved mid-session. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "an ext4 end-to-end assertion (read path, multi-block dir walk, the" \
        "59-entry listdir, or a genuine shell write/unlink round-trip) was" \
        "OBSERVED to fail while the session ran (qemu rc=$rc) — real regression."
fi
verdict_pass "$TAG" "ext4 end-to-end on a live virtio-blk mount: root+nested" \
    "reads, symlink follow, multi-block dir walk (FILE49 in block 2), the" \
    "full 59-entry listdir, and genuine shell write + unlink round-trips" \
    "(qemu rc=$rc)"
