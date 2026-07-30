#!/usr/bin/env bash
# scripts/test_ext4_dirgrow.sh — ext4 LINEAR directory GROWTH.
#
# WHY THIS GATE EXISTS
# ====================
# fs/ext4.ad::ext4_dir_insert used to examine only the LAST data block of
# a linear (non-htree) directory. When that block ran out of slack it
# returned -1 and said so in its own comment: it "does NOT grow the
# directory by allocating a new block". A directory therefore saturated
# at ONE block of entries — ~112 at 4 KiB blocks with ~25-char package
# filenames — and every further create failed with
#
#     ext4: blob_save_at_path FAIL (dir_insert)
#
# ext4 is the INSTALLED-system filesystem. /usr/bin, /usr/share, a home
# directory, a package cache or a photo folder blow past 112 entries
# trivially. The defect was found the hard way: an agent staging a
# 199-package repository mirror onto an installed root lost its last 88
# files, and worked around it by shipping 7 packages. Worse, the
# consumers above ext4 (user/install_rootfs_from_manifest.ad:215,
# user/hpm.ad:3916) only test `wn < 0` on a chunked ctl write, so the
# resulting -EIO arrives as a positive SHORT COUNT and the install
# reports success — data loss that ships looking healthy.
#
# WHAT THIS GATE ASSERTS
# ======================
# Fixture: a host-minted ext4 image (4 KiB blocks, NO journal, dir_index
# DISABLED so Linux cannot turn the directory into an htree) carrying a
# "growdir" directory with 3 seed files — one block, well under the old
# ceiling. dir_index off is what makes this the LINEAR path: the htree
# write path is a different code path already covered by
# scripts/test_ext4_htree_insert.sh.
#
# The in-kernel ext4_dirgrow_selftest() (gated on /etc/ext4-dirgrow-test):
#   (1) asserts growdir is LINEAR (no EXT4_INDEX_FL) and exactly 1 block,
#   (2) creates 600 files in it through the full ext4_create_file ->
#       ext4_dir_insert path — 5x the old ceiling — and records the
#       insert at which i_size first grew (the MEASURED old ceiling; every
#       insert past it used to fail),
#   (3) asserts the directory really grew to several blocks,
#   (4) looks EVERY name back up and reads its body byte, proving the
#       dirent points at the inode that was created for it (catches loss
#       AND cross-linking), and
#   (5) confirms the host-planted seeds survived.
#
# Then, on the host, against the image the KERNEL wrote:
#   (6) debugfs must enumerate all 605 entries of growdir (Linux's own
#       reader, not ours — interoperability is the whole point of using
#       ext4 rather than inventing a format), and
#   (7) e2fsck -fn must find NO problems at all (rc 0).
#
# MUTATION TESTING
# ================
# MUTATE=<label>[,<label>...] blinds individual assertions so this gate
# can be proven to go red without editing it. Labels:
#   linear | ceiling | grew | resolve | seeds | banner | debugfs | fsck
# The real mutation test is of course reverting the growth code itself
# (fs/ext4.ad::_ext4_dir_grow_insert); the labels prove each individual
# assertion is load-bearing.
#
# Pass marker:  [test_ext4_dirgrow] PASS   (kernel prints [ext4-dirgrow] PASS)
# Exit codes:   0 PASS, 1 FAIL, 125 INCONCLUSIVE (missing tool/fixture/boot)

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_dirgrow

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# Fixture shape. SEEDS + INSERTS + "." + ".." is what growdir must hold
# at the end. INSERTS must match EXT4_DIRGROW_INSERT_COUNT in fs/ext4.ad.
SEEDS=3
INSERTS=600
EXPECT_ENTRIES=$((SEEDS + INSERTS + 2))

mutated=",${MUTATE:-},"
blinded() {
    [ -n "$1" ] && [ "${mutated#*,${1},}" != "$mutated" ]
}

_which() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
    for prefix in /sbin /usr/sbin /usr/local/sbin; do
        if [ -x "$prefix/$name" ]; then echo "$prefix/$name"; return 0; fi
    done
    return 1
}
MKFS="$(_which mkfs.ext4)"   || { verdict_inconclusive "$TAG" "mkfs.ext4 not installed"; exit 125; }
FSCK="$(_which e2fsck)"      || { verdict_inconclusive "$TAG" "e2fsck not installed"; exit 125; }
DEBUGFS="$(_which debugfs)"  || { verdict_inconclusive "$TAG" "debugfs not installed"; exit 125; }

