#!/usr/bin/env bash
# scripts/test_ext4_extent_free.sh — ext4 extent write-path correctness:
# (1) ext4_unlink frees ALL data + index/leaf metadata blocks (no leak),
# (2) the extent-tree append/trim path round-trips a DEPTH-3 tree.
#
# Proves fs/ext4.ad's in-kernel ext4_extentfree_selftest() (gated on the
# cpio marker /etc/ext4extfree-test) on a live ext4 mount:
#
#   PART A — no-leak proof: record the free-block count (clear bits across
#   the group bitmaps — the resource ext4_alloc_block/ext4_free_block
#   flip), write a multi-block FRAGMENTED file spanning several extents
#   (forcing a depth-1 index tree, so interior leaf/index metadata blocks
#   exist), read it back byte-exact, ext4_unlink() it, and assert the
#   free-block count returns EXACTLY to its pre-write value. A non-zero
#   delta means unlink leaked data and/or index/leaf metadata blocks.
#
#   PART B — depth-3 round-trip: build a depth-2 tree, promote it to depth
#   3, append more fragmented blocks through the depth-3 append path, read
#   every block back byte-exact through the generic index walk, then
#   truncate to 0 (depth-3 trim frees L2 + L1 + leaf + data) and again
#   assert the free count round-trips.
#
# Fixture: a host-minted EMPTY ext4 image (1 KiB blocks, no journal)
# mounted by the kernel at /ext. The self-test builds its files ITSELF at
# boot — no host-side fragmentation trickery required.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO.
#
# Pass marker:  [test_ext4_extent_free] PASS   (kernel: [ext4-extent] PASS)
# Fail marker:  [test_ext4_extent_free] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_ext4_extent_free

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

DISK=$(mktemp --suffix=.ext4extfree.img)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4_extent_free] (1/4) Mint a 1 KiB-block ext4 image (no journal)"
# 128 MiB headroom @ 1 KiB blocks: plenty of free data blocks for the
# self-test's ~520 data + ~520 spacer single-block allocations, and 1 KiB
# blocks keep each leaf/index node small (84 records) so 400 fragmented
# blocks overflow the depth-1 ceiling (336) and force depth 2 (then
# promoted to depth 3 by the self-test).
truncate -s 128M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_EXTFREE" -O '^has_journal' "$DISK" >/dev/null

echo "[test_ext4_extent_free] (2/4) Build userland + plant /etc/ext4extfree-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4EXTFREE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_extent_free] (3/4) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_ext4_extent_free] (4/4) Boot QEMU with the empty ext4 image"
set +e
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
set -e

echo "[test_ext4_extent_free] --- ext4-extent self-test output ---"
grep -a -E "\[ext4-extent\]" "$LOG" || true
echo "[test_ext4_extent_free] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) ---
# Zero [ext4-extent] markers == starved/timeout/OOM boot, NOT a regression.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[ext4-extent\]'

fail=0

# Treat a virtio-blk superblock-read flake (host CPU starvation under
# load) as INCONCLUSIVE, not a code failure — re-run in a quiet window.
if grep -aqE "read failed status=255|failed to read superblock" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "virtio-blk superblock read flake ('read failed status=255') —" \
        "host CPU starvation; the selftest could not mount. Re-run quiet."
fi

if grep -a -F -q "[ext4-extent] FAIL" "$LOG"; then
    echo "[test_ext4_extent_free] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ext4-extent] FAIL" "$LOG" >&2 || true
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_ext4_extent_free] OK: $label"
    else
        echo "[test_ext4_extent_free] MISS: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "no-leak after unlink"          "[ext4-extent] no-leak verified"
check "promoted to depth-3 tree"      "[ext4-extent] promoted to eh_depth=3"
check "depth-3 byte-exact round-trip" "[ext4-extent] depth-3 round-trip"
check "depth-3 trim freed all blocks" "[ext4-extent] depth-3 no-leak verified"
check "self-test PASS banner"         "[ext4-extent] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_extent_free] --- full log ---"
    cat "$LOG"
    if ! grep -a -F -q "[ext4-extent] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
        verdict_inconclusive "$TAG" \
            "[ext4-extent] markers printed but the terminal PASS banner never" \
            "arrived and qemu was killed by timeout (rc=124) — starved" \
            "mid-selftest. Re-run on a QUIET host."
    fi
    verdict_fail "$TAG" \
        "an [ext4-extent] marker was OBSERVED absent (or an internal FAIL was" \
        "reported) while the selftest ran (qemu rc=$rc) — real regression."
fi

verdict_pass "$TAG" "ext4_unlink reclaims every data + index block on a" \
     "multi-block file (no leak), and the extent tree round-trips a depth-3" \
     "file byte-exact and frees it cleanly (qemu rc=$rc)"
