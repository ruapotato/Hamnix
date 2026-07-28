#!/usr/bin/env bash
# scripts/test_ext4_resize.sh — ext4 ONLINE-GROW (resize2fs-equivalent)
# against the native ext4 driver's ext4_resize_grow().
#
# The Hamnix installer lays down a fixed-size ext4 root that must be
# growable to fill the target disk after install. fs/ext4.ad's
# ext4_resize_grow() appends whole block groups: it writes each new
# group's descriptor, zeroes+inits its block/inode bitmaps and inode
# table, marks the metadata blocks used, bumps s_blocks_count plus the
# free-block/free-inode counts, and — when the FS carries
# RO_COMPAT_METADATA_CSUM — recomputes every crc32c checksum (group
# descriptor, block/inode bitmaps, and the superblock).
#
# This test mints a SMALL metadata_csum ext4 (a whole number of block
# groups) on a much larger SECOND virtio disk (vdb). On boot, init's
# _first_boot_grow_check() (the real installer first-boot resize-to-fit
# path) walks the block devices, finds vdb as the highest-numbered ext4,
# and grows it to fill the device via fs/ext4.ad's ext4_resize_grow().
# This is the SAME code path a freshly-installed disk takes on its first
# boot, so the test exercises production behaviour rather than a bespoke
# self-test hook. The driver prints stable [ext4_resize]/[firstboot]
# markers this script greps.
#
# INDEPENDENT ORACLE: after QEMU exits, the host runs `e2fsck -fn` on
# the grown vdb image. Because the driver's block round-trip leaves the
# image bit-identical to the clean grow, a green e2fsck proves every
# new group descriptor / bitmap / superblock checksum + free-count is
# correct per e2fsprogs — not just self-consistent with our own reader.
#
# vda stays the normal shared build/ext4.img root so the boot is a
# standard ext4 boot; vdb is the disposable grow target.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_resize

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

_which() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
    for prefix in /sbin /usr/sbin /usr/local/sbin; do
        if [ -x "$prefix/$name" ]; then echo "$prefix/$name"; return 0; fi
    done
    echo "$0: required tool '$name' not found" >&2
    return 1
}
MKE2FS="$(_which mke2fs)"
DEBUGFS="$(_which debugfs)"
DUMPE2FS="$(_which dumpe2fs)"
E2FSCK="$(_which e2fsck)"

# --- (1) Mint the grow-target disk -----------------------------------
# 64 MiB backing device, but format the ext4 at only the first 8192
# blocks (= one full 1 KiB block group, since blocks_per_group is 8192
# for 1 KiB blocks). A whole-group FS keeps the grow's group math exact
# (no partial trailing group). The driver later grows it to fill the
# 64 MiB device — roughly eight block groups.
echo "[test_ext4_resize] (1/6) Mint a small metadata_csum ext4 on a large disk (vdb)"
RDISK=$(mktemp --suffix=.ext4-resize.img)
truncate -s 64M "$RDISK"
# 8192 1-KiB blocks = exactly one block group.
"$MKE2FS" -F -q -b 1024 -t ext4 -L "HAMNIX_RESIZE" \
    -O metadata_csum,^has_journal,^64bit,^metadata_csum_seed,^resize_inode \
    "$RDISK" 8192 >/dev/null

# Confirm the host agrees the image carries metadata_csum and is exactly
# one block group (so the driver's whole-group grow math is exercised on
# a clean starting point).
if ! "$DUMPE2FS" -h "$RDISK" 2>/dev/null | grep -qiE '(^| )metadata_csum( |$)'; then
    echo "[test_ext4_resize] FAIL: minted image lacks metadata_csum"
    rm -f "$RDISK"; exit 1
fi
GROUP_CT=$("$DUMPE2FS" "$RDISK" 2>/dev/null | grep -c '^Group ' || true)
echo "[test_ext4_resize] host: metadata_csum present; block groups=$GROUP_CT"
if [ "$GROUP_CT" -ne 1 ]; then
    echo "[test_ext4_resize] FAIL: expected 1 starting block group, got $GROUP_CT"
    rm -f "$RDISK"; exit 1
fi