DISK=$(mktemp --suffix=.ext4dirgrow.img)
LOG=$(mktemp)
cleanup() {
    rm -f "$LOG" "$LOG.fsck" "$DISK"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_ext4_dirgrow] (1/6) Mint a 4 KiB-block ext4 image (no journal, NO dir_index)"
# 64 MiB @ 4 KiB blocks = 16384 blocks: a single block group, so every
# inode lives in group 0. -N 4096 gives ample inodes for the 600 files
# the kernel creates. ^dir_index keeps growdir LINEAR (the path under
# test); ^has_journal keeps the boot fast. metadata_csum is left ON so
# e2fsck also validates the dir_entry_tail checksums the kernel stamps
# into the blocks it allocates.
truncate -s 64M "$DISK"
if ! "$MKFS" -F -q -b 4096 -N 4096 -t ext4 -L "HAMNIX_DGROW" \
        -O '^has_journal,^dir_index' "$DISK" >/dev/null 2>&1; then
    verdict_inconclusive "$TAG" "mkfs.ext4 could not mint the fixture image"
    exit 125
fi

echo "[test_ext4_dirgrow] (2/6) Seed growdir with $SEEDS entries (debugfs, no mount/sudo)"
{
    echo "mkdir /growdir"
    for i in $(seq -f '%03g' 0 $((SEEDS - 1))); do
        echo "write /dev/null growdir/seed$i"
    done
} > "$LOG.dbg"
# debugfs `write` needs a real source file; use a 1-byte one.
printf 's' > "$LOG.seedsrc"
{
    echo "mkdir /growdir"
    for i in $(seq -f '%03g' 0 $((SEEDS - 1))); do
        echo "write $LOG.seedsrc growdir/seed$i"
    done
} > "$LOG.dbg"
if ! "$DEBUGFS" -w -f "$LOG.dbg" "$DISK" > "$LOG.dbgout" 2>&1; then
    echo "[test_ext4_dirgrow] --- debugfs seed output ---" >&2
    cat "$LOG.dbgout" >&2
    verdict_inconclusive "$TAG" "debugfs could not seed the fixture"
    exit 125
fi
rm -f "$LOG.seedsrc" "$LOG.dbg" "$LOG.dbgout"
if ! "$FSCK" -fn "$DISK" > "$LOG.fsck" 2>&1; then
    echo "[test_ext4_dirgrow] --- e2fsck on the FIXTURE ---" >&2
    cat "$LOG.fsck" >&2
    verdict_inconclusive "$TAG" "the fixture image is not clean before the boot"
    exit 125
fi
SEEDED=$("$DEBUGFS" -R "ls -l /growdir" "$DISK" 2>/dev/null | grep -c "seed")
echo "[test_ext4_dirgrow]   fixture growdir carries $SEEDED seed entries"

echo "[test_ext4_dirgrow] (3/6) Build userland + plant /etc/ext4-dirgrow-test"
if ! bash scripts/build_user.sh >"$LOG.build" 2>&1; then
    tail -40 "$LOG.build" >&2
    verdict_inconclusive "$TAG" "scripts/build_user.sh failed"
    exit 125
fi
if [ ! -f "$HAMSH_ELF" ]; then
    verdict_inconclusive "$TAG" "$HAMSH_ELF missing after build_user.sh"
    exit 125
fi
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4_DIRGROW_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null || {
        verdict_inconclusive "$TAG" "build_initramfs.py failed"; exit 125; }

echo "[test_ext4_dirgrow] (4/6) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null || {
    verdict_inconclusive "$TAG" "kernel compile failed"; exit 125; }

echo "[test_ext4_dirgrow] (5/6) Boot QEMU with the linear-dir ext4 image"
timeout 300s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$DISK",if=virtio,format=raw \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?

echo "[test_ext4_dirgrow] --- ext4-dirgrow self-test output ---"
grep -a -E "\[ext4-dirgrow\]" "$LOG" || true
echo "[test_ext4_dirgrow] --- end ---"

# Zero markers == starved/timeout/OOM boot, NOT a regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4-dirgrow\]'

fail=0
check() {
    local label="$1" needle="$2" mut="$3"
    if blinded "$mut"; then
        echo "[test_ext4_dirgrow] MUTATED(blinded): $label"
        return
    fi
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_ext4_dirgrow] OK: $label"
    else
        echo "[test_ext4_dirgrow] MISS: $label (expected '$needle')" >&2
        fail=1
    fi
}

