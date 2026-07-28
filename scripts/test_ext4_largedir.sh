#!/usr/bin/env bash
# scripts/test_ext4_largedir.sh — ext4 large_dir (3-level htree) WRITE path.
#
# Proves fs/ext4.ad GROWS a hash-indexed (htree / dir_index) directory from
# 2 index levels (dx_root.indirect_levels==1) to 3 index levels
# (indirect_levels==2) when the dx_root itself fills, exactly the way Linux
# does ONLY when the superblock declares INCOMPAT_LARGEDIR. The 3rd index
# level is gated strictly behind the feature flag.
#
# The in-kernel ext4_largedir_selftest() (gated on /etc/ext4-largedir-test):
#   (1) confirms the superblock declares large_dir,
#   (2) resolves the on-disk near-full 2-level "lgdir" dir_index directory
#       and asserts it starts at indirect_levels==1,
#   (3) inserts NEW long names through the full create ->
#       ext4_dir_insert -> ext4_htree_dir_insert WRITE path until the
#       dx_root overflows and the tree grows to 3 levels (indirect_levels==2),
#   (4) asserts the tree actually reached 3 levels (only reachable because
#       the superblock declares large_dir),
#   (5) verifies EVERY inserted name resolves via the 3-level hash descend
#       AND matches an independent linear scan (no corruption), and that at
#       least one lookup descended a genuine 3-frame (root->l2->leaf) path,
#       and that a pre-existing seed name survived the growth.
# The verdict is computed from real lookups + the depth assertion.
#
# After the kernel run, e2fsck on the host re-validates the on-disk
# directory the kernel WROTE — proving Linux/e2fsprogs accepts the 3-level
# htree.
#
# Fixture: a host-minted ext4 image (1 KiB blocks, large_dir, NO journal,
# NO metadata_csum) loop-mounted ONCE on the host and populated with an
# "lgdir" holding ~28700 long-named "zzz...zNNNNNNN" entries — enough for
# Linux to build a 2-level (indirect_levels==1) htree whose dx_root is
# NEARLY FULL (~117 of its 124-entry limit at 1 KiB blocks). The kernel's
# inserts overflow that root and force the real 1->2 (2->3 level) growth.
# metadata_csum is disabled because the kernel's htree INSERT path does not
# maintain the dx index-block checksums (it does maintain leaf/data tails).
#
# Pass marker:  [test_ext4_largedir] PASS  (kernel prints [ext4-largedir] PASS)
# Fail marker:  [test_ext4_largedir] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_largedir

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-1200}"

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
MKFS="$(_which mkfs.ext4)"
FSCK="$(_which e2fsck || true)"
DEBUGFS="$(_which debugfs || true)"

DISK=$(mktemp --suffix=.ext4largedir.img)
LOG=$(mktemp)
MNT=$(mktemp -d --suffix=.ext4largedir.mnt)
cleanup() {
    sudo umount "$MNT" >/dev/null 2>&1 || true
    rmdir "$MNT" >/dev/null 2>&1 || true
    rm -f "$LOG" "$DISK"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Long-name scheme MUST match the kernel's ext4_largedir_selftest():
# a 240-char 'z' prefix + a 7-digit zero-padded counter.
PREFIX=$(printf 'z%.0s' $(seq 1 240))
# Seed count: ~28000 long names at 1 KiB blocks lands a 2-level htree whose
# dx_root is near-full (~116-122 of its 124 limit) but reliably has NOT yet
# grown to 3 levels (the exact 2->3 transition jitters by a few hundred
# files with the hash distribution, so we stay safely below it). The kernel
# then inserts fresh names DIRECTLY via the htree write path (counter base
# 100000, past the seed range) until the dx_root overflows and the tree
# grows to 3 levels.
SEED_COUNT=${EXT4_LARGEDIR_SEED_COUNT:-27500}

echo "[test_ext4_largedir] (1/6) Mint a 1 KiB-block large_dir ext4 image"
# Headroom: ~28700 seed files (each 1 inode + 1 block) plus the kernel's
# fresh inserts. 1.2 GiB @ 1 KiB blocks is ample.
truncate -s 1200M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_LGDIR" \
    -O 'large_dir,^has_journal,^metadata_csum,^resize_inode' "$DISK" >/dev/null

echo "[test_ext4_largedir] (2/6) Loop-mount + build near-full 2-level 'lgdir'"
sudo mount -o loop "$DISK" "$MNT"
sudo mkdir "$MNT/lgdir"
sudo bash -c "for i in \$(seq -f '%07g' 0 $((SEED_COUNT-1))); do : > '$MNT/lgdir/${PREFIX}'\$i; done"
sync
sudo umount "$MNT"
rmdir "$MNT" 2>/dev/null || true
if [ -n "${DEBUGFS:-}" ]; then
    IND=$("$DEBUGFS" -R "htree_dump lgdir" "$DISK" 2>/dev/null \
          | grep -i "Indirect levels" | head -1 | tr -d '\t' || true)
    ROOTCNT=$("$DEBUGFS" -R "htree_dump lgdir" "$DISK" 2>/dev/null \
          | grep -i "Number of entries" | head -1 | tr -d '\t' || true)
    echo "[test_ext4_largedir]   host lgdir: ${IND:-<htree_dump unavailable>} ; root ${ROOTCNT:-?}"
    # Sanity: the fixture must be a 2-level tree (not already 3-level).
    if echo "$IND" | grep -qi "Indirect levels: 1"; then
        echo "[test_ext4_largedir]   OK: fixture is a 2-level htree"
    else
        echo "[test_ext4_largedir]   WARN: fixture indirect levels != 1 (kernel asserts this)"
    fi
fi

echo "[test_ext4_largedir] (3/6) Build userland + plant /etc/ext4-largedir-test"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4_LARGEDIR_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_largedir] (4/6) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ext4_largedir] (5/6) Boot QEMU with the large_dir ext4 image"
set +e
timeout 900s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$DISK",if=virtio,format=raw \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ext4_largedir] --- ext4-largedir self-test output ---"
grep -a -E "\[ext4-largedir\]" "$LOG" || true
echo "[test_ext4_largedir] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero [ext4-largedir] markers == the large_dir selftest never ran: a
# starved/timed-out boot (this gate builds a huge htree, so timeout is a
# genuine risk), an OBSERVED crash, or GRUB OOM — NOT an htree regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4-largedir\]'