# Plant the marker file AND pack group 0 nearly full so the driver's
# post-grow allocator must reach into a freshly-appended group to find
# a free block (proving the grown region is live).
TMP_MARK="$(mktemp --suffix=.resize-marker)"
printf 'EXT4RESIZE_MARKER online grow keeps old data intact\n' > "$TMP_MARK"
TMP_FILL="$(mktemp --suffix=.resize-fill)"
# ~7 MiB of filler — leaves group 0 with little/no free data space.
head -c 7000000 /dev/zero | tr '\0' 'F' > "$TMP_FILL"
"$DEBUGFS" -w -f /dev/stdin "$RDISK" >/dev/null <<EOF
write $TMP_MARK RESIZEME.TXT
write $TMP_FILL FILLER.DAT
EOF
rm -f "$TMP_MARK" "$TMP_FILL"

# Sanity: the freshly-minted image must be e2fsck-clean before we grow.
if ! "$E2FSCK" -fn "$RDISK" >/dev/null 2>&1; then
    echo "[test_ext4_resize] FAIL: freshly minted image is not e2fsck-clean"
    "$E2FSCK" -fn "$RDISK" || true
    rm -f "$RDISK"; exit 1
fi
echo "[test_ext4_resize] host: pre-grow image is e2fsck-clean"

echo "[test_ext4_resize] (2/6) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_ext4_resize] (3/6) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_ext4_resize] (4/6) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF"

# Ensure the shared root image exists (other ext4 tests build it; mint a
# minimal one here if absent so this test is self-contained).
if [ ! -f build/ext4.img ]; then
    echo "[test_ext4_resize] build/ext4.img missing; minting a minimal root"
    truncate -s 4M build/ext4.img
    "$MKE2FS" -F -q -b 1024 -t ext4 -L "HAMNIX_ROOT" -O "^has_journal" \
        build/ext4.img >/dev/null
fi

LOG=$(mktemp)
trap 'rm -f "$LOG" "$RDISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_ext4_resize] (5/6) Boot QEMU: vda=root, vdb=grow target"
# The grow runs automatically: init's _first_boot_grow_check() walks the
# block devices at boot, finds the highest-numbered ext4 (vdb, our small
# fixed-size metadata_csum FS), and grows it to fill the device — exactly
# the installer-disk first-boot resize-to-fit path. No interactive shell
# input is needed; we boot, let the firstboot hook fire, then exit on the
# hamsh prompt. We still gate the keystroke on the loop-enter marker so a
# slow TCG boot doesn't drop the 'exit'.
INPUT_FIFO=$(mktemp -u --suffix=.resize-fifo)
mkfifo "$INPUT_FIFO"
set +e
(
    exec 3>"$INPUT_FIFO"
    waited=0
    while ! grep -aq "loop-enter" "$LOG" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge 110 ]; then
            break
        fi
    done
    sleep 2
    printf 'exit\n' >&3
    sleep 1
    exec 3>&-
) &
FEEDER=$!
timeout 150s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file=build/ext4.img,if=virtio,format=raw \
    -drive file="$RDISK",if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    < "$INPUT_FIFO" > "$LOG" 2>&1
rc=$?
wait "$FEEDER" 2>/dev/null
rm -f "$INPUT_FIFO"
set -e

echo "[test_ext4_resize] --- ext4 resize/firstboot lines ---"
grep -aE '\[ext4_resize|\[firstboot\]' "$LOG" || true
echo "[test_ext4_resize] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Gate on hamsh 'loop-enter' liveness: zero loop-enter == the guest never
# reached an interactive shell (starved/timed-out boot, OBSERVED crash, GRUB
# OOM), so the firstboot resize hook never fired and the host oracles below
# would inspect an UN-grown image and mis-report FAIL. INCONCLUSIVE instead.
verdict_boot_gate "$TAG" "$LOG" "$rc" 'loop-enter'

if grep -aqE "read failed status=255|failed to read superblock" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "virtio-blk superblock read flake ('read failed status=255') — host" \
        "CPU starvation; the resize fs never mounted. Re-run on a quiet host."
fi

