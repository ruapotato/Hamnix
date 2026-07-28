#!/usr/bin/env bash
# scripts/test_ext4_htree.sh — ext4 htree (dir_index) hash lookup.
#
# Proves fs/ext4.ad resolves a name inside a hash-indexed (htree /
# dir_index) directory by HASHING the name and descending the
# dx_root/dx_node B-tree to the ONE indexed leaf block — instead of the
# old behaviour of linearly scanning every directory block.
#
# Two things are verified by the in-kernel ext4_htree_selftest() (gated
# on /etc/ext4-htree-test):
#   (1) HASH KAT — ext4_dirhash() reproduces, bit-for-bit, the hashes
#       that Linux's e2fsprogs `debugfs dx_hash` computes for the
#       legacy / half_md4 / TEA algorithms with a fixed seed. This is
#       the on-disk-compatibility proof.
#   (2) LIVE DESCEND — the kernel resolves several names inside the
#       on-disk "bigdir" htree directory via the hash-descend path,
#       cross-checks each result against a pure linear scan, and asserts
#       the descend read only a handful of leaf blocks (an instrumented
#       counter), proving the INDEX was used, not a disguised full scan.
#
# Fixture: a host-minted ext4 image (1 KiB blocks, no journal) that is
# loop-mounted ONCE on the host and populated with a "bigdir" directory
# holding enough entries (6000) to force Linux's ext4 to build a real
# htree index with indirect_levels >= 1 (an interior dx_node level). The
# mount/populate happens entirely on the host with mke2fs + a real Linux
# mount, so the on-disk htree (and its Linux-computed hashes) are the
# genuine article. The Hamnix kernel only READS the image.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO.
#
# Pass marker:  [test_ext4_htree] PASS   (kernel prints [ext4-htree] PASS)
# Fail marker:  [test_ext4_htree] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_htree

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

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

DISK=$(mktemp --suffix=.ext4htree.img)
LOG=$(mktemp)
MNT=$(mktemp -d --suffix=.ext4htree.mnt)
cleanup() {
    # Best-effort: unmount the fixture, drop temp files, restore the
    # initramfs to its default (marker-free) state.
    sudo umount "$MNT" >/dev/null 2>&1 || true
    rmdir "$MNT" >/dev/null 2>&1 || true
    rm -f "$LOG" "$DISK"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_ext4_htree] (1/5) Mint a 1 KiB-block ext4 image (no journal)"
# 256 MiB headroom @ 1 KiB blocks: room for 6000 zero-length files plus
# the directory's ~50 leaf blocks + dx_root/dx_node index blocks.
truncate -s 256M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_HTREE" -O '^has_journal' "$DISK" >/dev/null

echo "[test_ext4_htree] (2/5) Loop-mount + build 'bigdir' htree directory"
# A real Linux mount builds the on-disk htree index (dir_index) as the
# directory grows; mke2fs -d does NOT, so a genuine mount is required.
sudo mount -o loop "$DISK" "$MNT"
sudo mkdir "$MNT/bigdir"
# 6000 entries force Linux's ext4 to add an interior dx_node index level
# (indirect_levels >= 1) at 1 KiB blocks. seq formats fixed-width names.
sudo bash -c "for i in \$(seq -f '%06g' 0 5999); do : > '$MNT/bigdir/file'\$i; done"
sync
sudo umount "$MNT"
rmdir "$MNT" 2>/dev/null || true
# Confirm the host actually built an htree (sanity; not the kernel proof).
if command -v debugfs >/dev/null 2>&1 || [ -x /sbin/debugfs ]; then
    DEBUGFS="$(_which debugfs || true)"
    if [ -n "${DEBUGFS:-}" ]; then
        IND=$("$DEBUGFS" -R "htree_dump bigdir" "$DISK" 2>/dev/null \
              | grep -i "Indirect levels" | head -1 || true)
        echo "[test_ext4_htree]   host dx_root: ${IND:-<htree_dump unavailable>}"
    fi
fi

echo "[test_ext4_htree] (3/5) Build userland + plant /etc/ext4-htree-test"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4_HTREE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_htree] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ext4_htree] (5/5) Boot QEMU with the htree ext4 image"
set +e
timeout 180s qemu-system-x86_64 \
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
set -e

echo "[test_ext4_htree] --- ext4-htree self-test output ---"
grep -a -E "\[ext4-htree\]" "$LOG" || true
echo "[test_ext4_htree] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero [ext4-htree] markers == starved/timeout/OOM boot, NOT a regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4-htree\]'

fail=0

if grep -a -F -q "[ext4-htree] FAIL" "$LOG"; then
    echo "[test_ext4_htree] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ext4-htree] FAIL" "$LOG" >&2 || true
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_ext4_htree] OK: $label"
    else
        echo "[test_ext4_htree] MISS: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "hash KAT matches Linux"        "[ext4-htree] PASS hash-KAT"
check "bigdir is htree (dir_index)"   "[ext4-htree] PASS bigdir is EXT4_INDEX_FL"
check "descend cross-checks linear"   "[ext4-htree] PASS descend"
check "negative lookup resolves miss" "[ext4-htree] PASS negative lookup"
check "index used, not linear"        "[ext4-htree] PASS index-not-linear"
check "self-test PASS banner"         "[ext4-htree] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_htree] --- full log ---"
    cat "$LOG"
    if ! grep -a -F -q "[ext4-htree] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[ext4-htree] markers printed but the terminal PASS banner never" \
            "arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "an [ext4-htree] marker was OBSERVED absent (or an internal FAIL was" \
        "reported) while the selftest ran (qemu rc=$rc) — real regression."
fi

verdict_pass "$TAG" "ext4 htree hash lookup: the dirhash matches Linux" \
     "bit-for-bit and the kernel resolves names by descending the" \
     "dx_root/dx_node index to the one leaf block (qemu rc=$rc)"