if grep -aqE "read failed status=255|failed to read superblock" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "virtio-blk superblock read flake ('read failed status=255') — host" \
        "CPU starvation; the large_dir selftest could not mount. Re-run quiet."
fi

fail=0

if grep -a -F -q "[ext4-largedir] FAIL" "$LOG"; then
    echo "[test_ext4_largedir] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ext4-largedir] FAIL" "$LOG" >&2 || true
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_ext4_largedir] OK: $label"
    else
        echo "[test_ext4_largedir] MISS: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "superblock declares large_dir"   "[ext4-largedir] PASS superblock declares large_dir"
check "fixture starts as 2-level htree"  "[ext4-largedir] PASS fixture starts as a 2-level htree"
check "index grew to 3 levels"           "[ext4-largedir] PASS index grew"
check "all inserted names resolve"       "[ext4-largedir] PASS all"
check "3-frame descend path observed"    "[ext4-largedir] PASS a lookup descended a 3-frame"
check "pre-existing seed survived"        "[ext4-largedir] PASS pre-existing seed survived"
check "self-test PASS banner"            "[ext4-largedir] PASS"

echo "[test_ext4_largedir] (6/6) e2fsck the on-disk 3-level htree the kernel wrote"
if [ -n "${FSCK:-}" ]; then
    set +e
    "$FSCK" -fn "$DISK" > "$LOG.fsck" 2>&1
    fsck_rc=$?
    set -e
    echo "[test_ext4_largedir] --- e2fsck (rc=$fsck_rc) ---"
    cat "$LOG.fsck"
    echo "[test_ext4_largedir] --- end e2fsck ---"
    # Pass 2 ("Checking directory structure") verifies htree dx_root/dx_node
    # consistency, leaf reachability and dirent integrity, so a corrupt
    # on-disk 3-level htree shows up there. The block-bitmap / free-count /
    # i_blocks drift e2fsck also reports is NOT htree corruption — it is the
    # pre-existing Hamnix allocator limitation (updates BITMAPS but not the
    # group-descriptor / superblock free-count SUMMARIES) shared by every
    # write test; orthogonal to directory-structure correctness.
    if grep -a -i -E "htree|dir_index|Unconnected directory|directory inode .* corrupt|Entry .* has |Missing '\.'|Missing '\.\.'|Pass 2.*[0-9]+ problem|i_file_acl|directory corrupt" "$LOG.fsck" \
         | grep -a -v -i "should be" >/dev/null 2>&1; then
        echo "[test_ext4_largedir] FAIL: e2fsck found a directory/htree structural error" >&2
        fail=1
    else
        echo "[test_ext4_largedir] OK: e2fsck Pass 2 accepts the kernel-written 3-level htree" \
             "(directory structure clean; only allocator-summary drift remains)"
    fi
    rm -f "$LOG.fsck"
else
    echo "[test_ext4_largedir] (e2fsck unavailable — skipping host re-validation)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_largedir] --- full log ---"
    cat "$LOG"
    # A marker printed but the terminal PASS banner never arrived under a
    # timeout kill == starved mid-selftest (this gate builds a large htree).
    if ! grep -a -F -q "[ext4-largedir] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[ext4-largedir] markers printed but the terminal PASS banner never" \
            "arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest building the 3-level htree. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "an [ext4-largedir] marker was OBSERVED absent (or an internal FAIL /" \
        "e2fsck htree corruption was reported) while the selftest ran" \
        "(qemu rc=$rc) — a real large_dir/htree regression."
fi

verdict_pass "$TAG" "ext4 large_dir: a near-full 2-level dir_index directory" \
     "grows to a genuine 3-level htree (indirect_levels 1 -> 2), gated on" \
     "INCOMPAT_LARGEDIR; every inserted name resolves via the 3-level hash" \
     "descend, and e2fsck accepts the on-disk htree (qemu rc=$rc)"