if grep -a -F -q "[ext4-dirgrow] FAIL" "$LOG"; then
    if blinded banner; then
        echo "[test_ext4_dirgrow] MUTATED(blinded): kernel FAIL lines"
    else
        echo "[test_ext4_dirgrow] FAIL: kernel self-test reported a failure" >&2
        grep -a -F "[ext4-dirgrow] FAIL" "$LOG" >&2 || true
        fail=1
    fi
fi

check "growdir starts LINEAR and 1 block" \
      "[ext4-dirgrow] PASS growdir is a 1-block LINEAR directory" linear
check "directory grew past one block" \
      "[ext4-dirgrow] PASS dir grew" grew
check "all $INSERTS entries resolve and read back" \
      "[ext4-dirgrow] PASS all $INSERTS entries resolve and read back" resolve
check "pre-existing seeds survived" \
      "[ext4-dirgrow] PASS pre-existing seed survived the growth" seeds
check "self-test PASS banner" "[ext4-dirgrow] PASS" banner

# The measured old ceiling is the headline number this gate reports: the
# count of entries a SINGLE block accepted. It must be far below the
# number of entries we just stored (otherwise nothing was proven).
CEIL=$(grep -a -o "measured old 1-block ceiling: [0-9]* new entries" "$LOG" \
       | head -1 | grep -a -o "[0-9]*" | head -1)
if blinded ceiling; then
    echo "[test_ext4_dirgrow] MUTATED(blinded): measured-ceiling assertion"
elif [ -z "${CEIL:-}" ]; then
    echo "[test_ext4_dirgrow] MISS: kernel never reported a measured ceiling" >&2
    fail=1
elif [ "$CEIL" -ge "$INSERTS" ] || [ "$CEIL" -lt 10 ]; then
    echo "[test_ext4_dirgrow] MISS: implausible measured ceiling $CEIL" >&2
    fail=1
else
    echo "[test_ext4_dirgrow] OK: measured old 1-block ceiling = $CEIL entries;" \
         "this run stored $INSERTS (= $((INSERTS / CEIL))x it)"
fi

echo "[test_ext4_dirgrow] (6/6) Host re-validation of the image the kernel wrote"
# (a) Linux's own reader must enumerate every entry.
COUNT=$("$DEBUGFS" -R "ls -l /growdir" "$DISK" 2>/dev/null \
        | grep -a -c -E "^[[:space:]]*[0-9]+")
echo "[test_ext4_dirgrow]   debugfs counts $COUNT entries in growdir" \
     "(want $EXPECT_ENTRIES = $SEEDS seeds + $INSERTS inserts + . + ..)"
if blinded debugfs; then
    echo "[test_ext4_dirgrow] MUTATED(blinded): debugfs entry count"
elif [ "${COUNT:-0}" -ne "$EXPECT_ENTRIES" ]; then
    echo "[test_ext4_dirgrow] MISS: debugfs sees $COUNT of $EXPECT_ENTRIES entries" >&2
    "$DEBUGFS" -R "ls -l /growdir" "$DISK" 2>/dev/null | tail -5 >&2
    fail=1
else
    echo "[test_ext4_dirgrow] OK: debugfs enumerates all $EXPECT_ENTRIES entries"
fi

# (b) e2fsck must be completely clean — not "clean apart from". A grown
# directory has a new block in its extent tree, a new i_size, new
# i_blocks and (with metadata_csum) new dir_entry_tail checksums; any of
# those being wrong is exactly what e2fsck reports.
"$FSCK" -fn "$DISK" > "$LOG.fsck" 2>&1
fsck_rc=$?
echo "[test_ext4_dirgrow] --- e2fsck (rc=$fsck_rc) ---"
cat "$LOG.fsck"
echo "[test_ext4_dirgrow] --- end e2fsck ---"
if blinded fsck; then
    echo "[test_ext4_dirgrow] MUTATED(blinded): e2fsck cleanliness"
elif [ "$fsck_rc" -ne 0 ]; then
    echo "[test_ext4_dirgrow] MISS: e2fsck is not clean (rc=$fsck_rc)" >&2
    fail=1
else
    echo "[test_ext4_dirgrow] OK: e2fsck -fn clean on the kernel-written image"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_dirgrow] --- full boot log tail ---"
    tail -60 "$LOG"
    verdict_fail "$TAG" "linear directory growth is broken (see MISS lines)"
    exit 1
fi
verdict_pass "$TAG" \
    "grew growdir past its measured ${CEIL:-?}-entry 1-block ceiling to $EXPECT_ENTRIES entries; debugfs + e2fsck clean"
exit 0