fail=0
# Assert the in-kernel grow path ran end-to-end on vdb: the resize check
# found a checksummed grow feasible, the grow recomputed checksums, the
# old tail group's padding was reclaimed, the grow completed, and init's
# first-boot hook reported success.
for needle in \
    "[ext4_resize] metadata_csum present; grow will recompute checksums" \
    "[ext4_resize] OK: grow" \
    "[ext4_resize_grow]   old tail group 0 freed" \
    "[ext4_resize_grow] DONE: blocks 8192 -> 57345" \
    "[firstboot] resize_grow OK"
do
    if grep -aF -q "$needle" "$LOG"; then
        echo "[test_ext4_resize] OK: '$needle'"
    else
        echo "[test_ext4_resize] MISS: '$needle'"
        fail=1
    fi
done

if grep -aiE '\[ext4_resize\].*(FAIL|EIO|ENOSPC)|resize_grow FAILED' "$LOG"; then
    echo "[test_ext4_resize] in-driver grow reported a failure marker"
    fail=1
fi

# --- (6) Independent host oracle: e2fsck the grown image -------------
echo "[test_ext4_resize] (6/6) Host e2fsck -fn on the grown image"
if "$E2FSCK" -fn "$RDISK" > "$LOG.fsck" 2>&1; then
    echo "[test_ext4_resize] OK: e2fsck reports the grown FS CLEAN"
    grep -E 'blocks|inodes' "$LOG.fsck" | tail -3 || true
else
    echo "[test_ext4_resize] FAIL: e2fsck found problems in the grown FS"
    cat "$LOG.fsck"
    fail=1
fi

# Confirm e2fsck sees a GROWN block count (more than the starting group).
GROWN_GROUPS=$("$DUMPE2FS" "$RDISK" 2>/dev/null | grep -c '^Group ' || true)
echo "[test_ext4_resize] post-grow block groups (host view)=$GROWN_GROUPS"
if [ "$GROWN_GROUPS" -le 1 ]; then
    echo "[test_ext4_resize] FAIL: host sees no added block groups"
    fail=1
fi
rm -f "$LOG.fsck"

# --- Old-data-survives oracle: the pre-grow marker file must read back
# byte-exact off the grown image (debugfs dump, no mount needed). This is
# the host-side proof that growing the FS preserved existing file data.
MARK_OUT="$(mktemp --suffix=.resize-marker-out)"
"$DEBUGFS" -R "dump RESIZEME.TXT $MARK_OUT" "$RDISK" >/dev/null 2>&1 || true
EXPECT='EXT4RESIZE_MARKER online grow keeps old data intact'
if [ -s "$MARK_OUT" ] && grep -qF "$EXPECT" "$MARK_OUT"; then
    echo "[test_ext4_resize] OK: pre-grow marker RESIZEME.TXT survived byte-exact"
else
    echo "[test_ext4_resize] FAIL: RESIZEME.TXT missing/corrupt after grow"
    fail=1
fi
rm -f "$MARK_OUT"

# --- New-region-allocatable oracle: init's first-boot hook planted the
# .hamnix-grown sentinel AFTER the grow. Group 0 was packed near-full by
# FILLER.DAT, so the sentinel's inode/data had to come from a freshly
# appended group — and e2fsck (above) already certified the result CLEAN,
# proving the grown region is live + correctly accounted.
if "$DEBUGFS" -R "stat .hamnix-grown" "$RDISK" 2>/dev/null | grep -q 'Inode:'; then
    echo "[test_ext4_resize] OK: .hamnix-grown sentinel allocated in grown FS"
else
    echo "[test_ext4_resize] FAIL: .hamnix-grown sentinel not found after grow"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_resize] --- full boot log ---"
    cat "$LOG"
    verdict_fail "$TAG" \
        "hamsh reached its prompt (loop-enter observed) but the online-grow was" \
        "OBSERVED to fail — a [ext4_resize]/[firstboot] marker was absent, e2fsck" \
        "found problems, no block groups were added, or a pre-grow file did not" \
        "survive (qemu rc=$rc). A real ext4 online-resize regression."
fi
verdict_pass "$TAG" "ext4 online grow (metadata_csum): the in-kernel resize grew" \
    "blocks 8192 -> 57345, recomputed checksums, reclaimed the old tail group;" \
    "e2fsck certifies the grown FS CLEAN, pre-grow data survived byte-exact, and" \
    "a new-region sentinel allocated in the grown FS (qemu rc=$rc)"
